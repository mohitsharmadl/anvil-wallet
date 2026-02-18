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

    # Fetch full certificate chain
    CHAIN=$(openssl s_client -connect "$host:443" -servername "$host" -showcerts </dev/null 2>/dev/null)

    # Leaf certificate pin (cert #1)
    leaf_pin=$(echo "$CHAIN" | \
        openssl x509 -pubkey -noout 2>/dev/null | \
        openssl pkey -pubin -outform der 2>/dev/null | \
        openssl dgst -sha256 -binary 2>/dev/null | \
        base64 2>/dev/null)

    # Intermediate CA pin (cert #2 in the chain)
    intermediate_pin=$(echo "$CHAIN" | \
        awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++} n==2' | \
        openssl x509 -pubkey -noout 2>/dev/null | \
        openssl pkey -pubin -outform der 2>/dev/null | \
        openssl dgst -sha256 -binary 2>/dev/null | \
        base64 2>/dev/null)

    if [ -n "$leaf_pin" ]; then
        echo "  Leaf pin:         $leaf_pin"
    else
        echo "  ERROR: Could not extract leaf pin (host may be unreachable)"
    fi

    if [ -n "$intermediate_pin" ]; then
        echo "  Intermediate pin: $intermediate_pin"
    else
        echo "  WARN: Could not extract intermediate CA pin"
    fi
    echo ""
done

echo "Add both pins per host to CertificatePinner.swift pinnedHashes dictionary."
echo "The intermediate CA pin acts as a backup when leaf certs rotate."
