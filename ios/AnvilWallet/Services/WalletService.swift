import Foundation
import SwiftUI

/// WalletService is the central orchestrator for all wallet operations.
/// It coordinates between the Rust core (via UniFFI), Secure Enclave,
/// Keychain, and Biometric authentication to provide a secure wallet experience.
///
/// Security architecture:
///   1. Rust core generates mnemonic and derives keys (Argon2id + AES-256-GCM)
///   2. Encrypted seed is wrapped again by Secure Enclave P-256 key (double encryption)
///   3. Doubly-encrypted blob is stored in Keychain with biometric access control
///   4. Signing requires biometric auth -> SE decrypt -> Rust decrypt -> sign -> zeroize
final class WalletService: ObservableObject {
    static let shared = WalletService()

    private let keychain = KeychainService()
    private let secureEnclave = SecureEnclaveService()
    private let biometric = BiometricService()

    @Published var isWalletCreated: Bool = false
    @Published var addresses: [String: String] = [:] // chainId -> address
    @Published var currentWallet: WalletModel?
    @Published var tokens: [TokenModel] = []
    @Published var transactions: [TransactionModel] = []

    // Keychain storage keys
    private let encryptedSeedKey = "com.cryptowallet.encryptedSeed"
    private let walletMetadataKey = "com.cryptowallet.walletMetadata"
    private let passwordSaltKey = "com.cryptowallet.passwordSalt"

    private init() {
        isWalletCreated = keychain.exists(key: encryptedSeedKey)
        if isWalletCreated {
            loadWalletMetadata()
        }
    }

    // MARK: - Wallet Creation

    /// Creates a new wallet from a freshly generated mnemonic.
    ///
    /// Flow:
    ///   1. Generate 24-word mnemonic via Rust FFI
    ///   2. Derive master seed from mnemonic (BIP-39)
    ///   3. Encrypt seed with user password (Argon2id KDF + AES-256-GCM) via Rust
    ///   4. Create Secure Enclave P-256 key with biometric protection
    ///   5. Encrypt the already-encrypted seed with SE public key (double encryption)
    ///   6. Store doubly-encrypted blob in Keychain with kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ///   7. Derive addresses for all supported chains
    ///   8. Return mnemonic words so the user can write them down for backup
    ///
    /// - Parameter password: User-chosen password for seed encryption
    /// - Returns: Array of 24 mnemonic words for user backup
    func createWallet(password: String) async throws -> [String] {
        // TODO: Integrate Rust FFI
        // Expected Rust function signatures:
        //   fn generate_mnemonic() -> Result<String, WalletError>
        //   fn mnemonic_to_seed(mnemonic: &str) -> Result<Vec<u8>, WalletError>
        //   fn encrypt_seed(seed: &[u8], password: &str) -> Result<EncryptedData, WalletError>
        //   fn derive_address(seed: &[u8], chain: &str, index: u32) -> Result<String, WalletError>

        // Step 1: Generate mnemonic via Rust
        // let mnemonicString = try wallet_core.generate_mnemonic()
        let mnemonicString = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"
        let words = mnemonicString.split(separator: " ").map(String.init)

        // Step 2: Derive seed from mnemonic
        // let seed = try wallet_core.mnemonic_to_seed(mnemonicString)
        let seed = Data(repeating: 0, count: 64) // Placeholder

        // Step 3: Encrypt seed with password via Rust (Argon2id + AES-256-GCM)
        // let encryptedSeed = try wallet_core.encrypt_seed(seed, password)
        let encryptedSeed = seed // Placeholder - would be encrypted data

        // Step 4: Create Secure Enclave key and double-encrypt
        let seKey = try secureEnclave.createKey()
        let doubleEncrypted = try secureEnclave.encrypt(data: encryptedSeed, using: seKey)

        // Step 5: Store in Keychain with biometric protection
        try keychain.save(key: encryptedSeedKey, data: doubleEncrypted)

        // Step 6: Derive addresses for all chains
        let derivedAddresses = try deriveAddresses(seed: seed)
        self.addresses = derivedAddresses

        // Step 7: Create and save wallet metadata
        let wallet = WalletModel(
            name: "My Wallet",
            chains: ChainModel.defaults,
            addresses: derivedAddresses
        )
        try saveWalletMetadata(wallet)

        await MainActor.run {
            self.currentWallet = wallet
            self.isWalletCreated = true
            self.tokens = TokenModel.ethereumDefaults + TokenModel.solanaDefaults + TokenModel.bitcoinDefaults
        }

        return words
    }

    // MARK: - Wallet Import

    /// Imports a wallet from an existing mnemonic phrase.
    ///
    /// - Parameters:
    ///   - mnemonic: Space-separated mnemonic phrase (12 or 24 words)
    ///   - password: User-chosen password for seed encryption
    func importWallet(mnemonic: String, password: String) async throws {
        // TODO: Integrate Rust FFI
        // Expected Rust function signatures:
        //   fn validate_mnemonic(mnemonic: &str) -> Result<bool, WalletError>
        //   fn mnemonic_to_seed(mnemonic: &str) -> Result<Vec<u8>, WalletError>
        //   fn encrypt_seed(seed: &[u8], password: &str) -> Result<EncryptedData, WalletError>

        // Step 1: Validate mnemonic via Rust
        // let isValid = try wallet_core.validate_mnemonic(mnemonic)
        let words = mnemonic.split(separator: " ")
        guard words.count == 12 || words.count == 24 else {
            throw WalletError.invalidMnemonic
        }

        // Step 2: Derive seed
        // let seed = try wallet_core.mnemonic_to_seed(mnemonic)
        let seed = Data(repeating: 0, count: 64) // Placeholder

        // Step 3: Encrypt with password via Rust
        // let encryptedSeed = try wallet_core.encrypt_seed(seed, password)
        let encryptedSeed = seed // Placeholder

        // Step 4: Double-encrypt with Secure Enclave
        let seKey = try secureEnclave.createKey()
        let doubleEncrypted = try secureEnclave.encrypt(data: encryptedSeed, using: seKey)

        // Step 5: Store in Keychain
        try keychain.save(key: encryptedSeedKey, data: doubleEncrypted)

        // Step 6: Derive addresses
        let derivedAddresses = try deriveAddresses(seed: seed)
        self.addresses = derivedAddresses

        // Step 7: Save metadata
        let wallet = WalletModel(
            name: "Imported Wallet",
            chains: ChainModel.defaults,
            addresses: derivedAddresses
        )
        try saveWalletMetadata(wallet)

        await MainActor.run {
            self.currentWallet = wallet
            self.isWalletCreated = true
            self.tokens = TokenModel.ethereumDefaults + TokenModel.solanaDefaults + TokenModel.bitcoinDefaults
        }
    }

    // MARK: - Address Derivation

    /// Derives addresses for all supported chains from the master seed.
    ///
    /// Uses BIP-44 derivation paths:
    ///   - Ethereum & EVM chains: m/44'/60'/0'/0/0
    ///   - Solana: m/44'/501'/0'/0'
    ///   - Bitcoin: m/84'/0'/0'/0/0 (native segwit)
    ///
    /// - Parameter seed: The master seed bytes
    /// - Returns: Dictionary mapping chain IDs to derived addresses
    func deriveAddresses(seed: Data) throws -> [String: String] {
        // TODO: Integrate Rust FFI
        // Expected Rust function signature:
        //   fn derive_address(seed: &[u8], chain: &str, index: u32) -> Result<String, WalletError>

        var addresses: [String: String] = [:]

        for chain in ChainModel.defaults {
            // let address = try wallet_core.derive_address(seed, chain.id, 0)
            switch chain.chainType {
            case .evm:
                addresses[chain.id] = "0x0000000000000000000000000000000000000000" // Placeholder
            case .solana:
                addresses[chain.id] = "11111111111111111111111111111111" // Placeholder
            case .bitcoin:
                addresses[chain.id] = "bc1q000000000000000000000000000000000000000" // Placeholder
            }
        }

        return addresses
    }

    // MARK: - Transaction Signing

    /// Signs a transaction for a given chain.
    ///
    /// Flow:
    ///   1. Authenticate with biometrics
    ///   2. Load doubly-encrypted seed from Keychain
    ///   3. Decrypt outer layer with Secure Enclave (requires biometric)
    ///   4. Decrypt inner layer with password via Rust
    ///   5. Sign transaction with Rust core
    ///   6. Zeroize seed material immediately after signing
    ///
    /// - Parameters:
    ///   - chain: The chain ID to sign for
    ///   - txData: Raw transaction data to sign
    /// - Returns: Signed transaction bytes
    func signTransaction(chain: String, txData: Data) async throws -> Data {
        // Step 1: Biometric authentication
        let authenticated = try await biometric.authenticate(
            reason: "Authenticate to sign transaction"
        )
        guard authenticated else {
            throw WalletError.authenticationFailed
        }

        // Step 2: Load encrypted seed from Keychain
        guard let doubleEncrypted = try keychain.load(key: encryptedSeedKey) else {
            throw WalletError.seedNotFound
        }

        // Step 3: Decrypt with Secure Enclave
        let encryptedSeed = try secureEnclave.decrypt(data: doubleEncrypted)

        // Step 4: Decrypt with password via Rust
        // TODO: Integrate Rust FFI
        // let seed = try wallet_core.decrypt_seed(encryptedSeed, password)
        let seed = encryptedSeed // Placeholder

        // Step 5: Sign transaction via Rust
        // TODO: Integrate Rust FFI
        // Expected Rust function signature:
        //   fn sign_transaction(seed: &[u8], chain: &str, tx_data: &[u8]) -> Result<Vec<u8>, WalletError>
        // let signedTx = try wallet_core.sign_transaction(seed, chain, txData)
        let signedTx = Data() // Placeholder

        // Step 6: Zeroize seed material
        // Rust side handles zeroization via zeroize crate
        // Swift side: seed variable goes out of scope

        return signedTx
    }

    // MARK: - Balance & Price Updates

    /// Refreshes token balances for all chains.
    func refreshBalances() async throws {
        // TODO: Integrate RPCService to fetch balances for each chain/token
        // For each token, call the appropriate RPC endpoint:
        //   EVM: eth_getBalance, eth_call (for ERC-20 balanceOf)
        //   Solana: getBalance, getTokenAccountsByOwner
        //   Bitcoin: address/utxo endpoint
    }

    /// Refreshes token prices from price service.
    func refreshPrices() async throws {
        let priceService = PriceService()
        let symbols = tokens.map { $0.symbol.lowercased() }
        let prices = try await priceService.fetchPrices(for: symbols)

        await MainActor.run {
            for index in tokens.indices {
                let key = tokens[index].symbol.lowercased()
                if let price = prices[key] {
                    tokens[index].priceUsd = price
                }
            }
        }
    }

    // MARK: - Wallet Deletion

    /// Deletes the wallet and all associated data.
    /// This is irreversible -- the user must have their mnemonic backup.
    func deleteWallet() throws {
        try keychain.delete(key: encryptedSeedKey)
        try keychain.delete(key: walletMetadataKey)
        try keychain.delete(key: passwordSaltKey)

        currentWallet = nil
        addresses = [:]
        tokens = []
        transactions = []
        isWalletCreated = false
    }

    // MARK: - Private Helpers

    private func saveWalletMetadata(_ wallet: WalletModel) throws {
        let data = try JSONEncoder().encode(wallet)
        try keychain.save(key: walletMetadataKey, data: data)
    }

    private func loadWalletMetadata() {
        guard let data = try? keychain.load(key: walletMetadataKey),
              let wallet = try? JSONDecoder().decode(WalletModel.self, from: data) else {
            return
        }
        currentWallet = wallet
        addresses = wallet.addresses
        tokens = TokenModel.ethereumDefaults + TokenModel.solanaDefaults + TokenModel.bitcoinDefaults
    }
}

// MARK: - Wallet Errors

enum WalletError: LocalizedError {
    case invalidMnemonic
    case seedNotFound
    case encryptionFailed
    case decryptionFailed
    case authenticationFailed
    case keyDerivationFailed
    case signingFailed
    case networkError(String)
    case rustFFIError(String)

    var errorDescription: String? {
        switch self {
        case .invalidMnemonic:
            return "Invalid mnemonic phrase. Please check your words and try again."
        case .seedNotFound:
            return "Wallet seed not found. The wallet may need to be restored."
        case .encryptionFailed:
            return "Failed to encrypt wallet data."
        case .decryptionFailed:
            return "Failed to decrypt wallet data. Incorrect password?"
        case .authenticationFailed:
            return "Biometric authentication failed."
        case .keyDerivationFailed:
            return "Failed to derive keys from seed."
        case .signingFailed:
            return "Failed to sign the transaction."
        case .networkError(let message):
            return "Network error: \(message)"
        case .rustFFIError(let message):
            return "Internal error: \(message)"
        }
    }
}
