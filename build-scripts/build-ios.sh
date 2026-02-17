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
GENERATED_DIR="$IOS_DIR/CryptoWallet/Generated"
FRAMEWORK_NAME="WalletCoreFramework"

echo "=== Building wallet-core for iOS ==="
echo "Root: $ROOT_DIR"
echo ""

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

# 5. Create module maps for each platform
for PLATFORM_DIR in "$IOS_DIR/$FRAMEWORK_NAME-device" "$IOS_DIR/$FRAMEWORK_NAME-sim"; do
    HEADERS_DIR="$PLATFORM_DIR/Headers"
    MODULES_DIR="$PLATFORM_DIR/Modules"
    mkdir -p "$HEADERS_DIR" "$MODULES_DIR"

    cat > "$MODULES_DIR/module.modulemap" << 'MODULEMAP'
framework module WalletCoreFramework {
    header "wallet_coreFFI.h"
    export *
}
MODULEMAP
done

# 6. Generate Swift bindings and C header using uniffi-bindgen
echo ">>> Generating Swift bindings..."
UDL_FILE="$CRATE_DIR/src/wallet_core.udl"
DEVICE_DYLIB="$DEVICE_LIB"  # uniffi-bindgen works with static libs too

uniffi-bindgen generate "$UDL_FILE" \
    --language swift \
    --out-dir "$GENERATED_DIR" \
    --library "$DEVICE_LIB" 2>/dev/null || \
uniffi-bindgen generate "$UDL_FILE" \
    --language swift \
    --out-dir "$GENERATED_DIR"

# Move the generated header to framework headers
if [ -f "$GENERATED_DIR/wallet_coreFFI.h" ]; then
    cp "$GENERATED_DIR/wallet_coreFFI.h" "$IOS_DIR/$FRAMEWORK_NAME-device/Headers/"
    cp "$GENERATED_DIR/wallet_coreFFI.h" "$IOS_DIR/$FRAMEWORK_NAME-sim/Headers/"
fi

# 7. Copy static libraries into framework structure
cp "$DEVICE_LIB" "$IOS_DIR/$FRAMEWORK_NAME-device/$FRAMEWORK_NAME"
cp "$SIM_LIB" "$IOS_DIR/$FRAMEWORK_NAME-sim/$FRAMEWORK_NAME"

# 8. Create Info.plist for each
for PLATFORM_DIR in "$IOS_DIR/$FRAMEWORK_NAME-device" "$IOS_DIR/$FRAMEWORK_NAME-sim"; do
    cat > "$PLATFORM_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>WalletCoreFramework</string>
    <key>CFBundleIdentifier</key>
    <string>com.cryptowallet.walletcore</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
</dict>
</plist>
PLIST
done

# 9. Create XCFramework
echo ">>> Creating XCFramework..."
rm -rf "$IOS_DIR/$FRAMEWORK_NAME.xcframework"

xcodebuild -create-xcframework \
    -library "$DEVICE_LIB" \
    -headers "$IOS_DIR/$FRAMEWORK_NAME-device/Headers" \
    -library "$SIM_LIB" \
    -headers "$IOS_DIR/$FRAMEWORK_NAME-sim/Headers" \
    -output "$IOS_DIR/$FRAMEWORK_NAME.xcframework"

# 10. Cleanup temp directories
rm -rf "$IOS_DIR/$FRAMEWORK_NAME-device" "$IOS_DIR/$FRAMEWORK_NAME-sim"

echo ""
echo "=== Build complete! ==="
echo "XCFramework: $IOS_DIR/$FRAMEWORK_NAME.xcframework"
echo "Swift bindings: $GENERATED_DIR/wallet_core.swift"
echo ""
echo "Next steps:"
echo "  1. Open ios/CryptoWallet.xcodeproj in Xcode"
echo "  2. Add WalletCoreFramework.xcframework to the project"
echo "  3. Build and run on simulator or device"
