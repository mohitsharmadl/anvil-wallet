# FOR-Mohit: Crypto Wallet

## What Is This?

A self-custody crypto wallet for iOS (Android later). Think Trust Wallet or MetaMask mobile, but built from scratch with paranoid-level security. Supports BTC, ETH, all EVM chains (Polygon, Arbitrum, Base, etc.), and Solana. Ships to App Store with WalletConnect support so you can connect to Uniswap, OpenSea, etc.

The key architectural decision: **all crypto logic lives in Rust**, and the iOS app just handles UI + device security features (Secure Enclave, Keychain, Face ID). The Rust code talks to Swift via UniFFI (Mozilla's FFI generator).

## Why This Architecture?

Imagine a restaurant. The kitchen (Rust) does all the actual cooking — generating keys, signing transactions, encrypting seeds. The front-of-house (Swift) handles the customer experience — Face ID, pretty buttons, QR codes. The kitchen never changes even if you remodel the dining room (port to Android). And the waiter (UniFFI) translates between kitchen language and front-of-house language automatically.

Why not just write everything in Swift? Because:
1. **Memory safety matters for money**. Rust's `zeroize` crate guarantees private keys are wiped from memory. Swift's ARC garbage collector might leave secrets around.
2. **Cross-platform**. Same Rust code will power the Android app later.
3. **Pure Rust crypto**. No C libraries to cross-compile. `k256` gives us secp256k1 in pure Rust.

## Project Structure

```
crypto-wallet/
├── Cargo.toml              # Rust workspace root
├── crates/
│   ├── crypto-utils/       # AES-256-GCM encryption, Argon2id KDF, zeroize wrappers
│   ├── wallet-core/        # THE FFI boundary — BIP-39, HD derivation, all exports to Swift
│   ├── chain-btc/          # Bitcoin: P2WPKH addresses, UTXO transactions, signing
│   ├── chain-eth/          # Ethereum: EIP-1559 TX, ERC-20, multi-chain support
│   └── chain-sol/          # Solana: Ed25519, manual wire format (NO solana-sdk!)
├── build-scripts/
│   ├── build-ios.sh        # Compile Rust → XCFramework + Swift bindings
│   └── build-sim.sh        # Quick simulator build for dev
├── ios/
│   └── CryptoWallet/       # SwiftUI iOS app
│       ├── App/            # App entry point
│       ├── Features/       # All screens (Onboarding, Wallet, Send, DApps, Settings)
│       ├── Services/       # WalletService, KeychainService, SecureEnclave, Biometrics
│       ├── Security/       # Jailbreak detection, anti-debug, screenshot protection
│       └── Models/         # Data models
└── docs/                   # Security, architecture, App Store notes
```

## How Data Flows

### Creating a Wallet
1. Rust generates 24-word mnemonic (256 bits of entropy from OS random)
2. Mnemonic → 64-byte seed (BIP-39 PBKDF2)
3. Rust encrypts seed: Argon2id derives key from password → AES-256-GCM encrypts
4. Swift takes encrypted blob → Secure Enclave P-256 encrypts it again (ECIES)
5. Double-encrypted blob → iOS Keychain (device-only, no iCloud, biometric-protected)
6. From seed, derive addresses: BTC (m/84'/0'/0'/0/0), ETH (m/44'/60'/0'/0/0), SOL (m/44'/501'/0'/0')

### Signing a Transaction
1. User confirms → Face ID → Keychain → SE decrypt → Rust decrypt → seed in memory
2. Rust derives private key from seed → signs transaction → returns signed bytes
3. Seed immediately zeroized from memory
4. Swift broadcasts signed TX to blockchain

## Tech Stack & Why

| Tech | Why, Not Alternative |
|------|---------------------|
| **Rust** | Memory safety + zeroize. Not Go (no zeroize), not C++ (memory bugs) |
| **k256** | Pure Rust secp256k1. Not secp256k1-sys (requires C compilation for iOS) |
| **UniFFI 0.28** | Mozilla's FFI gen. Not cbindgen (manual, error-prone) |
| **bip39 2.2** | Battle-tested, rust-bitcoin community. Not a custom impl |
| **alloy sub-crates** | Granular imports. NOT the umbrella `alloy` crate (pulls in HTTP/WS we don't need) |
| **ed25519-dalek** | Standard Ed25519. NO solana-sdk (200+ deps, tokio, cross-compile hell) |
| **AES-256-GCM** | NCC Group audited. Authenticated encryption prevents tampering |
| **Argon2id** | PHC winner, GPU-resistant. Not bcrypt (weaker), not scrypt (less studied) |
| **No analytics SDKs** | Zero telemetry. Privacy is the product |

## Security Layers (The 16 Layers)

The wallet implements 16 security layers — see `docs/SECURITY.md` for full details. Key insight: the Secure Enclave only supports P-256 curves, NOT secp256k1 (which BTC/ETH use). So we can't store blockchain keys directly in the SE. Instead:

```
Password → Argon2id → AES key → Encrypt seed (Layer 1)
                                      ↓
                              SE P-256 → Encrypt again (Layer 2)
                                      ↓
                              iOS Keychain (Layer 3)
```

Both layers must be broken. Attacker needs: your device + your face + your password + break Secure Enclave.

## Lessons Learned

### UniFFI Type Gotcha
UniFFI 0.28 passes **owned types** across the FFI boundary (`String`, `Vec<u8>`), not references (`&str`, `&[u8]`). We spent time debugging "expected `&str`, found `String`" errors. Solution: all exported functions accept owned types and borrow internally.

### bip39 2.2 API Change
The `bip39` crate doesn't have `Mnemonic::generate_in()` like some docs suggest. You need `Mnemonic::from_entropy_in()` with your own entropy, and `parse_in_normalized()` instead of `parse_in()`.

### Solana Without solana-sdk
The solana-sdk crate is enormous (pulls in tokio, 200+ deps) and has cross-compilation issues for iOS. But Solana's wire format is actually simple — it's just a compact binary format with accounts, instructions, and Ed25519 signatures. We implemented it manually in ~400 lines. Same approach as Gem Wallet (a production wallet).

### Move Out of Drop Types
Rust types that implement `Drop` (like our `DerivedKey` with zeroize-on-drop) won't let you move fields out. Need `.clone()` on non-sensitive fields like `derivation_path` before the struct drops. The compiler tells you exactly where.

### Double Encryption Math
Desktop wallets use Argon2id with 1GB memory. On iPhone, that's too much. We use m=64MB which takes ~1 second on iPhone 14+. Still GPU-resistant (attackers need 64MB per guess), but mobile-friendly.

## Build & Run

```bash
# Rust tests (241 tests total)
cargo test --workspace

# Build for iOS
./build-scripts/build-ios.sh

# Open in Xcode
open ios/CryptoWallet.xcodeproj
```

## If I Had to Rebuild This...

### What worked well
- Rust workspace with independent chain crates — each can be tested in isolation
- UniFFI for FFI — automatic, type-safe, no manual marshalling
- Pure Rust crypto — no C dependencies, clean iOS cross-compile
- Comprehensive test coverage from day 1 (241 tests)

### What I'd do differently
- Consider using `uniffi::proc_macro` instead of UDL files — less boilerplate
- Start with physical device testing earlier (SE only works on real hardware)
- Build the XCFramework pipeline on day 1 (it's the riskiest integration point)

## Current Status

Phase 1 complete:
- All 5 Rust crates implemented and tested (241 tests passing)
- iOS project skeleton with all views, services, security modules
- Build scripts for XCFramework generation
- Documentation

Next: Phase 2 (Bitcoin testnet), Phase 3 (Ethereum), Phase 4 (Solana), Phase 5 (WalletConnect), Phase 6 (Security hardening), Phase 7 (App Store).
