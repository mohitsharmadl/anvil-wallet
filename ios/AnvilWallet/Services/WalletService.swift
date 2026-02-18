import Foundation
import SwiftUI

// MARK: - Transaction Request Types

/// Typed transaction request for signing — ensures correct parameters per chain.
enum TransactionRequest {
    case eth(EthTransactionRequest)
    case sol(SolTransactionRequest)
    case btc(BtcTransactionRequest)
}

struct EthTransactionRequest {
    let chainId: UInt64
    let nonce: UInt64
    let to: String
    let valueWeiHex: String
    let data: Data
    let maxPriorityFeeHex: String
    let maxFeeHex: String
    let gasLimit: UInt64
}

struct SolTransactionRequest {
    let to: String
    let lamports: UInt64
    let recentBlockhash: Data // 32 bytes
}

struct BtcTransactionRequest {
    let utxos: [UtxoData]
    let recipientAddress: String
    let amountSat: UInt64
    let changeAddress: String
    let feeRateSatVbyte: UInt64
    let isTestnet: Bool
}

// MARK: - WalletService

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
    private let encryptedSeedKey = "com.anvilwallet.encryptedSeed"
    private let walletMetadataKey = "com.anvilwallet.walletMetadata"
    private let passwordSaltKey = "com.anvilwallet.passwordSalt"

    /// In-memory session password stored as raw bytes for explicit zeroization.
    /// Swift String instances are immutable and may linger in memory after deallocation.
    /// ContiguousArray<UInt8> allows us to overwrite every byte before releasing.
    private var sessionPasswordBytes: ContiguousArray<UInt8>?

    private init() {
        isWalletCreated = keychain.exists(key: encryptedSeedKey)
        if isWalletCreated {
            loadWalletMetadata()
        }
    }

    /// Whether the session password is currently cached in memory.
    var hasSessionPassword: Bool {
        sessionPasswordBytes != nil
    }

    /// Clears the cached session password. Zeros all bytes in-place before releasing.
    /// Called when the app enters background.
    ///
    /// Note: `if var bytes = ...` would copy due to Swift copy-on-write.
    /// We must mutate the stored property directly to zero the actual backing storage.
    func clearSessionPassword() {
        if sessionPasswordBytes != nil {
            for i in sessionPasswordBytes!.indices { sessionPasswordBytes![i] = 0 }
        }
        sessionPasswordBytes = nil
    }

    /// Sets the session password after user re-enters it (e.g. after returning from background).
    /// Validates the password by attempting a decrypt round-trip before accepting it.
    func setSessionPassword(_ password: String) async throws {
        // Validate by loading the encrypted seed and attempting decryption
        guard let doubleEncrypted = try keychain.load(key: encryptedSeedKey) else {
            throw WalletError.seedNotFound
        }

        let packed = try secureEnclave.decrypt(data: doubleEncrypted)
        let (salt, ciphertext) = try unpackSaltAndCiphertext(from: packed)

        // This will throw if the password is wrong
        var seedBytes = try decryptSeedWithPassword(
            ciphertext: [UInt8](ciphertext),
            salt: [UInt8](salt),
            password: password
        )

        // Zeroize immediately — we only needed to verify the password works
        for i in seedBytes.indices { seedBytes[i] = 0 }

        sessionPasswordBytes = ContiguousArray(password.utf8)
    }

    // MARK: - Combined Data Packing
    // Format: [4-byte big-endian salt length][salt bytes][ciphertext bytes]

    private func packSaltAndCiphertext(salt: Data, ciphertext: Data) -> Data {
        var packed = Data()
        var saltLen = UInt32(salt.count).bigEndian
        packed.append(Data(bytes: &saltLen, count: 4))
        packed.append(salt)
        packed.append(ciphertext)
        return packed
    }

    private func unpackSaltAndCiphertext(from data: Data) throws -> (salt: Data, ciphertext: Data) {
        guard data.count > 4 else {
            throw WalletError.decryptionFailed
        }
        // Parse 4-byte big-endian length manually to avoid unaligned memory access
        let b0 = UInt32(data[data.startIndex])
        let b1 = UInt32(data[data.startIndex + 1])
        let b2 = UInt32(data[data.startIndex + 2])
        let b3 = UInt32(data[data.startIndex + 3])
        let saltLen = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
        let saltStart = data.startIndex + 4
        let saltEnd = saltStart + saltLen
        guard data.endIndex >= saltEnd else {
            throw WalletError.decryptionFailed
        }
        let salt = data[saltStart..<saltEnd]
        let ciphertext = data[saltEnd...]
        return (salt: Data(salt), ciphertext: Data(ciphertext))
    }

    // MARK: - Wallet Creation

    /// Creates a new wallet from a freshly generated mnemonic.
    ///
    /// Flow:
    ///   1. Generate 24-word mnemonic via Rust FFI
    ///   2. Encrypt seed with user password (Argon2id KDF + AES-256-GCM) via Rust
    ///   3. Create Secure Enclave P-256 key with biometric protection
    ///   4. Encrypt the already-encrypted seed with SE public key (double encryption)
    ///   5. Store doubly-encrypted blob in Keychain
    ///   6. Derive addresses for all supported chains from mnemonic
    ///   7. Return mnemonic words so the user can write them down for backup
    ///
    /// - Parameter password: User-chosen password for seed encryption
    /// - Returns: Array of 24 mnemonic words for user backup
    func createWallet(password: String) async throws -> [String] {
        // Step 1: Generate mnemonic via Rust
        let mnemonicString = try generateMnemonic()
        let words = mnemonicString.split(separator: " ").map(String.init)

        // Step 2: Derive seed and encrypt with password via Rust (Argon2id + AES-256-GCM)
        let seedBytes = try mnemonicToSeed(mnemonicPhrase: mnemonicString, passphrase: "")
        let encrypted = try encryptSeedWithPassword(seed: [UInt8](seedBytes), password: password)
        let packed = packSaltAndCiphertext(
            salt: Data(encrypted.salt),
            ciphertext: Data(encrypted.ciphertext)
        )

        // Step 3: Create Secure Enclave key and double-encrypt
        let seKey = try secureEnclave.createKey()
        let doubleEncrypted = try secureEnclave.encrypt(data: packed, using: seKey)

        // Step 4: Store in Keychain with biometric protection
        try keychain.save(key: encryptedSeedKey, data: doubleEncrypted)

        // Step 5: Cache session password as zeroizable bytes
        sessionPasswordBytes = ContiguousArray(password.utf8)

        // Step 6: Derive addresses from mnemonic (not raw seed)
        let derivedAddresses = try deriveAddresses(mnemonic: mnemonicString)
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
        // Step 1: Validate mnemonic via Rust
        let isValid = try validateMnemonic(phrase: mnemonic)
        guard isValid else {
            throw WalletError.invalidMnemonic
        }

        // Step 2: Derive seed and encrypt with password via Rust
        let seedBytes = try mnemonicToSeed(mnemonicPhrase: mnemonic, passphrase: "")
        let encrypted = try encryptSeedWithPassword(seed: [UInt8](seedBytes), password: password)
        let packed = packSaltAndCiphertext(
            salt: Data(encrypted.salt),
            ciphertext: Data(encrypted.ciphertext)
        )

        // Step 3: Double-encrypt with Secure Enclave
        let seKey = try secureEnclave.createKey()
        let doubleEncrypted = try secureEnclave.encrypt(data: packed, using: seKey)

        // Step 4: Store in Keychain
        try keychain.save(key: encryptedSeedKey, data: doubleEncrypted)

        // Step 5: Cache session password as zeroizable bytes
        sessionPasswordBytes = ContiguousArray(password.utf8)

        // Step 6: Derive addresses from mnemonic
        let derivedAddresses = try deriveAddresses(mnemonic: mnemonic)
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

    /// Derives addresses for all supported chains from a mnemonic phrase.
    ///
    /// Uses BIP-44 derivation paths via Rust FFI:
    ///   - Ethereum & EVM chains: m/44'/60'/0'/0/0 (shared address)
    ///   - Solana: m/44'/501'/0'/0'
    ///   - Bitcoin: m/84'/0'/0'/0/0 (native segwit)
    ///
    /// - Parameter mnemonic: The BIP-39 mnemonic phrase
    /// - Returns: Dictionary mapping chain IDs to derived addresses
    func deriveAddresses(mnemonic: String) throws -> [String: String] {
        // Call Rust to derive BTC, ETH, SOL addresses in one shot
        let rustAddresses = try deriveAllAddressesFromMnemonic(
            mnemonicPhrase: mnemonic,
            passphrase: "",
            account: 0
        )

        var addresses: [String: String] = [:]

        // Map Rust Chain enum results to our ChainModel IDs
        for derived in rustAddresses {
            switch derived.chain {
            case .ethereum:
                // EVM chains all share the ETH address
                for chain in ChainModel.defaults where chain.chainType == .evm {
                    addresses[chain.id] = derived.address
                }
            case .solana:
                addresses["solana"] = derived.address
            case .bitcoin:
                addresses["bitcoin"] = derived.address
            default:
                break
            }
        }

        return addresses
    }

    // MARK: - Transaction Signing

    /// Signs a transaction using the stored encrypted seed.
    ///
    /// Flow:
    ///   1. Authenticate with biometrics
    ///   2. Load doubly-encrypted seed from Keychain
    ///   3. Decrypt outer layer with Secure Enclave (requires biometric)
    ///   4. Unpack salt + ciphertext from combined data
    ///   5. Decrypt inner layer with password via Rust
    ///   6. Sign transaction with Rust core
    ///   7. Zeroize seed material immediately after signing
    ///
    /// - Parameter request: Typed transaction request (ETH or SOL)
    /// - Returns: Signed transaction bytes
    func signTransaction(request: TransactionRequest) async throws -> Data {
        // Step 1: Ensure we have the session password
        // Convert from zeroizable bytes to String for the Rust FFI call.
        // This creates a short-lived String copy — unavoidable since UniFFI accepts String.
        guard let pwBytes = sessionPasswordBytes else {
            throw WalletError.passwordRequired // Caller should show password re-entry UI
        }
        let password = String(decoding: pwBytes, as: UTF8.self)

        // Step 2: Biometric authentication
        let authenticated = try await biometric.authenticate(
            reason: "Authenticate to sign transaction"
        )
        guard authenticated else {
            throw WalletError.authenticationFailed
        }

        // Step 3: Load encrypted seed from Keychain
        guard let doubleEncrypted = try keychain.load(key: encryptedSeedKey) else {
            throw WalletError.seedNotFound
        }

        // Step 4: Decrypt with Secure Enclave
        let packed = try secureEnclave.decrypt(data: doubleEncrypted)

        // Step 5: Unpack salt + ciphertext and decrypt with password via Rust
        let (salt, ciphertext) = try unpackSaltAndCiphertext(from: packed)
        var seedBytes = try decryptSeedWithPassword(
            ciphertext: [UInt8](ciphertext),
            salt: [UInt8](salt),
            password: password
        )

        // Step 6: Sign transaction via Rust (seed is zeroized in Rust after signing)
        defer {
            // Also zeroize the Swift-side copy
            for i in seedBytes.indices { seedBytes[i] = 0 }
        }

        let signedTx: Data
        switch request {
        case .eth(let ethReq):
            let result = try signEthTransaction(
                seed: seedBytes,
                passphrase: "",
                account: 0,
                index: 0,
                chainId: ethReq.chainId,
                nonce: ethReq.nonce,
                toAddress: ethReq.to,
                valueWeiHex: ethReq.valueWeiHex,
                data: [UInt8](ethReq.data),
                maxPriorityFeeHex: ethReq.maxPriorityFeeHex,
                maxFeeHex: ethReq.maxFeeHex,
                gasLimit: ethReq.gasLimit
            )
            signedTx = Data(result)

        case .sol(let solReq):
            let result = try signSolTransfer(
                seed: seedBytes,
                account: 0,
                toAddress: solReq.to,
                lamports: solReq.lamports,
                recentBlockhash: [UInt8](solReq.recentBlockhash)
            )
            signedTx = Data(result)

        case .btc(let btcReq):
            let result = try signBtcTransaction(
                seed: seedBytes,
                account: 0,
                index: 0,
                utxos: btcReq.utxos,
                recipientAddress: btcReq.recipientAddress,
                amountSat: btcReq.amountSat,
                changeAddress: btcReq.changeAddress,
                feeRateSatVbyte: btcReq.feeRateSatVbyte,
                isTestnet: btcReq.isTestnet
            )
            signedTx = Data(result)
        }

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

        // Zero password bytes in-place before releasing (avoid COW copy)
        if sessionPasswordBytes != nil {
            for i in sessionPasswordBytes!.indices { sessionPasswordBytes![i] = 0 }
        }
        sessionPasswordBytes = nil
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
    case passwordRequired
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
        case .passwordRequired:
            return "Password required. Please re-enter your password."
        case .networkError(let message):
            return "Network error: \(message)"
        case .rustFFIError(let message):
            return "Internal error: \(message)"
        }
    }
}
