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
# Uses a sentinel constant that must be set to true when real pins are added.
# This avoids false positives from base64-like strings in comments.
PINNER_FILE="$PROJECT_DIR/ios/AnvilWallet/Services/CertificatePinner.swift"
if [ -f "$PINNER_FILE" ]; then
    if grep -q 'static let pinningConfigured = true' "$PINNER_FILE" 2>/dev/null; then
        echo "PASS: Certificate pinning is marked as configured"
    else
        echo "FAIL: Certificate pinning not configured"
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

# Check 4: All Rust tests pass
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
