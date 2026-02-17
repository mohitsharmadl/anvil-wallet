# Architecture

## Overview

```
┌─────────────────────────────────────────────────┐
│                  Swift UI (iOS)                   │
│                                                   │
│  ┌──────────┐  ┌──────────┐  ┌────────────────┐ │
│  │ Features │  │ Services │  │   Security     │ │
│  │ (Views)  │  │          │  │   Module       │ │
│  └────┬─────┘  └────┬─────┘  └────────────────┘ │
│       │              │                            │
│       └──────┬───────┘                            │
│              │                                    │
│     ┌────────▼────────┐                          │
│     │  WalletService   │ ← Orchestrator          │
│     │  (SE + Keychain  │                          │
│     │   + Biometrics)  │                          │
│     └────────┬────────┘                          │
└──────────────┼───────────────────────────────────┘
               │ UniFFI (C FFI)
┌──────────────▼───────────────────────────────────┐
│               Rust Core (wallet-core)             │
│                                                   │
│  ┌──────────────┐  ┌──────────────┐             │
│  │ crypto-utils  │  │  wallet-core │ ← FFI      │
│  │ (AES, Argon2) │  │ (BIP39, HD)  │  boundary  │
│  └──────────────┘  └──────────────┘             │
│                                                   │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐      │
│  │ chain-btc│  │ chain-eth│  │ chain-sol│      │
│  │ (Bitcoin) │  │ (EVM)    │  │ (Solana) │      │
│  └──────────┘  └──────────┘  └──────────┘      │
└──────────────────────────────────────────────────┘
```

## Rust Crate Dependency Graph

```
wallet-core (FFI boundary)
├── crypto-utils (AES-GCM, Argon2id, zeroize)
├── chain-btc (Bitcoin P2WPKH)
├── chain-eth (Ethereum EIP-1559, ERC-20)
└── chain-sol (Solana Ed25519, SPL)
```

All chain crates are independent. `wallet-core` depends on all of them and exposes a unified FFI interface.

## Data Flow: Create Wallet

```
1. User taps "Create Wallet"
2. Swift: WalletService.createWallet(password:)
3. Rust FFI: generate_mnemonic() → 24 words
4. Swift: Display words for backup
5. User verifies backup
6. Rust FFI: mnemonic_to_seed(words, passphrase) → 64-byte seed
7. Rust FFI: encrypt_seed_with_password(seed, password) → encrypted blob
8. Swift: SecureEnclaveService.encrypt(encrypted_blob) → double-encrypted
9. Swift: KeychainService.save("wallet_seed", double_encrypted)
10. Rust FFI: derive_all_addresses(seed) → BTC, ETH, SOL addresses
11. Swift: Store addresses in WalletService
12. Navigate to wallet home
```

## Data Flow: Sign Transaction

```
1. User enters send details (to, amount, chain)
2. Swift: RPCService fetches gas/fee estimates
3. Swift: TransactionSimulator.simulate() (ETH only)
4. User confirms, taps "Send"
5. Swift: BiometricService.authenticate("Confirm transaction")
6. Swift: KeychainService.load("wallet_seed") → double-encrypted
7. Swift: SecureEnclaveService.decrypt(double_encrypted) → encrypted
8. Rust FFI: decrypt_seed_with_password(encrypted, password) → seed
9. Rust FFI: sign_eth_transaction(seed, ...) → signed_tx bytes
10. Swift: RPCService.broadcastTransaction(signed_tx)
11. Zeroize seed in memory
12. Show result
```

## Key Design Decisions

### Why Rust for Crypto?
- Memory safety without garbage collection
- `zeroize` crate guarantees sensitive data cleanup
- Pure Rust crypto (k256) — no C FFI for simpler iOS cross-compile
- Same code compiles for iOS, Android, desktop

### Why UniFFI (not manual C FFI)?
- Auto-generates type-safe Swift bindings from UDL file
- Handles String/Vec/Result marshalling automatically
- Mozilla-maintained, used in Firefox

### Why No solana-sdk?
- Pulls in tokio runtime + 200+ dependencies
- iOS cross-compilation issues with tokio
- Solana wire format is simple enough to implement manually (~400 lines)
- Same approach as Gem Wallet (production wallet)

### Why k256 Instead of secp256k1-sys?
- Pure Rust — no C compilation step
- Simpler iOS cross-compile (no libsecp256k1 C library)
- RustCrypto ecosystem, actively maintained
- Performance is adequate for wallet use (signing, not mining)

### Why Secure Enclave + Argon2id (Double Encryption)?
- SE alone only supports P-256, not secp256k1
- Can't store BTC/ETH keys directly in SE
- Solution: SE encrypts the encrypted seed
- Attacker needs: device access + biometric + password + SE compromise
