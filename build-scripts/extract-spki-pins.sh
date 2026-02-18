#!/bin/bash
# extract-spki-pins.sh — Extracts SPKI SHA-256 pin hashes for all RPC hosts.
#
# Usage: ./build-scripts/extract-spki-pins.sh
#
# For each host, outputs the base64-encoded SHA-256 hash of the SPKI DER
# encoding. These values should be added to CertificatePinner.swift's
# pinnedHashes dictionary before release.

set -euo pipefail

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

echo "=== SPKI Pin Hashes for Anvil Wallet RPC Hosts ==="
echo ""

for host in "${HOSTS[@]}"; do
    echo "Host: $host"
    pin=$(openssl s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null | \
        openssl x509 -pubkey -noout 2>/dev/null | \
        openssl pkey -pubin -outform der 2>/dev/null | \
        openssl dgst -sha256 -binary 2>/dev/null | \
        base64 2>/dev/null)

    if [ -n "$pin" ]; then
        echo "  Pin: $pin"
    else
        echo "  ERROR: Could not extract pin (host may be unreachable)"
    fi
    echo ""
done

echo "Add these to CertificatePinner.swift pinnedHashes dictionary."
echo "Include at least 2 pins per host (primary + backup CA) to avoid lockout."
