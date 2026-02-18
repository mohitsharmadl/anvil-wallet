#!/bin/bash
# extract-spki-pins.sh — Extracts SPKI SHA-256 pin hashes for all RPC hosts.
#
# Usage: ./build-scripts/extract-spki-pins.sh
#
# For each host, outputs the base64-encoded SHA-256 hash of the SPKI DER
# encoding. These values should be added to CertificatePinner.swift's
# pinnedHashes dictionary before release.

set -uo pipefail
# Note: -e is intentionally omitted so that a single host failure
# does not abort the entire run. Failures are tracked and reported.

HOSTS=(
    "eth-mainnet.g.alchemy.com"
    "polygon-rpc.com"
    "arb1.arbitrum.io"
    "mainnet.base.org"
    "mainnet.optimism.io"
    "bsc-dataseed.binance.org"
    "api.avax.network"
    "api.mainnet-beta.solana.com"
    "blockstream.info"
    "rpc.sepolia.org"
)

FAILURES=0
# SHA-256 of empty input — produced when openssl silently fails.
# Any pin matching this value is invalid and must be rejected.
EMPTY_HASH="47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="

# Extracts SPKI pin from a PEM certificate on stdin.
# Uses a single pipeline — no binary data stored in shell variables.
# Returns empty string (and exit 1) if any step fails.
extract_pin() {
    local pin
    # Validate that stdin contains a PEM certificate before hashing.
    # Then run the full pipeline: PEM → pubkey PEM → DER → SHA-256 → base64.
    # pipefail ensures any stage failure propagates.
    pin=$(openssl x509 -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform der 2>/dev/null \
        | openssl dgst -sha256 -binary 2>/dev/null \
        | base64 2>/dev/null) || return 1
    # Reject empty output or the known SHA-256("") sentinel
    if [ -z "$pin" ] || [ "$pin" = "$EMPTY_HASH" ]; then
        return 1
    fi
    echo "$pin"
}

echo "=== SPKI Pin Hashes for Anvil Wallet RPC Hosts ==="
echo ""

for host in "${HOSTS[@]}"; do
    echo "Host: $host"

    # Fetch full certificate chain
    CHAIN=$(openssl s_client -connect "$host:443" -servername "$host" -showcerts </dev/null 2>/dev/null)

    # Verify we got at least one certificate
    if ! echo "$CHAIN" | grep -q 'BEGIN CERTIFICATE'; then
        echo "  ERROR: No certificates received (host unreachable or TLS failure)"
        FAILURES=$((FAILURES + 1))
        echo ""
        continue
    fi

    # Leaf certificate pin (cert #1)
    leaf_pin=$(echo "$CHAIN" | extract_pin)

    # Intermediate CA pin (cert #2 in the chain)
    intermediate_pin=$(echo "$CHAIN" | awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++} n==2' | extract_pin)

    if [ -n "$leaf_pin" ]; then
        echo "  Leaf pin:         $leaf_pin"
    else
        echo "  ERROR: Could not extract valid leaf pin"
        FAILURES=$((FAILURES + 1))
    fi

    if [ -n "$intermediate_pin" ]; then
        echo "  Intermediate pin: $intermediate_pin"
    else
        echo "  WARN: Could not extract intermediate CA pin"
    fi
    echo ""
done

echo "=== Summary ==="
if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES host(s) failed pin extraction. Re-run or check connectivity."
else
    echo "All hosts extracted successfully."
fi
echo ""
echo "Add both pins per host to CertificatePinner.swift pinnedHashes dictionary."
echo "The intermediate CA pin acts as a backup when leaf certs rotate."

exit "$FAILURES"
