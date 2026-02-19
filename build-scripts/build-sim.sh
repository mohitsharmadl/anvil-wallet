#!/bin/bash
set -euo pipefail

# Quick build for iOS simulator only (development)
# Much faster than full build-ios.sh since it only targets simulator

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CRATE_DIR="$ROOT_DIR/crates/wallet-core"
IOS_DIR="$ROOT_DIR/ios"
GENERATED_DIR="$IOS_DIR/AnvilWallet/Generated"

echo "=== Quick simulator build ==="

# Set minimum iOS deployment target to match project.yml (17.0)
export IPHONEOS_DEPLOYMENT_TARGET=17.0

# Build for simulator only
echo ">>> Building for aarch64-apple-ios-sim..."
cargo build --manifest-path "$CRATE_DIR/Cargo.toml" \
    --target aarch64-apple-ios-sim \
    --release

SIM_LIB="$ROOT_DIR/target/aarch64-apple-ios-sim/release/libwallet_core.a"

if [ ! -f "$SIM_LIB" ]; then
    echo "ERROR: Simulator library not found at $SIM_LIB"
    exit 1
fi

# Generate Swift bindings
echo ">>> Generating Swift bindings..."
mkdir -p "$GENERATED_DIR"

UDL_FILE="$CRATE_DIR/src/wallet_core.udl"
cargo run -p uniffi-bindgen --manifest-path "$ROOT_DIR/Cargo.toml" -- generate "$UDL_FILE" \
    --language swift \
    --out-dir "$GENERATED_DIR"

# Rename modulemap to standard name (Swift convention)
if [ -f "$GENERATED_DIR/wallet_coreFFI.modulemap" ]; then
    mv "$GENERATED_DIR/wallet_coreFFI.modulemap" "$GENERATED_DIR/module.modulemap"
fi

echo ""
echo "=== Simulator build complete! ==="
echo "Library: $SIM_LIB"
echo "Bindings: $GENERATED_DIR/"
