<p align="center">
  <strong>Anvil Wallet</strong>
</p>

<p align="center">
  Open-source, self-custody crypto wallet for iOS.<br/>
  Rust core. SwiftUI interface. Zero telemetry. 16 security layers.
</p>

<p align="center">
  <a href="https://www.rust-lang.org"><img alt="Rust" src="https://img.shields.io/badge/Rust-1.92-000000?logo=rust&logoColor=white"></a>
  <a href="#"><img alt="Tests" src="https://img.shields.io/badge/tests-241%20passing-brightgreen"></a>
  <a href="#"><img alt="Platform" src="https://img.shields.io/badge/platform-iOS%2016+-007AFF?logo=apple&logoColor=white"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <a href="#"><img alt="Analytics" src="https://img.shields.io/badge/analytics-zero-critical"></a>
</p>

<p align="center">
  <a href="https://anvilwallet.com">Website</a> &middot;
  <a href="https://x.com/anvilwallet">Twitter</a> &middot;
  <a href="https://instagram.com/anvilwallet">Instagram</a>
</p>

---

## What is Anvil Wallet?

Anvil Wallet is a fully open-source, self-custody cryptocurrency wallet for iOS. All cryptographic operations -- key generation, signing, encryption -- happen in Rust. The iOS app is pure SwiftUI connected to the Rust core via Mozilla's UniFFI.

No accounts. No servers. No tracking. Your keys never leave your device.

### Supported Chains

| Chain | Type | Details |
|-------|------|---------|
| **Bitcoin** | UTXO | Native SegWit (P2WPKH, bech32) |
| **Ethereum** | EVM | EIP-1559 transactions, ERC-20 tokens |
| **Polygon** | EVM | MATIC + ERC-20 |
| **Arbitrum** | EVM | ETH + ERC-20 |
| **Base** | EVM | ETH + ERC-20 |
| **Optimism** | EVM | ETH + ERC-20 |
| **BSC** | EVM | BNB + BEP-20 |
| **Avalanche** | EVM | AVAX + ERC-20 |
| **Solana** | Ed25519 | SOL + SPL tokens |

## Implementation Status

| Component | Status | Notes |
|-----------|--------|-------|
| Rust crypto core (5 crates) | Complete | 241 tests passing |
| BIP-39 mnemonic generation | Complete | 24-word, via Rust FFI |
| HD key derivation (BTC, ETH, SOL) | Complete | BIP-44/84 paths |
| AES-256-GCM + Argon2id encryption | Complete | Double encryption with SE |
| EVM transaction signing (EIP-1559) | Complete | Wired to Rust FFI |
| Solana transaction signing | Complete | Wired to Rust FFI |
| Bitcoin transaction signing | Planned | Requires UTXO management |
| Certificate pinning | Framework ready | Native URLSession delegate wired; SPKI pin hashes not yet configured |
| Binary integrity check | Framework ready | SHA-256 comparison wired; build-time hash injection not yet configured |
| WalletConnect v2 | Stub | Phase 5 — Reown SDK integration |
| Token balance fetching | Stub | RPC methods ready, UI integration pending |

## Architecture

```
+----------------------------------------------------+
|                SwiftUI (iOS App)                    |
|                                                     |
|   Features    Services        Security Module       |
|   (Views)     (RPC, Price)    (SE, Keychain, Bio)   |
|       \           |                                 |
|        +----+-----+                                 |
|             |                                       |
|       WalletService (orchestrator)                  |
+-------------|---------------------------------------+
              | UniFFI (C FFI boundary)
+-------------|---------------------------------------+
|             v                                       |
|         Rust Core (wallet-core)                     |
|                                                     |
|   crypto-utils    wallet-core (BIP-39, HD, FFI)     |
|   (AES, Argon2)                                     |
|                                                     |
|   chain-btc       chain-eth        chain-sol        |
|   (Bitcoin)       (EVM)            (Solana)         |
+-----------------------------------------------------+
```

All chain crates are independent. `wallet-core` depends on all of them and exposes a single, unified FFI interface to Swift.

## Project Structure

```
anvil-wallet/
|-- crates/
|   |-- crypto-utils/      # AES-256-GCM, Argon2id KDF, zeroize wrappers
|   |-- wallet-core/       # BIP-39/32/44 HD derivation, UniFFI FFI boundary
|   |-- chain-btc/         # Bitcoin P2WPKH, UTXO transaction building
|   |-- chain-eth/         # Ethereum EIP-1559, ERC-20, 7 EVM chains
|   |-- chain-sol/         # Solana Ed25519, manual wire format, SPL tokens
|-- ios/
|   |-- AnvilWallet/
|       |-- App/            # Entry point, ContentView
|       |-- Features/       # Onboarding, Wallet, Send, DApps, Activity, Settings
|       |-- Services/       # WalletService, Keychain, SecureEnclave, Biometric, RPC
|       |-- Security/       # Jailbreak detection, anti-debug, screenshot protection
|       |-- Models/         # Wallet, Token, Transaction, Chain models
|       |-- Navigation/     # Router, TabBar
|       |-- Extensions/     # Theme colors, View helpers
|-- build-scripts/
|   |-- build-ios.sh        # Build XCFramework for device + simulator
|   |-- build-sim.sh        # Quick simulator-only build
|-- docs/
|   |-- SECURITY.md         # Full 16-layer security breakdown
|   |-- ARCHITECTURE.md     # Detailed architecture and data flows
|-- tests/
|   |-- integration/        # Cross-crate integration tests
|-- Cargo.toml              # Workspace root
|-- rust-toolchain.toml     # Pinned Rust 1.92.0
```

## At a Glance

| | |
|---|---|
| **241** | Tests passing |
| **5** | Rust crates |
| **46** | Swift files |
| **16** | Security layers |
| **0** | Analytics SDKs |

## Security Overview

Anvil Wallet implements 16 security layers spanning hardware, OS, application, and network levels:

| Layer | Protection |
|-------|-----------|
| Secure Enclave | Hardware-bound P-256 key encrypts the seed (non-extractable) |
| iOS Keychain | Device-only storage, no iCloud sync, no backup extraction |
| BIP-39 | 24-word mnemonic + optional passphrase (plausible deniability) |
| AES-256-GCM | Seed encrypted at rest (NCC Group audited aes-gcm crate) |
| Argon2id KDF | 64MB memory-hard password derivation (GPU/ASIC resistant) |
| Biometric Auth | Face ID / Touch ID required for every transaction |
| Jailbreak Detection | 6 sub-layer detection (files, symlinks, sandbox, dyld, fork, URL schemes) |
| Anti-Screenshot | Secure text overlay + background blur |
| Clipboard Auto-Clear | Copied data wiped after 120 seconds |
| Certificate Pinning | Native URLSession delegate with SPKI SHA-256 pinning (pin hashes not yet configured) |
| Memory Zeroization | All keys, seeds, mnemonics zeroed on drop (Rust + Swift) |
| Anti-Debugging | ptrace deny-attach + sysctl P_TRACED check |
| Binary Integrity | Mach-O header + executable SHA-256 verification (build-time hash injection not yet configured) |
| Transaction Simulation | Pre-sign simulation for EVM transactions |
| Address Validation | Format + checksum + address poisoning detection |
| Zero Telemetry | No analytics, no crash reporting, no third-party data SDKs |

**Double encryption:** User password derives an AES key via Argon2id, which encrypts the seed. The Secure Enclave then encrypts that ciphertext with P-256 ECIES. Both layers must be compromised to access the seed.

Full details: [`docs/SECURITY.md`](docs/SECURITY.md)

## Why Rust?

The entire cryptographic core -- key generation, HD derivation, transaction signing, encryption -- is written in Rust.

- **Memory safety without garbage collection.** No use-after-free, no buffer overflows, no data races. The compiler enforces these guarantees at build time, not runtime.
- **Deterministic cleanup.** The `zeroize` crate with `ZeroizeOnDrop` ensures all private keys, seeds, and mnemonics are overwritten with zeros the instant they leave scope. This is not a best-effort GC finalizer -- it is a compiler-guaranteed destructor.
- **Pure Rust cryptography.** Anvil uses `k256` (RustCrypto) for secp256k1, not C bindings to libsecp256k1. This eliminates an entire class of FFI-related vulnerabilities and simplifies iOS cross-compilation.
- **No solana-sdk.** The Solana transaction wire format is implemented manually in ~400 lines of Rust, avoiding the 200+ transitive dependencies and tokio runtime that `solana-sdk` would pull in.
- **One codebase, every platform.** The same Rust code compiles for iOS device (aarch64-apple-ios), iOS simulator, and eventually Android and desktop.

## Building

### Prerequisites

- **Rust 1.92.0** (pinned via `rust-toolchain.toml` -- installed automatically)
- **Xcode 15+** with iOS 16+ SDK
- **uniffi-bindgen-cli 0.28.0**

```bash
# Install iOS targets
rustup target add aarch64-apple-ios aarch64-apple-ios-sim

# Install UniFFI bindgen
cargo install uniffi-bindgen-cli --version 0.28.0
```

### Run Tests

```bash
# All 241 tests
cargo test --workspace

# Individual crate
cargo test -p crypto-utils
cargo test -p chain-btc
cargo test -p chain-eth
cargo test -p chain-sol
cargo test -p wallet-core
```

### Build for iOS

```bash
# Full build: device + simulator XCFramework + Swift bindings
./build-scripts/build-ios.sh

# Quick simulator-only build
./build-scripts/build-sim.sh
```

After building:
1. Open `ios/AnvilWallet.xcodeproj` in Xcode
2. Add `WalletCoreFramework.xcframework` to the project
3. Build and run on simulator or device

### WalletConnect

Anvil Wallet supports WalletConnect v2 for connecting to dApps (Uniswap, OpenSea, Aave, and others). Pair by scanning a QR code, then approve sessions and sign transactions directly from the wallet.

## Dependencies

Anvil follows a strict dependency policy: only audited, well-known crates from established ecosystems.

| Purpose | Crate | Ecosystem |
|---------|-------|-----------|
| secp256k1 ECDSA | `k256` | RustCrypto |
| Ed25519 (Solana) | `ed25519-dalek` | dalek-cryptography |
| AES-256-GCM | `aes-gcm` | RustCrypto (NCC audited) |
| Argon2id KDF | `argon2` | RustCrypto |
| BIP-39 mnemonics | `bip39` | rust-bitcoin |
| BIP-32 HD keys | `bip32` | RustCrypto |
| Bitcoin | `bitcoin` | rust-bitcoin |
| Ethereum RLP/types | `alloy-*` | Alloy (Paradigm) |
| Memory zeroization | `zeroize` | RustCrypto |
| FFI generation | `uniffi` | Mozilla |

No umbrella crates. No C bindings for crypto. No analytics or telemetry SDKs.

## Contributing

Contributions are welcome. Please open an issue before submitting a pull request for any non-trivial change.

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/your-feature`)
3. Ensure all tests pass (`cargo test --workspace`)
4. Run clippy (`cargo clippy --workspace -- -D warnings`)
5. Submit a pull request

### Areas Where Help is Appreciated

- Android port (the Rust core already compiles for Android targets)
- Additional chain integrations
- Security audits and review
- Accessibility improvements in the iOS app
- Localization

## License

This project is licensed under the [MIT License](LICENSE).

---

<p align="center">
  Built with Rust and SwiftUI.<br/>
  Your keys. Your crypto. Nothing else.
</p>
