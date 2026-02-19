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

    /// All HD accounts derived from the same seed.
    @Published var accounts: [WalletModel] = []

    /// Currently active account index.
    @Published var activeAccountIndex: Int = 0

    // Keychain storage keys
    private let encryptedSeedKey = "com.anvilwallet.encryptedSeed"
    private let encryptedMnemonicKey = "com.anvilwallet.encryptedMnemonic"
    private let walletMetadataKey = "com.anvilwallet.walletMetadata"
    private let passwordSaltKey = "com.anvilwallet.passwordSalt"
    private let accountsMetadataKey = "com.anvilwallet.accountsMetadata"

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
            throw AppWalletError.seedNotFound
        }

        let packed = try secureEnclave.decrypt(data: doubleEncrypted)
        let (salt, ciphertext) = try unpackSaltAndCiphertext(from: packed)

        // This will throw if the password is wrong
        var seedBytes = try decryptSeedWithPassword(
            ciphertext: ciphertext,
            salt: salt,
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
            throw AppWalletError.decryptionFailed
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
            throw AppWalletError.decryptionFailed
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
        // Note: Empty passphrase is intentional — matches MetaMask/Trust Wallet behavior.
        // BIP-39 passphrase support (for plausible deniability) is a planned future feature.
        var seedBytes = try mnemonicToSeed(mnemonic: mnemonicString, passphrase: "")
        defer {
            // Zeroize seed bytes after all operations complete
            for i in seedBytes.indices { seedBytes[i] = 0 }
        }
        let encrypted = try encryptSeedWithPassword(seed: seedBytes, password: password)
        let packed = packSaltAndCiphertext(
            salt: Data(encrypted.salt),
            ciphertext: Data(encrypted.ciphertext)
        )

        // Step 3: Create Secure Enclave key and double-encrypt
        let seKey = try secureEnclave.createKey()
        let doubleEncrypted = try secureEnclave.encrypt(data: packed, using: seKey)

        // Step 4: Store in Keychain with biometric protection
        try keychain.save(key: encryptedSeedKey, data: doubleEncrypted)

        // Step 4b: Also encrypt and store the mnemonic for recovery phrase backup
        try encryptAndStoreMnemonic(mnemonicString, password: password, seKey: seKey)

        // Step 5: Cache session password as zeroizable bytes
        sessionPasswordBytes = ContiguousArray(password.utf8)

        // Step 6: Derive addresses from mnemonic (not raw seed)
        let derivedAddresses = try deriveAddresses(mnemonic: mnemonicString, account: 0)
        self.addresses = derivedAddresses

        // Step 7: Create and save wallet metadata
        let wallet = WalletModel(
            name: "My Wallet",
            chains: ChainModel.defaults,
            addresses: derivedAddresses,
            accountIndex: 0,
            accountName: "Account 0"
        )
        try saveWalletMetadata(wallet)
        try saveAccountsMetadata([wallet])

        await MainActor.run {
            self.currentWallet = wallet
            self.accounts = [wallet]
            self.activeAccountIndex = 0
            self.isWalletCreated = true
            self.tokens = TokenModel.ethereumDefaults + TokenModel.solanaDefaults + TokenModel.bitcoinDefaults
        }

        // Discover ERC-20 tokens in background (best-effort, non-blocking)
        Task { await runTokenDiscovery() }

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
            throw AppWalletError.invalidMnemonic
        }

        // Step 2: Derive seed and encrypt with password via Rust
        var seedBytes = try mnemonicToSeed(mnemonic: mnemonic, passphrase: "")
        defer {
            // Zeroize seed bytes after all operations complete
            for i in seedBytes.indices { seedBytes[i] = 0 }
        }
        let encrypted = try encryptSeedWithPassword(seed: seedBytes, password: password)
        let packed = packSaltAndCiphertext(
            salt: Data(encrypted.salt),
            ciphertext: Data(encrypted.ciphertext)
        )

        // Step 3: Double-encrypt with Secure Enclave
        let seKey = try secureEnclave.createKey()
        let doubleEncrypted = try secureEnclave.encrypt(data: packed, using: seKey)

        // Step 4: Store in Keychain
        try keychain.save(key: encryptedSeedKey, data: doubleEncrypted)

        // Step 4b: Also encrypt and store the mnemonic for recovery phrase backup
        try encryptAndStoreMnemonic(mnemonic, password: password, seKey: seKey)

        // Step 5: Cache session password as zeroizable bytes
        sessionPasswordBytes = ContiguousArray(password.utf8)

        // Step 6: Derive addresses from mnemonic
        let derivedAddresses = try deriveAddresses(mnemonic: mnemonic, account: 0)
        self.addresses = derivedAddresses

        // Step 7: Save metadata
        let wallet = WalletModel(
            name: "Imported Wallet",
            chains: ChainModel.defaults,
            addresses: derivedAddresses,
            accountIndex: 0,
            accountName: "Account 0"
        )
        try saveWalletMetadata(wallet)
        try saveAccountsMetadata([wallet])

        await MainActor.run {
            self.currentWallet = wallet
            self.accounts = [wallet]
            self.activeAccountIndex = 0
            self.isWalletCreated = true
            self.tokens = TokenModel.ethereumDefaults + TokenModel.solanaDefaults + TokenModel.bitcoinDefaults
        }

        // Discover ERC-20 tokens in background (best-effort, non-blocking)
        Task { await runTokenDiscovery() }
    }

    // MARK: - Address Derivation

    /// Derives addresses for all supported chains from a mnemonic phrase.
    ///
    /// Uses BIP-44 derivation paths via Rust FFI:
    ///   - Ethereum & EVM chains: m/44'/60'/account'/0/0 (shared address)
    ///   - Solana: m/44'/501'/account'/0'
    ///   - Bitcoin: m/84'/0'/account'/0/0 (native segwit)
    ///
    /// - Parameters:
    ///   - mnemonic: The BIP-39 mnemonic phrase
    ///   - account: The HD account index (default 0)
    /// - Returns: Dictionary mapping chain IDs to derived addresses
    func deriveAddresses(mnemonic: String, account: UInt32 = 0) throws -> [String: String] {
        // Call Rust to derive BTC, ETH, SOL addresses in one shot
        let rustAddresses = try deriveAllAddressesFromMnemonic(
            mnemonic: mnemonic,
            passphrase: "",
            account: account
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
            throw AppWalletError.passwordRequired // Caller should show password re-entry UI
        }
        let password = String(decoding: pwBytes, as: UTF8.self)

        // Step 2: Biometric authentication
        let authenticated = try await biometric.authenticate(
            reason: "Authenticate to sign transaction"
        )
        guard authenticated else {
            throw AppWalletError.authenticationFailed
        }

        // Step 3: Load encrypted seed from Keychain
        guard let doubleEncrypted = try keychain.load(key: encryptedSeedKey) else {
            throw AppWalletError.seedNotFound
        }

        // Step 4: Decrypt with Secure Enclave
        let packed = try secureEnclave.decrypt(data: doubleEncrypted)

        // Step 5: Unpack salt + ciphertext and decrypt with password via Rust
        let (salt, ciphertext) = try unpackSaltAndCiphertext(from: packed)
        var seedBytes = try decryptSeedWithPassword(
            ciphertext: ciphertext,
            salt: salt,
            password: password
        )

        // Step 6: Sign transaction via Rust (seed is zeroized in Rust after signing)
        defer {
            // Also zeroize the Swift-side copy
            for i in seedBytes.indices { seedBytes[i] = 0 }
        }

        let signedTx: Data
        let accountIdx = UInt32(activeAccountIndex)
        switch request {
        case .eth(let ethReq):
            let result = try signEthTransaction(
                seed: seedBytes,
                passphrase: "",
                account: accountIdx,
                index: 0,
                chainId: ethReq.chainId,
                nonce: ethReq.nonce,
                toAddress: ethReq.to,
                valueWeiHex: ethReq.valueWeiHex,
                data: ethReq.data,
                maxPriorityFeeHex: ethReq.maxPriorityFeeHex,
                maxFeeHex: ethReq.maxFeeHex,
                gasLimit: ethReq.gasLimit
            )
            signedTx = Data(result)

        case .sol(let solReq):
            let result = try signSolTransfer(
                seed: seedBytes,
                account: accountIdx,
                toAddress: solReq.to,
                lamports: solReq.lamports,
                recentBlockhash: solReq.recentBlockhash
            )
            signedTx = Data(result)

        case .btc(let btcReq):
            let result = try signBtcTransaction(
                seed: seedBytes,
                account: accountIdx,
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

    /// Merges discovered ERC-20 tokens into the token list, avoiding duplicates.
    func mergeDiscoveredTokens(_ discovered: [TokenDiscoveryService.DiscoveredToken]) async {
        let existingContracts = Set(tokens.compactMap { $0.contractAddress?.lowercased() })

        var newTokens: [TokenModel] = []
        for dt in discovered {
            if existingContracts.contains(dt.contractAddress.lowercased()) { continue }
            newTokens.append(TokenModel(
                id: UUID(),
                symbol: dt.symbol,
                name: dt.name,
                chain: dt.chain,
                contractAddress: dt.contractAddress,
                decimals: dt.decimals,
                balance: 0,
                priceUsd: 0
            ))
        }

        if !newTokens.isEmpty {
            await MainActor.run {
                tokens.append(contentsOf: newTokens)
            }
        }
    }

    /// Runs token discovery for Ethereum mainnet and merges results.
    func runTokenDiscovery() async {
        guard let ethAddress = addresses["ethereum"] else { return }
        do {
            let discovered = try await TokenDiscoveryService.shared.discoverTokens(for: ethAddress)
            await mergeDiscoveredTokens(discovered)
        } catch {
            // Non-fatal — discovery is best-effort
        }
    }

    /// Refreshes token balances for all chains.
    func refreshBalances() async throws {
        let rpc = RPCService.shared

        // Snapshot token list to iterate
        let currentTokens = await MainActor.run { tokens }
        let snapshotAddresses = addresses

        // Collect results into a local array to avoid mutating a var across suspension points
        var results: [(index: Int, balance: Double)] = []

        for (index, token) in currentTokens.enumerated() {
            guard let chain = ChainModel.defaults.first(where: { $0.id == token.chain }),
                  let address = snapshotAddresses[token.chain] else {
                continue
            }

            do {
                let balance: Double

                switch chain.chainType {
                case .evm:
                    if token.isNativeToken {
                        let hexBalance: String = try await rpc.getBalance(rpcUrl: chain.activeRpcUrl, address: address)
                        balance = Self.hexToDouble(hexBalance) / pow(10.0, Double(token.decimals))
                    } else {
                        guard let contractAddress = token.contractAddress else { continue }
                        let stripped = String(address.dropFirst(2)).lowercased()
                        let paddedAddress = String(repeating: "0", count: max(0, 64 - stripped.count)) + stripped
                        let callData = "0x70a08231" + paddedAddress
                        let hexBalance: String = try await rpc.ethCall(rpcUrl: chain.activeRpcUrl, to: contractAddress, data: callData)
                        balance = Self.hexToDouble(hexBalance) / pow(10.0, Double(token.decimals))
                    }

                case .solana:
                    let lamports = try await rpc.getSolanaBalance(rpcUrl: chain.activeRpcUrl, address: address)
                    balance = Double(lamports) / pow(10.0, Double(token.decimals))

                case .bitcoin:
                    let satoshis = try await rpc.getBitcoinBalance(apiUrl: chain.activeRpcUrl, address: address)
                    balance = Double(satoshis) / pow(10.0, Double(token.decimals))
                }

                results.append((index: index, balance: balance))
            } catch {
                continue
            }
        }

        let balanceResults = results
        await MainActor.run {
            for result in balanceResults {
                if result.index < tokens.count {
                    tokens[result.index].balance = result.balance
                }
            }
        }

        // Re-discover tokens on each refresh (picks up newly received ERC-20s)
        await runTokenDiscovery()
    }

    /// Parses a hex string (with or without 0x prefix) to Double.
    /// Uses Double arithmetic to avoid UInt64 overflow for large token balances.
    static func hexToDouble(_ hex: String) -> Double {
        let cleaned = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        var result: Double = 0
        for char in cleaned {
            guard let digit = Int(String(char), radix: 16) else { return 0 }
            result = result * 16.0 + Double(digit)
        }
        return result
    }

    /// Refreshes token prices from price service.
    func refreshPrices() async throws {
        let priceService = PriceService.shared
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
        try? keychain.delete(key: encryptedMnemonicKey)
        try keychain.delete(key: walletMetadataKey)
        try keychain.delete(key: passwordSaltKey)
        try? keychain.delete(key: accountsMetadataKey)

        // Clear discovered tokens, manually added tokens, and NFTs for all accounts
        for account in accounts {
            if let ethAddr = account.addresses["ethereum"] {
                TokenDiscoveryService.shared.clearPersistedTokens(for: ethAddr)
                ManualTokenService.shared.clearPersistedTokens(for: ethAddr)
                NFTService.shared.clearPersistedNFTs(for: ethAddr)
            }
        }

        // Clear transaction history cache and local pending transactions
        TransactionHistoryService.shared.clearLocalTransactions()

        // Clear notification history and notified hashes
        NotificationService.shared.clearAll()

        // Zero password bytes in-place before releasing (avoid COW copy)
        if sessionPasswordBytes != nil {
            for i in sessionPasswordBytes!.indices { sessionPasswordBytes![i] = 0 }
        }
        sessionPasswordBytes = nil
        currentWallet = nil
        addresses = [:]
        tokens = []
        transactions = []
        accounts = []
        activeAccountIndex = 0
        isWalletCreated = false
    }

    // MARK: - Message Signing (EIP-191)

    /// Signs an arbitrary message using EIP-191 personal_sign.
    /// Used by WalletConnect for personal_sign requests.
    ///
    /// - Parameter message: The raw message bytes to sign
    /// - Returns: 65-byte signature (r + s + v)
    func signMessage(_ message: [UInt8]) async throws -> [UInt8] {
        guard let pwBytes = sessionPasswordBytes else {
            throw AppWalletError.passwordRequired
        }
        let password = String(decoding: pwBytes, as: UTF8.self)

        let authenticated = try await biometric.authenticate(
            reason: "Authenticate to sign message"
        )
        guard authenticated else {
            throw AppWalletError.authenticationFailed
        }

        guard let doubleEncrypted = try keychain.load(key: encryptedSeedKey) else {
            throw AppWalletError.seedNotFound
        }

        let packed = try secureEnclave.decrypt(data: doubleEncrypted)
        let (salt, ciphertext) = try unpackSaltAndCiphertext(from: packed)
        var seedBytes = try decryptSeedWithPassword(
            ciphertext: ciphertext,
            salt: salt,
            password: password
        )
        defer { for i in seedBytes.indices { seedBytes[i] = 0 } }

        let signature = try signEthMessage(
            seed: seedBytes,
            account: UInt32(activeAccountIndex),
            index: 0,
            message: Data(message)
        )

        return [UInt8](signature)
    }

    // MARK: - Raw Hash Signing (EIP-712)

    /// Signs a raw 32-byte hash without EIP-191 prefixing.
    /// Used for EIP-712 typed data signing where the caller computes the final hash.
    ///
    /// - Parameter hash: The 32-byte hash to sign directly
    /// - Returns: 65-byte signature (r + s + v)
    func signRawHash(_ hash: [UInt8]) async throws -> [UInt8] {
        guard hash.count == 32 else {
            throw AppWalletError.signingFailed
        }
        guard let pwBytes = sessionPasswordBytes else {
            throw AppWalletError.passwordRequired
        }
        let password = String(decoding: pwBytes, as: UTF8.self)

        let authenticated = try await biometric.authenticate(
            reason: "Authenticate to sign typed data"
        )
        guard authenticated else {
            throw AppWalletError.authenticationFailed
        }

        guard let doubleEncrypted = try keychain.load(key: encryptedSeedKey) else {
            throw AppWalletError.seedNotFound
        }

        let packed = try secureEnclave.decrypt(data: doubleEncrypted)
        let (salt, ciphertext) = try unpackSaltAndCiphertext(from: packed)
        var seedBytes = try decryptSeedWithPassword(
            ciphertext: ciphertext,
            salt: salt,
            password: password
        )
        defer { for i in seedBytes.indices { seedBytes[i] = 0 } }

        let signature = try signEthRawHash(
            seed: seedBytes,
            account: UInt32(activeAccountIndex),
            index: 0,
            hash: Data(hash)
        )

        return [UInt8](signature)
    }

    // MARK: - Solana Raw Transaction Signing (WalletConnect)

    /// Signs a pre-built Solana transaction (raw wire-format bytes).
    /// Used by WalletConnect `solana_signTransaction` requests.
    ///
    /// - Parameter rawTx: The raw transaction bytes (Solana wire format)
    /// - Returns: Signed transaction bytes ready for submission
    func signSolanaRawTransaction(_ rawTx: Data) async throws -> Data {
        guard let pwBytes = sessionPasswordBytes else {
            throw AppWalletError.passwordRequired
        }
        let password = String(decoding: pwBytes, as: UTF8.self)

        let authenticated = try await biometric.authenticate(
            reason: "Authenticate to sign Solana transaction"
        )
        guard authenticated else {
            throw AppWalletError.authenticationFailed
        }

        guard let doubleEncrypted = try keychain.load(key: encryptedSeedKey) else {
            throw AppWalletError.seedNotFound
        }

        let packed = try secureEnclave.decrypt(data: doubleEncrypted)
        let (salt, ciphertext) = try unpackSaltAndCiphertext(from: packed)
        var seedBytes = try decryptSeedWithPassword(
            ciphertext: ciphertext,
            salt: salt,
            password: password
        )
        defer { for i in seedBytes.indices { seedBytes[i] = 0 } }

        let signedTx = try signSolRawTransaction(
            seed: seedBytes,
            account: UInt32(activeAccountIndex),
            rawTx: rawTx
        )

        return signedTx
    }

    // MARK: - Solana Message Signing (WalletConnect)

    /// Signs an arbitrary message with the Solana Ed25519 key.
    /// Used by WalletConnect `solana_signMessage` requests.
    ///
    /// - Parameter message: The raw message bytes to sign
    /// - Returns: 64-byte Ed25519 signature
    func signSolanaMessage(_ message: [UInt8]) async throws -> [UInt8] {
        guard let pwBytes = sessionPasswordBytes else {
            throw AppWalletError.passwordRequired
        }
        let password = String(decoding: pwBytes, as: UTF8.self)

        let authenticated = try await biometric.authenticate(
            reason: "Authenticate to sign Solana message"
        )
        guard authenticated else {
            throw AppWalletError.authenticationFailed
        }

        guard let doubleEncrypted = try keychain.load(key: encryptedSeedKey) else {
            throw AppWalletError.seedNotFound
        }

        let packed = try secureEnclave.decrypt(data: doubleEncrypted)
        let (salt, ciphertext) = try unpackSaltAndCiphertext(from: packed)
        var seedBytes = try decryptSeedWithPassword(
            ciphertext: ciphertext,
            salt: salt,
            password: password
        )
        defer { for i in seedBytes.indices { seedBytes[i] = 0 } }

        let signature = try signSolMessage(
            seed: seedBytes,
            account: UInt32(activeAccountIndex),
            message: Data(message)
        )

        return [UInt8](signature)
    }

    // MARK: - Mnemonic Encryption

    /// Encrypts and stores the mnemonic string using the same double-encryption pipeline as the seed.
    private func encryptAndStoreMnemonic(_ mnemonic: String, password: String, seKey: SecKey) throws {
        let mnemonicData = Data(mnemonic.utf8)
        let encrypted = try encryptSeedWithPassword(seed: mnemonicData, password: password)
        let packed = packSaltAndCiphertext(
            salt: Data(encrypted.salt),
            ciphertext: Data(encrypted.ciphertext)
        )
        let doubleEncrypted = try secureEnclave.encrypt(data: packed, using: seKey)
        try keychain.save(key: encryptedMnemonicKey, data: doubleEncrypted)
    }

    /// Decrypts the stored mnemonic and returns the individual words.
    /// Returns nil if mnemonic was not stored (wallet created before this feature).
    func decryptMnemonic() async throws -> [String]? {
        guard let pwBytes = sessionPasswordBytes else {
            throw AppWalletError.passwordRequired
        }
        let password = String(decoding: pwBytes, as: UTF8.self)

        guard let doubleEncrypted = try keychain.load(key: encryptedMnemonicKey) else {
            return nil // Mnemonic not stored — wallet created before this feature
        }

        let packed = try secureEnclave.decrypt(data: doubleEncrypted)
        let (salt, ciphertext) = try unpackSaltAndCiphertext(from: packed)

        var mnemonicBytes = try decryptSeedWithPassword(
            ciphertext: ciphertext,
            salt: salt,
            password: password
        )
        defer {
            for i in mnemonicBytes.indices { mnemonicBytes[i] = 0 }
        }

        guard let mnemonicString = String(bytes: mnemonicBytes, encoding: .utf8) else {
            throw AppWalletError.decryptionFailed
        }

        return mnemonicString.split(separator: " ").map(String.init)
    }

    // MARK: - Change Password

    /// Changes the wallet password by re-encrypting the seed (and mnemonic if stored).
    func changePassword(current: String, new newPassword: String) async throws {
        // Step 1: Load and decrypt the seed with current password
        guard let doubleEncryptedSeed = try keychain.load(key: encryptedSeedKey) else {
            throw AppWalletError.seedNotFound
        }

        let packedSeed = try secureEnclave.decrypt(data: doubleEncryptedSeed)
        let (seedSalt, seedCiphertext) = try unpackSaltAndCiphertext(from: packedSeed)
        var seedBytes = try decryptSeedWithPassword(
            ciphertext: seedCiphertext,
            salt: seedSalt,
            password: current
        )
        defer { for i in seedBytes.indices { seedBytes[i] = 0 } }

        // Step 2: Re-encrypt seed with new password
        let newEncrypted = try encryptSeedWithPassword(seed: seedBytes, password: newPassword)
        let newPacked = packSaltAndCiphertext(
            salt: Data(newEncrypted.salt),
            ciphertext: Data(newEncrypted.ciphertext)
        )
        let seKey = try secureEnclave.getKey()
        let newDoubleEncrypted = try secureEnclave.encrypt(data: newPacked, using: seKey)
        try keychain.save(key: encryptedSeedKey, data: newDoubleEncrypted)

        // Step 3: Re-encrypt mnemonic if stored
        if let doubleEncryptedMnemonic = try keychain.load(key: encryptedMnemonicKey) {
            let packedMnemonic = try secureEnclave.decrypt(data: doubleEncryptedMnemonic)
            let (mSalt, mCiphertext) = try unpackSaltAndCiphertext(from: packedMnemonic)
            var mnemonicBytes = try decryptSeedWithPassword(
                ciphertext: mCiphertext,
                salt: mSalt,
                password: current
            )
            defer { for i in mnemonicBytes.indices { mnemonicBytes[i] = 0 } }

            let newMEncrypted = try encryptSeedWithPassword(seed: mnemonicBytes, password: newPassword)
            let newMPacked = packSaltAndCiphertext(
                salt: Data(newMEncrypted.salt),
                ciphertext: Data(newMEncrypted.ciphertext)
            )
            let newMDoubleEncrypted = try secureEnclave.encrypt(data: newMPacked, using: seKey)
            try keychain.save(key: encryptedMnemonicKey, data: newMDoubleEncrypted)
        }

        // Step 4: Update session password
        clearSessionPassword()
        sessionPasswordBytes = ContiguousArray(newPassword.utf8)
    }

    // MARK: - Encrypted Backup Export

    /// Exports the wallet mnemonic encrypted with a user-chosen backup password.
    ///
    /// Flow:
    ///   1. Verify session password is available
    ///   2. Load and decrypt the stored mnemonic via SE + app password
    ///   3. Re-encrypt the mnemonic with the backup password via Rust FFI (Argon2id + AES-256-GCM)
    ///   4. Package into Anvil backup format: "ANVL" magic + version byte + salt length + salt + ciphertext
    ///   5. Zeroize all plaintext mnemonic material
    ///
    /// - Parameter backupPassword: The password chosen by the user specifically for this backup
    /// - Returns: The complete backup file data ready to write to disk
    func exportEncryptedBackup(backupPassword: String) async throws -> Data {
        guard let pwBytes = sessionPasswordBytes else {
            throw AppWalletError.passwordRequired
        }
        let password = String(decoding: pwBytes, as: UTF8.self)

        // Load and decrypt the stored mnemonic
        guard let doubleEncrypted = try keychain.load(key: encryptedMnemonicKey) else {
            throw BackupError.mnemonicNotAvailable
        }

        let packed = try secureEnclave.decrypt(data: doubleEncrypted)
        let (salt, ciphertext) = try unpackSaltAndCiphertext(from: packed)
        var mnemonicBytes = try decryptSeedWithPassword(
            ciphertext: ciphertext,
            salt: salt,
            password: password
        )
        defer { for i in mnemonicBytes.indices { mnemonicBytes[i] = 0 } }

        // Re-encrypt the mnemonic with the backup password
        let backupEncrypted = try encryptSeedWithPassword(seed: mnemonicBytes, password: backupPassword)

        // Build the backup file:
        //   [4 bytes] magic "ANVL"
        //   [1 byte]  version (0x01)
        //   [4 bytes] salt length (big-endian UInt32)
        //   [N bytes] salt
        //   [M bytes] ciphertext
        var backupData = Data()
        backupData.append(contentsOf: [0x41, 0x4E, 0x56, 0x4C]) // "ANVL"
        backupData.append(0x01) // version 1
        var saltLen = UInt32(backupEncrypted.salt.count).bigEndian
        backupData.append(Data(bytes: &saltLen, count: 4))
        backupData.append(backupEncrypted.salt)
        backupData.append(backupEncrypted.ciphertext)

        return backupData
    }

    // MARK: - Encrypted Backup Import

    /// Validates and decrypts an Anvil backup file, then restores the wallet from the decrypted mnemonic.
    ///
    /// Flow:
    ///   1. Parse and validate backup file header ("ANVL" magic + version)
    ///   2. Extract salt and ciphertext
    ///   3. Decrypt with the backup password via Rust FFI
    ///   4. Validate the decrypted mnemonic phrase
    ///   5. Re-import the wallet using the standard importWallet flow
    ///
    /// - Parameters:
    ///   - backupData: The raw data from the .anvilbackup file
    ///   - backupPassword: The password used when the backup was created
    ///   - appPassword: The new app password to encrypt the restored wallet with
    func importEncryptedBackup(backupData: Data, backupPassword: String, appPassword: String) async throws {
        // Validate magic bytes
        guard backupData.count > 9 else {
            throw BackupError.invalidFormat
        }

        let magic = backupData[0..<4]
        guard magic == Data([0x41, 0x4E, 0x56, 0x4C]) else { // "ANVL"
            throw BackupError.invalidFormat
        }

        let version = backupData[4]
        guard version == 0x01 else {
            throw BackupError.unsupportedVersion(version)
        }

        // Parse salt length (big-endian UInt32)
        let b0 = UInt32(backupData[5])
        let b1 = UInt32(backupData[6])
        let b2 = UInt32(backupData[7])
        let b3 = UInt32(backupData[8])
        let saltLen = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)

        let saltStart = 9
        let saltEnd = saltStart + saltLen
        guard backupData.count > saltEnd else {
            throw BackupError.invalidFormat
        }

        let salt = Data(backupData[saltStart..<saltEnd])
        let ciphertext = Data(backupData[saltEnd...])

        // Decrypt with backup password -- this decrypts the mnemonic
        var mnemonicBytes: Data
        do {
            mnemonicBytes = try decryptSeedWithPassword(
                ciphertext: ciphertext,
                salt: salt,
                password: backupPassword
            )
        } catch {
            throw BackupError.wrongPassword
        }
        defer { for i in mnemonicBytes.indices { mnemonicBytes[i] = 0 } }

        // Convert bytes to mnemonic string
        guard let mnemonic = String(bytes: mnemonicBytes, encoding: .utf8) else {
            throw BackupError.corruptedData
        }

        // Validate mnemonic
        let isValid = try validateMnemonic(phrase: mnemonic)
        guard isValid else {
            throw BackupError.corruptedData
        }

        // Delete existing wallet data before restoring
        try? keychain.delete(key: encryptedSeedKey)
        try? keychain.delete(key: encryptedMnemonicKey)
        try? keychain.delete(key: walletMetadataKey)

        // Clear discovered tokens and NFTs from old wallet
        if let ethAddr = addresses["ethereum"] {
            TokenDiscoveryService.shared.clearPersistedTokens(for: ethAddr)
            ManualTokenService.shared.clearPersistedTokens(for: ethAddr)
            NFTService.shared.clearPersistedNFTs(for: ethAddr)
        }

        // Use the standard import flow which handles seed derivation, encryption, and SE wrapping
        try await importWallet(mnemonic: mnemonic, password: appPassword)
    }

    // MARK: - Transaction History

    /// Records a locally-sent transaction so it appears immediately in ActivityView
    /// before blockchain indexers pick it up.
    func recordLocalTransaction(_ tx: TransactionModel) {
        TransactionHistoryService.shared.addLocalTransaction(tx)
        // Insert at the front so it shows up immediately
        Task { @MainActor in
            if !self.transactions.contains(where: { $0.hash.lowercased() == tx.hash.lowercased() }) {
                self.transactions.insert(tx, at: 0)
            }
        }
    }

    /// Refreshes transaction history from blockchain explorers.
    /// Merges remote history with locally-stored pending transactions and deduplicates.
    /// On API failure, shows cached/local-only data gracefully.
    ///
    /// After fetching, compares old vs. new transactions to trigger local notifications
    /// for confirmed transactions and incoming transfers.
    func refreshTransactions() async throws {
        let txService = TransactionHistoryService.shared

        // Snapshot old state for diff
        let oldTransactions = await MainActor.run { self.transactions }
        let oldHashes = Set(oldTransactions.map { $0.hash.lowercased() })
        let oldPendingHashes = Set(
            oldTransactions
                .filter { $0.status == .pending }
                .map { $0.hash.lowercased() }
        )

        let newTransactions = try await txService.fetchAllTransactions(addresses: addresses)

        await MainActor.run {
            self.transactions = newTransactions
        }

        // Detect notification-worthy events
        let snapshotAddresses = addresses
        let notifier = NotificationService.shared

        for tx in newTransactions {
            let hashLower = tx.hash.lowercased()
            let chainName = ChainModel.defaults.first(where: { $0.id == tx.chain })?.name ?? tx.chain.capitalized

            // 1. Transaction confirmed: was pending, now confirmed
            if tx.status == .confirmed && oldPendingHashes.contains(hashLower) {
                notifier.notifyTransactionConfirmed(
                    txHash: tx.hash,
                    tokenSymbol: tx.tokenSymbol,
                    amount: tx.amount,
                    chain: chainName
                )
            }

            // 2. Incoming transfer: new tx we haven't seen before, where `to` is our address
            if tx.status == .confirmed && !oldHashes.contains(hashLower) {
                let isIncoming = snapshotAddresses.values.contains(where: {
                    $0.lowercased() == tx.to.lowercased()
                })
                if isIncoming {
                    notifier.notifyIncomingTransfer(
                        txHash: tx.hash,
                        tokenSymbol: tx.tokenSymbol,
                        amount: tx.amount,
                        from: tx.from,
                        chain: chainName
                    )
                }
            }
        }
    }

    /// Forces a full refresh by clearing the cache first.
    func forceRefreshTransactions() async throws {
        TransactionHistoryService.shared.invalidateCache()
        try await refreshTransactions()
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
        activeAccountIndex = wallet.accountIndex
        addresses = wallet.addresses
        tokens = TokenModel.ethereumDefaults + TokenModel.solanaDefaults + TokenModel.bitcoinDefaults

        // Load accounts list (backward compatible: if none stored, use current wallet as sole account)
        if let accountsData = try? keychain.load(key: accountsMetadataKey),
           let loadedAccounts = try? JSONDecoder().decode([WalletModel].self, from: accountsData),
           !loadedAccounts.isEmpty {
            accounts = loadedAccounts
        } else {
            accounts = [wallet]
        }

        // Merge previously discovered tokens from UserDefaults (scoped to current wallet)
        guard let ethAddr = addresses["ethereum"] else { return }
        let persisted = TokenDiscoveryService.shared.loadPersistedTokens(for: ethAddr)
        let existingContracts = Set(tokens.compactMap { $0.contractAddress?.lowercased() })
        for dt in persisted {
            if existingContracts.contains(dt.contractAddress.lowercased()) { continue }
            tokens.append(TokenModel(
                id: UUID(),
                symbol: dt.symbol,
                name: dt.name,
                chain: dt.chain,
                contractAddress: dt.contractAddress,
                decimals: dt.decimals,
                balance: 0,
                priceUsd: 0
            ))
        }

        // Merge manually added tokens
        let manualTokens = ManualTokenService.shared.loadPersistedTokens(for: ethAddr)
        let existingAfterDiscovery = Set(tokens.compactMap { $0.contractAddress?.lowercased() })
        for mt in manualTokens {
            if existingAfterDiscovery.contains(mt.contractAddress.lowercased()) { continue }
            tokens.append(TokenModel(
                id: UUID(),
                symbol: mt.symbol,
                name: mt.name,
                chain: mt.chain,
                contractAddress: mt.contractAddress,
                decimals: mt.decimals,
                balance: 0,
                priceUsd: 0
            ))
        }
    }

    // MARK: - Multi-Account Management

    /// Persists the full accounts list to Keychain.
    private func saveAccountsMetadata(_ accounts: [WalletModel]) throws {
        let data = try JSONEncoder().encode(accounts)
        try keychain.save(key: accountsMetadataKey, data: data)
    }

    /// Creates a new HD account by deriving addresses for the next account index.
    ///
    /// Requires the session password to be available (to decrypt the mnemonic for derivation).
    /// The new account shares the same seed -- only the BIP-44 account index changes.
    ///
    /// - Parameter name: Optional user-friendly name for the account
    func createAccount(name: String? = nil) async throws {
        // Need the mnemonic to derive addresses for the new account index
        guard let mnemonicWords = try await decryptMnemonic() else {
            throw AppWalletError.decryptionFailed
        }
        let mnemonic = mnemonicWords.joined(separator: " ")

        let nextIndex = (accounts.map { $0.accountIndex }.max() ?? -1) + 1
        let accountName = name ?? "Account \(nextIndex)"

        let derivedAddresses = try deriveAddresses(
            mnemonic: mnemonic,
            account: UInt32(nextIndex)
        )

        let newAccount = WalletModel(
            name: currentWallet?.name ?? "My Wallet",
            chains: ChainModel.defaults,
            addresses: derivedAddresses,
            accountIndex: nextIndex,
            accountName: accountName
        )

        var updatedAccounts = accounts
        updatedAccounts.append(newAccount)
        try saveAccountsMetadata(updatedAccounts)

        await MainActor.run {
            self.accounts = updatedAccounts
        }

        // Switch to the newly created account
        try await switchAccount(index: nextIndex)
    }

    /// Switches to a different HD account by index.
    ///
    /// Updates the active wallet, addresses, tokens, and triggers balance/token refresh.
    ///
    /// - Parameter index: The account index to switch to
    func switchAccount(index: Int) async throws {
        guard let account = accounts.first(where: { $0.accountIndex == index }) else {
            return
        }

        try saveWalletMetadata(account)

        await MainActor.run {
            self.currentWallet = account
            self.activeAccountIndex = index
            self.addresses = account.addresses
            self.tokens = TokenModel.ethereumDefaults + TokenModel.solanaDefaults + TokenModel.bitcoinDefaults
            self.transactions = []
        }

        // Merge discovered and manual tokens for the new account's address
        if let ethAddr = account.addresses["ethereum"] {
            let persisted = TokenDiscoveryService.shared.loadPersistedTokens(for: ethAddr)
            let manualTokens = ManualTokenService.shared.loadPersistedTokens(for: ethAddr)

            await MainActor.run {
                let existingContracts = Set(tokens.compactMap { $0.contractAddress?.lowercased() })
                for dt in persisted {
                    if existingContracts.contains(dt.contractAddress.lowercased()) { continue }
                    tokens.append(TokenModel(
                        id: UUID(),
                        symbol: dt.symbol,
                        name: dt.name,
                        chain: dt.chain,
                        contractAddress: dt.contractAddress,
                        decimals: dt.decimals,
                        balance: 0,
                        priceUsd: 0
                    ))
                }

                let existingAfterDiscovery = Set(tokens.compactMap { $0.contractAddress?.lowercased() })
                for mt in manualTokens {
                    if existingAfterDiscovery.contains(mt.contractAddress.lowercased()) { continue }
                    tokens.append(TokenModel(
                        id: UUID(),
                        symbol: mt.symbol,
                        name: mt.name,
                        chain: mt.chain,
                        contractAddress: mt.contractAddress,
                        decimals: mt.decimals,
                        balance: 0,
                        priceUsd: 0
                    ))
                }
            }
        }

        // Refresh balances and discover tokens in background
        Task {
            try? await refreshBalances()
            try? await refreshPrices()
            try? await refreshTransactions()
        }
    }

    /// Renames an account.
    ///
    /// - Parameters:
    ///   - index: The account index to rename
    ///   - name: The new name
    func renameAccount(index: Int, name: String) throws {
        guard let idx = accounts.firstIndex(where: { $0.accountIndex == index }) else {
            return
        }
        accounts[idx].accountName = name
        try saveAccountsMetadata(accounts)

        // If renaming the active account, update currentWallet too
        if index == activeAccountIndex {
            currentWallet?.accountName = name
            if let wallet = currentWallet {
                try saveWalletMetadata(wallet)
            }
        }
    }

    /// Deletes an account (cannot delete account 0).
    ///
    /// If the deleted account was active, switches to account 0.
    ///
    /// - Parameter index: The account index to delete
    func deleteAccount(index: Int) async throws {
        guard index != 0 else { return } // Cannot delete primary account
        guard accounts.contains(where: { $0.accountIndex == index }) else { return }

        // Clear persisted tokens for the deleted account
        if let account = accounts.first(where: { $0.accountIndex == index }),
           let ethAddr = account.addresses["ethereum"] {
            TokenDiscoveryService.shared.clearPersistedTokens(for: ethAddr)
            ManualTokenService.shared.clearPersistedTokens(for: ethAddr)
        }

        var updatedAccounts = accounts.filter { $0.accountIndex != index }
        try saveAccountsMetadata(updatedAccounts)

        await MainActor.run {
            self.accounts = updatedAccounts
        }

        // If we deleted the active account, switch to account 0
        if activeAccountIndex == index {
            try await switchAccount(index: 0)
        }
    }
}

// MARK: - Wallet Errors

enum AppWalletError: LocalizedError {
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

// MARK: - Backup Errors

enum BackupError: LocalizedError {
    case invalidFormat
    case unsupportedVersion(UInt8)
    case wrongPassword
    case corruptedData
    case mnemonicNotAvailable

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "This file is not a valid Anvil Wallet backup. Please select an .anvilbackup file."
        case .unsupportedVersion(let version):
            return "This backup was created with a newer version of Anvil Wallet (v\(version)). Please update the app."
        case .wrongPassword:
            return "Incorrect backup password. Please try again."
        case .corruptedData:
            return "The backup file appears to be corrupted and cannot be restored."
        case .mnemonicNotAvailable:
            return "Recovery phrase not available for backup. This wallet was created before backup support was added. Please re-import your wallet first."
        }
    }
}
