# FOR-Mohit: Anvil Wallet

## What Is This?

**Anvil Wallet** — a self-custody crypto wallet for iOS (Android later). Think Trust Wallet or MetaMask mobile, but built from scratch with paranoid-level security. Supports BTC, ETH, all EVM chains (Polygon, Arbitrum, Base, etc.), and Solana. Ships to App Store with WalletConnect support so you can connect to Uniswap, OpenSea, etc.

The key architectural decision: **all crypto logic lives in Rust**, and the iOS app just handles UI + device security features (Secure Enclave, Keychain, Face ID). The Rust code talks to Swift via UniFFI (Mozilla's FFI generator).

## Why This Architecture?

Imagine a restaurant. The kitchen (Rust) does all the actual cooking — generating keys, signing transactions, encrypting seeds. The front-of-house (Swift) handles the customer experience — Face ID, pretty buttons, QR codes. The kitchen never changes even if you remodel the dining room (port to Android). And the waiter (UniFFI) translates between kitchen language and front-of-house language automatically.

Why not just write everything in Swift? Because:
1. **Memory safety matters for money**. Rust's `zeroize` crate guarantees private keys are wiped from memory. Swift's ARC garbage collector might leave secrets around.
2. **Cross-platform**. Same Rust code will power the Android app later.
3. **Pure Rust crypto**. No C libraries to cross-compile. `k256` gives us secp256k1 in pure Rust.

## Project Structure

```
anvil-wallet/
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
│   └── AnvilWallet/       # SwiftUI iOS app
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
open ios/AnvilWallet.xcodeproj
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

Phase 1 complete + security hardening pass:
- All 5 Rust crates implemented and tested (241 tests passing)
- iOS app wired to real Rust FFI (create, import, derive, sign)
- EVM + Solana transaction signing fully wired (BTC planned — needs UTXO mgmt)
- Security modules hardened (see Codex review below)
- Build scripts for XCFramework generation
- Documentation

Next: Phase 2 (Bitcoin UTXO signing), Phase 5 (WalletConnect), Phase 7 (App Store).

---

## Codex Security Review — Feb 2026

A comprehensive security review (Codex) identified 10 issues in the iOS app. Here's what was found, what was fixed, and what was deferred.

### Finding 1: All Rust FFI calls were placeholders
**Severity:** Critical
**What:** `WalletService.swift` used hardcoded "abandon abandon..." mnemonic, zero-byte seeds, and fake tx hashes. Nothing was actually calling the Rust core.
**Fix:** Rewrote `createWallet()`, `importWallet()`, `deriveAddresses()`, and `signTransaction()` to call real UniFFI-exported functions (`generateMnemonic()`, `mnemonicToSeed()`, `encryptSeedWithPassword()`, `deriveAllAddressesFromMnemonic()`, `signEthTransaction()`, `signSolTransfer()`). Added `TransactionRequest` enum for typed signing.
**Lesson:** Build FFI integration tests early. A working UI with zero backend is dangerous because it *looks* done.

### Finding 2: Seed not zeroized in Rust signing functions
**Severity:** High
**What:** `sign_eth_transaction()` and `sign_sol_transfer()` in `lib.rs` accepted `seed: Vec<u8>` but never zeroized it. The seed could linger in memory after signing.
**Fix:** Added `mut` to seed parameters, added `seed.zeroize()` before `Ok(...)` return in both functions. Also added zeroization to `encrypt_seed_with_password()`.
**Lesson:** Rust's `zeroize` crate is great, but you have to actually call it on function parameters that aren't wrapped in `ZeroizeOnDrop` structs.

### Finding 3: No session password management
**Severity:** High
**What:** The signing flow needed a password to decrypt the seed, but there was no mechanism to cache or prompt for it.
**Fix:** Added `sessionPassword` in-memory cache to `WalletService`. Password is set during create/import and cleared when the app enters background (via `scenePhase` observer in `AnvilWalletApp`). Added `WalletError.passwordRequired` case.
**Design decision:** Cache in memory rather than prompt every transaction — better UX while still clearing on background.

### Finding 4: Transaction signing used fake hashes
**Severity:** Critical
**What:** `ConfirmTransactionView.signAndSend()` just slept 2 seconds and returned `UUID().uuidString` as the transaction hash.
**Fix:** Wired to real flow: fetch nonce + gas → build `TransactionRequest` → `walletService.signTransaction()` → `RPCService.shared.sendRawTransaction()`. Removed hardcoded $3,500 ETH price.

### Finding 5: No BIP-39 word validation in import flow
**Severity:** Medium
**What:** `ImportWalletView` only checked word count (12 or 24), not whether words were valid BIP-39 words or whether the checksum was correct.
**Fix:** Added real-time per-word validation via `isValidBip39Word()` (highlights invalid words), plus full `validateMnemonic()` call before proceeding. Also clears clipboard after pasting mnemonic.

### Finding 6: Password policy too weak
**Severity:** Medium
**What:** `PasswordStrength.fair` passed `meetsMinimum`, meaning a password with just 2 of 5 criteria could proceed.
**Fix:** Changed `meetsMinimum` to require `.strong` or `.veryStrong`. Scoring now requires ALL four criteria (length>=8, uppercase, digit, special char) for `.strong`. Length>=12 + all four criteria = `.veryStrong`.

### Finding 7: WalletConnect URI logged with full symKey
**Severity:** Medium
**What:** `pair(uri:)` printed the full URI including the symmetric key.
**Fix:** Regex replacement of `symKey=[^&]+` → `symKey=REDACTED` before logging.

### Finding 8: Certificate pinning was a comment/TODO
**Severity:** High
**What:** `RPCService` had `// TODO: Phase 3 - Configure TrustKit certificate pinning delegate` and used a plain `URLSession`.
**Fix:** Created `CertificatePinner.swift` — a native `URLSessionDelegate` that validates server certificates against pinned SHA-256 public key hashes. Wired it to `RPCService`'s session. Pin hashes left empty for now (need real certs at build time) — hosts without pins fall through to default OS validation.
**Deferred:** TrustKit integration (adds a dependency). Native pinning is sufficient for now.

### Finding 9: App integrity checker was a stub
**Severity:** Medium
**What:** `checkExecutableIntegrity()` just checked if the file was readable. `checkBundleSignature()` used `"com.cryptowallet"` prefix.
**Fix:** Implemented real SHA-256 hash comparison via CryptoKit (skipped in DEBUG builds). Fixed bundle ID to `"com.anvilwallet"`. Added `exit(0)` in Release builds when integrity check fails.
**Deferred:** Build-time hash injection script (needs Xcode build phase setup).

### Finding 10: Bundle ID still "com.cryptowallet" everywhere
**Severity:** Low
**What:** 7 occurrences of `"com.cryptowallet"` across WalletService, KeychainService, SecureEnclaveService, AppIntegrityChecker, SecurityBootstrap.
**Fix:** Global rename to `"com.anvilwallet"`. Verified zero remaining occurrences.

### What Was Deferred
- **BTC transaction signing** — needs UTXO management (fetching, selecting, change addresses). Out of scope for this review.
- **Build-time hash injection** — `AppIntegrityChecker` has the comparison code but needs an Xcode build phase script to compute and inject the expected hash.
- **Real certificate pin hashes** — `CertificatePinner` is wired up but pin dictionaries are empty. Need to extract SPKI hashes from production RPC endpoint certificates.
- **TrustKit** — native pinning covers the same attack surface. TrustKit adds reporting capabilities if needed later.
