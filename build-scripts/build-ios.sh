#!/bin/bash
set -euo pipefail

# Build Rust wallet-core for iOS and create XCFramework + Swift bindings
#
# Prerequisites:
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim
#   cargo install uniffi-bindgen-cli --version 0.28.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CRATE_DIR="$ROOT_DIR/crates/wallet-core"
IOS_DIR="$ROOT_DIR/ios"
GENERATED_DIR="$IOS_DIR/AnvilWallet/Generated"
FRAMEWORK_NAME="WalletCoreFramework"

echo "=== Building wallet-core for iOS ==="
echo "Root: $ROOT_DIR"
echo ""

# Set minimum iOS deployment target to match project.yml (17.0)
# Without this, Rust links against the SDK version (e.g. 26.2) causing
# "object file was built for newer iOS version" warnings in Xcode.
export IPHONEOS_DEPLOYMENT_TARGET=17.0

# 1. Build for iOS device (arm64)
echo ">>> Building for aarch64-apple-ios (device)..."
cargo build --manifest-path "$CRATE_DIR/Cargo.toml" \
    --target aarch64-apple-ios \
    --release

# 2. Build for iOS simulator (arm64 — Apple Silicon Mac)
echo ">>> Building for aarch64-apple-ios-sim (simulator)..."
cargo build --manifest-path "$CRATE_DIR/Cargo.toml" \
    --target aarch64-apple-ios-sim \
    --release

# 3. Create directories
mkdir -p "$GENERATED_DIR"
mkdir -p "$IOS_DIR/$FRAMEWORK_NAME-device"
mkdir -p "$IOS_DIR/$FRAMEWORK_NAME-sim"

# 4. Copy static libraries
DEVICE_LIB="$ROOT_DIR/target/aarch64-apple-ios/release/libwallet_core.a"
SIM_LIB="$ROOT_DIR/target/aarch64-apple-ios-sim/release/libwallet_core.a"

if [ ! -f "$DEVICE_LIB" ]; then
    echo "ERROR: Device library not found at $DEVICE_LIB"
    exit 1
fi

if [ ! -f "$SIM_LIB" ]; then
    echo "ERROR: Simulator library not found at $SIM_LIB"
    exit 1
fi

# 5. Generate Swift bindings and C header using uniffi-bindgen
echo ">>> Generating Swift bindings..."
UDL_FILE="$CRATE_DIR/src/wallet_core.udl"

cargo run -p uniffi-bindgen --manifest-path "$ROOT_DIR/Cargo.toml" -- generate "$UDL_FILE" \
    --language swift \
    --out-dir "$GENERATED_DIR" \
    --library "$DEVICE_LIB" 2>/dev/null || \
cargo run -p uniffi-bindgen --manifest-path "$ROOT_DIR/Cargo.toml" -- generate "$UDL_FILE" \
    --language swift \
    --out-dir "$GENERATED_DIR"

# Rename modulemap to standard name (Swift convention)
if [ -f "$GENERATED_DIR/wallet_coreFFI.modulemap" ]; then
    mv "$GENERATED_DIR/wallet_coreFFI.modulemap" "$GENERATED_DIR/module.modulemap"
fi

# 6. Create XCFramework (library-only, no headers — headers live in Generated/)
# This avoids module.modulemap conflicts with Reown SDK's Yttrium xcframework.
echo ">>> Creating XCFramework..."
rm -rf "$IOS_DIR/$FRAMEWORK_NAME.xcframework"

xcodebuild -create-xcframework \
    -library "$DEVICE_LIB" \
    -library "$SIM_LIB" \
    -output "$IOS_DIR/$FRAMEWORK_NAME.xcframework"

echo ""
echo "=== Build complete! ==="
echo "XCFramework: $IOS_DIR/$FRAMEWORK_NAME.xcframework"
echo "Swift bindings: $GENERATED_DIR/wallet_core.swift"
echo ""
echo "Next steps:"
echo "  1. Open ios/AnvilWallet.xcodeproj in Xcode"
echo "  2. Add WalletCoreFramework.xcframework to the project"
echo "  3. Build and run on simulator or device"
