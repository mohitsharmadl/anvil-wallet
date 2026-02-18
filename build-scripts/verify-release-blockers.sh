#!/bin/bash
# verify-release-blockers.sh — Pre-release check that ensures certificate
# pinning and binary integrity are properly configured before shipping.
#
# Usage: ./build-scripts/verify-release-blockers.sh
#
# Run this before submitting to App Store. Exits with code 1 if any blocker
# is not resolved.

set -euo pipefail

ERRORS=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Anvil Wallet Release Blocker Check ==="
echo ""

# Check 1: Certificate pins configured
# Verifies BOTH:
#   a) The sentinel constant is set to true
#   b) pinnedHashes contains at least one real base64 pin entry (host: ["hash="])
PINNER_FILE="$PROJECT_DIR/ios/AnvilWallet/Services/CertificatePinner.swift"
if [ -f "$PINNER_FILE" ]; then
    SENTINEL_OK=false
    PINS_OK=false

    if grep -q 'static let pinningConfigured = true' "$PINNER_FILE" 2>/dev/null; then
        SENTINEL_OK=true
    fi

    # Count distinct host keys in the pinnedHashes dictionary.
    # Matches non-comment lines like:   "eth-mainnet.g.alchemy.com": [
    PIN_COUNT=$(grep -v '^ *//' "$PINNER_FILE" 2>/dev/null | grep -cE '"[a-zA-Z0-9_-]+\.[a-zA-Z0-9._-]+": *\[' || true)
    # Also verify at least one real base64 pin hash exists (not just empty arrays).
    # Scoped to non-comment lines to prevent commented-out hashes from satisfying the check.
    HASH_COUNT=$(grep -v '^ *//' "$PINNER_FILE" 2>/dev/null | grep -cE '"[A-Za-z0-9+/]{20,}="' || true)
    if [ "$HASH_COUNT" -lt 1 ]; then
        PIN_COUNT=0
    fi
    if [ "$PIN_COUNT" -ge 1 ]; then
        PINS_OK=true
    fi

    if $SENTINEL_OK && $PINS_OK; then
        echo "PASS: Certificate pinning configured (sentinel=true, $PIN_COUNT host(s) pinned)"
    else
        echo "FAIL: Certificate pinning not fully configured"
        $SENTINEL_OK || echo "  - pinningConfigured is not set to true"
        $PINS_OK    || echo "  - pinnedHashes contains no real pin entries"
        echo "  1. Run: ./build-scripts/extract-spki-pins.sh"
        echo "  2. Add pin hashes to pinnedHashes dictionary"
        echo "  3. Set 'static let pinningConfigured = true' in CertificatePinner.swift"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "FAIL: CertificatePinner.swift not found"
    ERRORS=$((ERRORS + 1))
fi

echo ""

# Check 2: Binary hash injection script exists and is executable
INJECT_SCRIPT="$PROJECT_DIR/build-scripts/inject-binary-hash.sh"
if [ -f "$INJECT_SCRIPT" ] && [ -x "$INJECT_SCRIPT" ]; then
    echo "PASS: inject-binary-hash.sh exists and is executable"
else
    echo "FAIL: inject-binary-hash.sh missing or not executable"
    echo "  Run: chmod +x build-scripts/inject-binary-hash.sh"
    ERRORS=$((ERRORS + 1))
fi

echo ""

# Check 3: BinaryHash.swift stub exists
HASH_FILE="$PROJECT_DIR/ios/AnvilWallet/Generated/BinaryHash.swift"
if [ -f "$HASH_FILE" ]; then
    echo "PASS: BinaryHash.swift exists"
else
    echo "FAIL: BinaryHash.swift not found at ios/AnvilWallet/Generated/"
    echo "  This file should be created by inject-binary-hash.sh during build."
    ERRORS=$((ERRORS + 1))
fi

echo ""

# Check 4: Reown WalletConnect project ID is configured via Secrets.xcconfig
SECRETS_FILE="$PROJECT_DIR/ios/Secrets.xcconfig"
SECRETS_EXAMPLE="$PROJECT_DIR/ios/Secrets.xcconfig.example"
if [ ! -f "$SECRETS_EXAMPLE" ]; then
    echo "FAIL: Secrets.xcconfig.example not found"
    ERRORS=$((ERRORS + 1))
elif [ ! -f "$SECRETS_FILE" ]; then
    echo "FAIL: ios/Secrets.xcconfig not found"
    echo "  Copy Secrets.xcconfig.example to Secrets.xcconfig and set REOWN_PROJECT_ID"
    ERRORS=$((ERRORS + 1))
elif grep -qE 'REOWN_PROJECT_ID\s*=\s*YOUR_REOWN_PROJECT_ID' "$SECRETS_FILE" 2>/dev/null || \
     grep -qE 'REOWN_PROJECT_ID\s*=\s*$' "$SECRETS_FILE" 2>/dev/null; then
    echo "FAIL: REOWN_PROJECT_ID is placeholder or empty in ios/Secrets.xcconfig"
    echo "  Set a real project ID from https://cloud.reown.com"
    ERRORS=$((ERRORS + 1))
else
    echo "PASS: Reown WalletConnect project ID configured in Secrets.xcconfig"
fi

echo ""

# Check 5: All Rust tests pass
echo "Running Rust test suite..."
if (cd "$PROJECT_DIR" && cargo test --workspace --quiet 2>&1); then
    echo "PASS: All Rust tests pass"
else
    echo "FAIL: Rust tests failed"
    ERRORS=$((ERRORS + 1))
fi

echo ""
echo "=== Summary ==="
if [ "$ERRORS" -gt 0 ]; then
    echo "BLOCKED: $ERRORS issue(s) must be resolved before release."
    exit 1
else
    echo "All release checks passed."
    exit 0
fi
