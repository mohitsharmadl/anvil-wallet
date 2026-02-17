# Anvil Wallet — Claude Instructions

## Project Overview
AnvilWallet — self-custody crypto wallet: Rust core (all crypto) + Swift UI (iOS app) connected via UniFFI.
Website: anvilwallet.com | Twitter: @anvilwallet | Instagram: @anvilwallet

## Quick Commands
```bash
cargo test --workspace          # Run all 241 Rust tests
cargo test -p crypto-utils      # Test single crate
cargo check -p wallet-core      # Quick compile check
./build-scripts/build-ios.sh    # Build XCFramework for iOS
./build-scripts/build-sim.sh    # Quick simulator build
```

## Architecture
- `crates/crypto-utils/` — AES-256-GCM, Argon2id, zeroize wrappers
- `crates/wallet-core/` — FFI boundary, BIP-39, HD derivation, UniFFI exports
- `crates/chain-btc/` — Bitcoin P2WPKH, UTXO transactions
- `crates/chain-eth/` — Ethereum EIP-1559, ERC-20, 7 EVM chains
- `crates/chain-sol/` — Solana Ed25519, manual wire format, SPL tokens
- `ios/AnvilWallet/` — SwiftUI iOS app

## Key Constraints
- UniFFI 0.28 passes owned types (String, Vec<u8>) across FFI, not references
- Secure Enclave only supports P-256, not secp256k1 — hence double encryption
- No solana-sdk — manual wire format implementation
- All sensitive data must use `zeroize` / `ZeroizeOnDrop`
- Zero analytics, zero telemetry, zero third-party data SDKs

## Dependencies Policy
- Rust: Only audited, well-known crates (RustCrypto, rust-bitcoin, alloy)
- iOS: Only SwiftUI + native frameworks + TrustKit + Reown SDK
- No umbrella crates — use granular sub-crates (e.g., alloy-primitives not alloy)
