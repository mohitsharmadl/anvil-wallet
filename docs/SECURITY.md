# Security Architecture

## 16 Security Layers

### Layer 1: Secure Enclave (Hardware)
- P-256 key stored in Secure Enclave
- Used to encrypt the master seed (ECIES)
- Key is non-extractable — operations happen inside the SE chip
- Biometric gated: Face ID/Touch ID required for decryption

### Layer 2: iOS Keychain
- Encrypted seed stored with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- `kSecAttrSynchronizable: false` — no iCloud sync, ever
- Data is bound to the device and cannot be extracted via backup

### Layer 3: BIP-39 Mnemonic + Optional Passphrase
- 24-word mnemonic (256 bits of entropy)
- Optional 25th word (passphrase) for plausible deniability
- Passphrase creates entirely different wallet from same mnemonic

### Layer 4: AES-256-GCM Encryption at Rest
- Seed encrypted with AES-256-GCM in Rust (aes-gcm 0.10, NCC Group audited)
- 12-byte random nonce per encryption
- Authentication tag prevents tampering

### Layer 5: Argon2id KDF
- Password → encryption key via Argon2id (PHC competition winner)
- Parameters: m=64MB, t=3 iterations, p=4 parallelism
- GPU/ASIC resistant — 64MB memory requirement per attempt
- ~1 second on iPhone 14+

### Layer 6: Biometric Auth for Transactions
- Every transaction requires Face ID / Touch ID
- Uses `.biometryCurrentSet` — invalidates if biometrics change
- Falls back to device passcode only if explicitly configured

### Layer 7: Jailbreak Detection (6 sub-layers)
1. File existence checks (Cydia, sshd, apt, etc.)
2. Symlink detection for suspicious paths
3. Sandbox writability test (/private)
4. Dynamic library inspection (dyld)
5. fork() test (should fail in sandbox)
6. URL scheme checks (cydia://)

### Layer 8: Anti-Screenshot
- Sensitive screens protected via UITextField.isSecureTextEntry overlay
- App blurs content on backgrounding (willResignActive)
- Prevents screen recording of seed phrases and private data

### Layer 9: Clipboard Auto-Clear
- Copied addresses/data cleared after 120 seconds
- Uses UIPasteboard.general with scheduled clearing

### Layer 10: Certificate Pinning + TLS Policy

**Pinned hosts (SPKI SHA-256, fail-closed):**
- Native `URLSessionDelegate` with SPKI SHA-256 pin validation
- Constructs proper SubjectPublicKeyInfo DER for RSA and ECDSA keys before hashing
- 12 hosts pinned with dual SPKI hashes (leaf certificate + intermediate CA) per host
- Covers all RPC endpoints (Alchemy, Blockstream, Solana RPC), block explorers (Etherscan), and price APIs (CoinGecko)
- Fail-closed: any host not in the pinning table is rejected via `.cancelAuthenticationChallenge`
- Handles both RSA (dynamic ASN.1 header) and ECDSA (P-256/P-384) key types
- Pin updates are operationally owned: `build-scripts/extract-spki-pins.sh` regenerates all pins

**Standard TLS hosts (OS trust store validation, not pinned):**
- WalletConnect relay (`relay.walletconnect.com`) — Reown-managed, rotates certs without notice
- Swap aggregator APIs (`quote-api.jup.ag`, `api.0x.org`) — third-party, frequent cert rotation

**Rationale:** Pinning high-churn third-party endpoints creates an availability-as-security risk — a cert rotation by the provider silently breaks the feature for all users until an app update ships. Standard TLS validation still verifies the full certificate chain against the OS trust store. The tradeoff is: pinned hosts get MITM protection even if the OS trust store is compromised; standard TLS hosts get protection against everything except a compromised CA.

**Rollback plan:** If a swap or WC provider is found to be actively targeted, pins can be added to `CertificatePinner.pinnedHashes` and the session delegate swapped in — this is a code change, not an architecture change.

### Layer 11: Memory Zeroization
- Rust: `zeroize` crate with `ZeroizeOnDrop` derive
- All seed material, private keys, and mnemonics zeroed on drop
- Swift: explicit memset for sensitive Data objects
- No sensitive data persists in memory after use

### Layer 12: Anti-Debugging
- `ptrace(PT_DENY_ATTACH)` prevents debugger attachment
- `sysctl` check for P_TRACED flag
- Both checks run at app launch

### Layer 13: App Binary Integrity
- Mach-O header verification (MH_PIE flag)
- Executable SHA-256 hash validation (CryptoKit)
- Build script (`build-scripts/inject-binary-hash.sh`) runs as an Xcode Build Phase
- Release builds: computes SHA-256 of the compiled executable and injects it as a Swift constant
- Runtime check compares the running binary's hash against the injected expected hash
- DEBUG builds skip hash check to avoid false positives during development
- Release builds exit(0) on integrity failure (hash mismatch)

### Layer 14: Transaction Simulation
- Pre-sign simulation via `eth_call` for EVM transactions
- Estimates gas and detects revert conditions
- User sees simulation result before signing

### Layer 15: Address Validation
- Format validation per chain (bech32, EIP-55, Base58)
- Address poisoning detection (first/last char matching)
- Checksum verification where applicable

### Layer 16: Zero Telemetry
- No analytics SDKs
- No crash reporting SDKs
- No third-party data collection
- Only outbound connections: blockchain RPC nodes + price API

## Double Encryption Flow

```
User Password
    │
    ▼
Argon2id (m=64MB, t=3, p=4)
    │
    ▼
AES-256-GCM Key
    │
    ▼
Encrypted Seed (Layer 1 - Rust)
    │
    ▼
Secure Enclave P-256 ECIES
    │
    ▼
Double-Encrypted Seed → iOS Keychain
```

Both the password-derived AES key AND the Secure Enclave key must be compromised to access the seed.

## Threat Model

| Threat | Mitigation |
|--------|-----------|
| Device theft | Biometric + password + device encryption |
| Jailbreak | 6-layer detection, exit on detection |
| MITM on RPC/APIs | SPKI pinning (12 RPC/explorer/price hosts, fail-closed); standard TLS for WC relay + swap aggregators (high-churn third-party infra) |
| Memory dump | Zeroize all sensitive data on drop |
| Screenshot/recording | Anti-screenshot overlay + blur |
| Debugger attachment | ptrace + sysctl checks |
| Clipboard sniffing | Auto-clear after 2 minutes |
| Supply chain | Zero third-party SDKs (except Reown SDK for WalletConnect) |
| iCloud backup | Keychain data not synced, not included in backups |
