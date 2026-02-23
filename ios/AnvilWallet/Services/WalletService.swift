import Combine
import Foundation
import LocalAuthentication
import SwiftUI

// MARK: - Transaction Request Types

/// Typed transaction request for signing -- ensures correct parameters per chain.
enum TransactionRequest {
    case eth(EthTransactionRequest)
    case sol(SolTransactionRequest)
    case btc(BtcTransactionRequest)
    case zec(ZecTransactionRequest)
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

struct ZecTransactionRequest {
    let utxos: [ZecUtxoData]
    let recipientAddress: String
    let amountZatoshi: UInt64
    let changeAddress: String
    let feeRateZatByte: UInt64
    let expiryHeight: UInt32
    let isTestnet: Bool
}

struct WatchPortfolioEntry: Identifiable, Hashable {
    let id: UUID
    let name: String
    let chainId: String
    let address: String
    let nativeSymbol: String
    let balanceNative: Double
    let balanceUsd: Double
}

// MARK: - WalletService

/// WalletService is the central orchestrator for all wallet operations.
/// It coordinates between the Rust core (via UniFFI), Secure Enclave,
/// Keychain, and Biometric authentication to provide a secure wallet experience.
///
/// Delegates to focused services:
///   - BackupService: mnemonic encryption, backup export/import, password change
///   - AccountManager: multi-account CRUD
///   - BalanceService: balance fetching, watch-only data, widget updates
final class WalletService: ObservableObject {
    static let shared = WalletService()

    private let keychain = KeychainService()
    private let secureEnclave = SecureEnclaveService()
    private let biometric = BiometricService()
    private let securityService = SecurityService.shared
    private let backup = BackupService.shared
    private let accountManager = AccountManager()
    private let balanceService = BalanceService.shared

    @Published var isWalletCreated: Bool = false
    @Published var addresses: [String: String] = [:] // chainId -> address
    @Published var currentWallet: WalletModel?
    @Published var tokens: [TokenModel] = []
    @Published var transactions: [TransactionModel] = []
    @Published var watchPortfolio: [WatchPortfolioEntry] = []
    @Published var watchTransactions: [TransactionModel] = []

    /// All HD accounts derived from the same seed.
    @Published var accounts: [WalletModel] = []

    /// Currently active account index.
    @Published var activeAccountIndex: Int = 0

    /// In-memory session password stored as raw bytes for explicit zeroization.
    /// Swift String instances are immutable and may linger in memory after deallocation.
    /// ContiguousArray<UInt8> allows us to overwrite every byte before releasing.
    private var sessionPasswordBytes: ContiguousArray<UInt8>?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        isWalletCreated = keychain.exists(key: WalletKeychainKeys.encryptedSeed)
        if isWalletCreated {
            loadWalletMetadata()
        }

        ChainPreferencesStore.shared.$disabledChainIds
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (_: Set<String>) in self?.rebuildTokensForEnabledChains() }
            .store(in: &cancellables)
    }

    /// Whether the session password is currently cached in memory.
    var hasSessionPassword: Bool {
        sessionPasswordBytes != nil
    }

    /// Whether an optional BIP-39 passphrase is configured for this wallet.
    var hasBip39Passphrase: Bool {
        backup.hasBip39Passphrase
    }

    // MARK: - Session Password

    /// Clears the cached session password. Zeros all bytes in-place before releasing.
    func clearSessionPassword() {
        if sessionPasswordBytes != nil {
            for i in sessionPasswordBytes!.indices { sessionPasswordBytes![i] = 0 }
        }
        sessionPasswordBytes = nil
    }

    /// Sets the session password after user re-enters it.
    /// Validates the password by attempting a decrypt round-trip before accepting it.
    func setSessionPassword(_ password: String) async throws {
        guard let doubleEncrypted = try keychain.load(key: WalletKeychainKeys.encryptedSeed) else {
            throw AppWalletError.seedNotFound
        }

        let packed = try secureEnclave.decrypt(data: doubleEncrypted)
        let (salt, ciphertext) = try backup.unpackSaltAndCiphertext(from: packed)

        var seedBytes = try decryptSeedWithPassword(
            ciphertext: ciphertext,
            salt: salt,
            password: password
        )
        for i in seedBytes.indices { seedBytes[i] = 0 }

        sessionPasswordBytes = ContiguousArray(password.utf8)
    }

    /// Returns the current session password as a String, or throws if not set.
    private func requireSessionPassword() throws -> String {
        guard let pwBytes = sessionPasswordBytes else {
            throw AppWalletError.passwordRequired
        }
        return String(decoding: pwBytes, as: UTF8.self)
    }

    // MARK: - Secure Enclave Migration

    /// Re-wraps encrypted wallet blobs under a new Secure Enclave key policy.
    func migrateSecureEnclaveProtection(requiresBiometrics: Bool) throws {
        guard let seedCipher = try keychain.load(key: WalletKeychainKeys.encryptedSeed) else {
            throw AppWalletError.seedNotFound
        }

        let oldKey = try secureEnclave.getKey()

        let packedSeed = try secureEnclave.decrypt(data: seedCipher, using: oldKey)
        let packedMnemonic = try keychain.load(key: WalletKeychainKeys.encryptedMnemonic).map {
            try secureEnclave.decrypt(data: $0, using: oldKey)
        }
        let packedPassphrase = try keychain.load(key: WalletKeychainKeys.encryptedPassphrase).map {
            try secureEnclave.decrypt(data: $0, using: oldKey)
        }

        let newKey = try secureEnclave.createKey(requiresBiometrics: requiresBiometrics)
        let rewrappedSeed = try secureEnclave.encrypt(data: packedSeed, using: newKey)
        try keychain.save(key: WalletKeychainKeys.encryptedSeed, data: rewrappedSeed)

        if let packedMnemonic {
            let rewrappedMnemonic = try secureEnclave.encrypt(data: packedMnemonic, using: newKey)
            try keychain.save(key: WalletKeychainKeys.encryptedMnemonic, data: rewrappedMnemonic)
        }

        if let packedPassphrase {
            let rewrappedPassphrase = try secureEnclave.encrypt(data: packedPassphrase, using: newKey)
            try keychain.save(key: WalletKeychainKeys.encryptedPassphrase, data: rewrappedPassphrase)
        }
    }

    // MARK: - Wallet Creation

    func createWallet(password: String, passphrase: String = "") async throws -> [String] {
        let mnemonicString = try generateMnemonic()
        let words = mnemonicString.split(separator: " ").map(String.init)

        var seedBytes = try mnemonicToSeed(mnemonic: mnemonicString, passphrase: passphrase)
        defer {
            for i in seedBytes.indices { seedBytes[i] = 0 }
        }
        let encrypted = try encryptSeedWithPassword(seed: seedBytes, password: password)
        let packed = backup.packSaltAndCiphertext(
            salt: Data(encrypted.salt),
            ciphertext: Data(encrypted.ciphertext)
        )

        let seKey = try secureEnclave.createKey()
        let doubleEncrypted = try secureEnclave.encrypt(data: packed, using: seKey)
        try keychain.save(key: WalletKeychainKeys.encryptedSeed, data: doubleEncrypted)

        try backup.encryptAndStoreMnemonic(mnemonicString, password: password, seKey: seKey)
        try backup.encryptAndStorePassphrase(passphrase, password: password, seKey: seKey)

        sessionPasswordBytes = ContiguousArray(password.utf8)
        SessionLockManager.shared.savePasswordForBiometrics(password)

        let derivedAddresses = try deriveAddresses(mnemonic: mnemonicString, passphrase: passphrase, account: 0)
        self.addresses = derivedAddresses

        let wallet = WalletModel(
            name: "My Wallet",
            chains: ChainModel.defaults,
            addresses: derivedAddresses,
            accountIndex: 0,
            accountName: "Account 0"
        )
        try accountManager.saveWalletMetadata(wallet)
        try accountManager.saveAccountsMetadata([wallet])

        await MainActor.run {
            self.currentWallet = wallet
            self.accounts = [wallet]
            self.activeAccountIndex = 0
            self.isWalletCreated = true
            self.tokens = TokenModel.enabledDefaultTokens()
        }

        Task { await runTokenDiscovery() }

        return words
    }

    // MARK: - Wallet Import

    func importWallet(mnemonic: String, password: String, passphrase: String = "") async throws {
        let isValid = try validateMnemonic(phrase: mnemonic)
        guard isValid else {
            throw AppWalletError.invalidMnemonic
        }

        var seedBytes = try mnemonicToSeed(mnemonic: mnemonic, passphrase: passphrase)
        defer {
            for i in seedBytes.indices { seedBytes[i] = 0 }
        }
        let encrypted = try encryptSeedWithPassword(seed: seedBytes, password: password)
        let packed = backup.packSaltAndCiphertext(
            salt: Data(encrypted.salt),
            ciphertext: Data(encrypted.ciphertext)
        )

        let seKey = try secureEnclave.createKey()
        let doubleEncrypted = try secureEnclave.encrypt(data: packed, using: seKey)
        try keychain.save(key: WalletKeychainKeys.encryptedSeed, data: doubleEncrypted)

        try backup.encryptAndStoreMnemonic(mnemonic, password: password, seKey: seKey)
        try backup.encryptAndStorePassphrase(passphrase, password: password, seKey: seKey)

        sessionPasswordBytes = ContiguousArray(password.utf8)
        SessionLockManager.shared.savePasswordForBiometrics(password)

        let derivedAddresses = try deriveAddresses(mnemonic: mnemonic, passphrase: passphrase, account: 0)
        self.addresses = derivedAddresses

        let wallet = WalletModel(
            name: "Imported Wallet",
            chains: ChainModel.defaults,
            addresses: derivedAddresses,
            accountIndex: 0,
            accountName: "Account 0"
        )
        try accountManager.saveWalletMetadata(wallet)
        try accountManager.saveAccountsMetadata([wallet])

        await MainActor.run {
            self.currentWallet = wallet
            self.accounts = [wallet]
            self.activeAccountIndex = 0
            self.isWalletCreated = true
            self.tokens = TokenModel.enabledDefaultTokens()
        }

        Task { await runTokenDiscovery() }
    }

    // MARK: - Address Derivation

    func deriveAddresses(mnemonic: String, passphrase: String = "", account: UInt32 = 0) throws -> [String: String] {
        let rustAddresses = try deriveAllAddressesFromMnemonic(
            mnemonic: mnemonic,
            passphrase: passphrase,
            account: account
        )

        var addresses: [String: String] = [:]
        for derived in rustAddresses {
            switch derived.chain {
            case .ethereum:
                for chain in ChainModel.defaults where chain.chainType == .evm {
                    addresses[chain.id] = derived.address
                }
            case .solana:
                addresses["solana"] = derived.address
            case .bitcoin:
                addresses["bitcoin"] = derived.address
            case .zcash:
                addresses["zcash"] = derived.address
            default:
                break
            }
        }
        return addresses
    }

    // MARK: - Transaction Signing

    func signTransaction(request: TransactionRequest) async throws -> Data {
        let password = try requireSessionPassword()

        let authContext = try await authenticateForSigning(reason: "Authenticate to sign transaction")

        guard let doubleEncrypted = try keychain.load(key: WalletKeychainKeys.encryptedSeed) else {
            throw AppWalletError.seedNotFound
        }

        let packed = try secureEnclave.decrypt(data: doubleEncrypted, context: authContext)
        let (salt, ciphertext) = try backup.unpackSaltAndCiphertext(from: packed)
        var seedBytes = try decryptSeedWithPassword(
            ciphertext: ciphertext,
            salt: salt,
            password: password
        )
        defer {
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

        case .zec(let zecReq):
            let result = try signZecTransaction(
                seed: seedBytes,
                account: accountIdx,
                index: 0,
                utxos: zecReq.utxos,
                recipientAddress: zecReq.recipientAddress,
                amountZatoshi: zecReq.amountZatoshi,
                changeAddress: zecReq.changeAddress,
                feeRateZatByte: zecReq.feeRateZatByte,
                expiryHeight: zecReq.expiryHeight,
                isTestnet: zecReq.isTestnet
            )
            signedTx = Data(result)
        }

        return signedTx
    }

    // MARK: - Message Signing

    func signMessage(_ message: [UInt8]) async throws -> [UInt8] {
        let password = try requireSessionPassword()
        let ctx = try await authenticateForSigning(reason: "Authenticate to sign message")

        var seedBytes = try decryptSeed(password: password, context: ctx)
        defer { for i in seedBytes.indices { seedBytes[i] = 0 } }

        let signature = try signEthMessage(
            seed: seedBytes,
            account: UInt32(activeAccountIndex),
            index: 0,
            message: Data(message)
        )
        return [UInt8](signature)
    }

    func signRawHash(_ hash: [UInt8]) async throws -> [UInt8] {
        guard hash.count == 32 else { throw AppWalletError.signingFailed }
        let password = try requireSessionPassword()
        let ctx = try await authenticateForSigning(reason: "Authenticate to sign typed data")

        var seedBytes = try decryptSeed(password: password, context: ctx)
        defer { for i in seedBytes.indices { seedBytes[i] = 0 } }

        let signature = try signEthRawHash(
            seed: seedBytes,
            account: UInt32(activeAccountIndex),
            index: 0,
            hash: Data(hash)
        )
        return [UInt8](signature)
    }

    func signSolanaRawTransaction(_ rawTx: Data) async throws -> Data {
        let password = try requireSessionPassword()
        let ctx = try await authenticateForSigning(reason: "Authenticate to sign Solana transaction")

        var seedBytes = try decryptSeed(password: password, context: ctx)
        defer { for i in seedBytes.indices { seedBytes[i] = 0 } }

        return try signSolRawTransaction(
            seed: seedBytes,
            account: UInt32(activeAccountIndex),
            rawTx: rawTx
        )
    }

    func signSolanaMessage(_ message: [UInt8]) async throws -> [UInt8] {
        let password = try requireSessionPassword()
        let ctx = try await authenticateForSigning(reason: "Authenticate to sign Solana message")

        var seedBytes = try decryptSeed(password: password, context: ctx)
        defer { for i in seedBytes.indices { seedBytes[i] = 0 } }

        let signature = try signSolMessage(
            seed: seedBytes,
            account: UInt32(activeAccountIndex),
            message: Data(message)
        )
        return [UInt8](signature)
    }

    // MARK: - Balance & Price Updates

    func mergeDiscoveredTokens(_ discovered: [TokenDiscoveryService.DiscoveredToken]) async {
        let existingContracts = Set(tokens.compactMap { $0.contractAddress?.lowercased() })
        let newTokens: [TokenModel] = discovered
            .filter { !existingContracts.contains($0.contractAddress.lowercased()) }
            .map { dt in
                TokenModel(
                    id: UUID(),
                    symbol: dt.symbol,
                    name: dt.name,
                    chain: dt.chain,
                    contractAddress: dt.contractAddress,
                    decimals: dt.decimals,
                    balance: 0,
                    priceUsd: 0
                )
            }
        if !newTokens.isEmpty {
            await MainActor.run {
                tokens.append(contentsOf: newTokens)
            }
        }
    }

    func runTokenDiscovery() async {
        guard let ethAddress = addresses["ethereum"] else { return }
        do {
            let discovered = try await TokenDiscoveryService.shared.discoverTokens(for: ethAddress)
            await mergeDiscoveredTokens(discovered)
        } catch {}
    }

    func refreshBalances() async throws {
        let currentTokens = await MainActor.run { tokens }
        let snapshotAddresses = addresses

        let balanceResults = await balanceService.fetchBalances(
            tokens: currentTokens,
            addresses: snapshotAddresses
        )

        await MainActor.run {
            for result in balanceResults {
                if result.index < tokens.count {
                    tokens[result.index].balance = result.balance
                }
            }
        }

        balanceService.updateWidgetData(
            tokens: tokens,
            accountName: currentWallet?.displayName ?? "Account 0"
        )

        try? await refreshWatchOnlyData()
        await runTokenDiscovery()
    }

    /// Parses a hex string (with or without 0x prefix) to Double.
    static func hexToDouble(_ hex: String) -> Double {
        BalanceService.hexToDouble(hex)
    }

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

        balanceService.updateWidgetData(
            tokens: tokens,
            accountName: currentWallet?.displayName ?? "Account 0"
        )

        try? await refreshWatchOnlyData()
    }

    func refreshWatchOnlyData() async throws {
        let (portfolio, txs) = try await balanceService.fetchWatchOnlyData()
        await MainActor.run {
            self.watchPortfolio = portfolio
            self.watchTransactions = txs
        }
    }

    // MARK: - Backup Delegation

    func decryptMnemonic() async throws -> [String]? {
        let password = try requireSessionPassword()
        return try backup.decryptMnemonic(password: password)
    }

    func decryptPassphrase() async throws -> String {
        let password = try requireSessionPassword()
        return try backup.decryptPassphrase(password: password)
    }

    func exportEncryptedBackup(backupPassword: String) async throws -> Data {
        let password = try requireSessionPassword()
        return try await backup.exportEncryptedBackup(
            sessionPassword: password,
            backupPassword: backupPassword
        )
    }

    func importEncryptedBackup(backupData: Data, backupPassword: String, appPassword: String) async throws {
        let (mnemonic, passphrase) = try backup.parseAndDecryptBackup(
            backupData: backupData,
            backupPassword: backupPassword
        )

        let oldEthAddr = addresses["ethereum"]
        try await importWallet(mnemonic: mnemonic, password: appPassword, passphrase: passphrase)

        if let oldEthAddr, oldEthAddr.lowercased() != (addresses["ethereum"] ?? "").lowercased() {
            TokenDiscoveryService.shared.clearPersistedTokens(for: oldEthAddr)
            ManualTokenService.shared.clearPersistedTokens(for: oldEthAddr)
            NFTService.shared.clearPersistedNFTs(for: oldEthAddr)
        }
    }

    func changePassword(current: String, new newPassword: String) async throws {
        try backup.changePassword(current: current, newPassword: newPassword)

        clearSessionPassword()
        sessionPasswordBytes = ContiguousArray(newPassword.utf8)
        SessionLockManager.shared.savePasswordForBiometrics(newPassword)
    }

    // MARK: - Multi-Account Management

    func createAccount(name: String? = nil) async throws {
        let password = try requireSessionPassword()
        let (newAccount, updatedAccounts) = try await accountManager.createAccount(
            accounts: accounts,
            currentWalletName: currentWallet?.name ?? "My Wallet",
            sessionPassword: password,
            name: name
        )

        await MainActor.run {
            self.accounts = updatedAccounts
        }

        try await switchAccount(index: newAccount.accountIndex)
    }

    func switchAccount(index: Int) async throws {
        guard let account = accounts.first(where: { $0.accountIndex == index }) else {
            return
        }

        try accountManager.saveWalletMetadata(account)

        await MainActor.run {
            self.currentWallet = account
            self.activeAccountIndex = index
            self.addresses = account.addresses
            self.tokens = TokenModel.enabledDefaultTokens()
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
                        id: UUID(), symbol: dt.symbol, name: dt.name, chain: dt.chain,
                        contractAddress: dt.contractAddress, decimals: dt.decimals, balance: 0, priceUsd: 0
                    ))
                }
                let existingAfterDiscovery = Set(tokens.compactMap { $0.contractAddress?.lowercased() })
                for mt in manualTokens {
                    if existingAfterDiscovery.contains(mt.contractAddress.lowercased()) { continue }
                    tokens.append(TokenModel(
                        id: UUID(), symbol: mt.symbol, name: mt.name, chain: mt.chain,
                        contractAddress: mt.contractAddress, decimals: mt.decimals, balance: 0, priceUsd: 0
                    ))
                }
            }
        }

        Task {
            try? await refreshBalances()
            try? await refreshPrices()
            try? await refreshTransactions()
        }
    }

    func renameAccount(index: Int, name: String) throws {
        currentWallet = try accountManager.renameAccount(
            accounts: &accounts,
            index: index,
            name: name,
            currentWallet: currentWallet,
            activeAccountIndex: activeAccountIndex
        )
    }

    func deleteAccount(index: Int) async throws {
        guard let updatedAccounts = try accountManager.deleteAccount(accounts: accounts, index: index) else {
            return
        }

        await MainActor.run {
            self.accounts = updatedAccounts
        }

        if activeAccountIndex == index {
            try await switchAccount(index: 0)
        }
    }

    // MARK: - Wallet Deletion

    func deleteWallet() throws {
        try keychain.delete(key: WalletKeychainKeys.encryptedSeed)
        try? keychain.delete(key: WalletKeychainKeys.encryptedMnemonic)
        try? keychain.delete(key: WalletKeychainKeys.encryptedPassphrase)
        try keychain.delete(key: WalletKeychainKeys.walletMetadata)
        try keychain.delete(key: WalletKeychainKeys.passwordSalt)
        try? keychain.delete(key: WalletKeychainKeys.accountsMetadata)

        for account in accounts {
            if let ethAddr = account.addresses["ethereum"] {
                TokenDiscoveryService.shared.clearPersistedTokens(for: ethAddr)
                ManualTokenService.shared.clearPersistedTokens(for: ethAddr)
                NFTService.shared.clearPersistedNFTs(for: ethAddr)
            }
        }

        TransactionHistoryService.shared.clearLocalTransactions()
        NotificationService.shared.clearAll()

        clearSessionPassword()
        currentWallet = nil
        addresses = [:]
        tokens = []
        transactions = []
        watchPortfolio = []
        watchTransactions = []
        accounts = []
        activeAccountIndex = 0
        isWalletCreated = false
    }

    // MARK: - Transaction History

    func recordLocalTransaction(_ tx: TransactionModel) {
        TransactionHistoryService.shared.addLocalTransaction(tx)
        Task { @MainActor in
            if !self.transactions.contains(where: { $0.hash.lowercased() == tx.hash.lowercased() }) {
                self.transactions.insert(tx, at: 0)
            }
        }
    }

    func refreshTransactions() async throws {
        let txService = TransactionHistoryService.shared

        let oldTransactions = await MainActor.run { self.transactions }
        let oldHashes = Set(oldTransactions.map { $0.hash.lowercased() })
        let oldPendingHashes = Set(
            oldTransactions.filter { $0.status == .pending }.map { $0.hash.lowercased() }
        )

        let newTransactions = try await txService.fetchAllTransactions(addresses: addresses)

        await MainActor.run {
            self.transactions = newTransactions
        }

        let snapshotAddresses = addresses
        let notifier = NotificationService.shared

        for tx in newTransactions {
            let hashLower = tx.hash.lowercased()
            let chainName = ChainModel.defaults.first(where: { $0.id == tx.chain })?.name ?? tx.chain.capitalized

            if tx.status == .confirmed && oldPendingHashes.contains(hashLower) {
                notifier.notifyTransactionConfirmed(
                    txHash: tx.hash, tokenSymbol: tx.tokenSymbol,
                    amount: tx.amount, chain: chainName
                )
            }

            if tx.status == .confirmed && !oldHashes.contains(hashLower) {
                let isIncoming = snapshotAddresses.values.contains(where: {
                    $0.lowercased() == tx.to.lowercased()
                })
                if isIncoming {
                    notifier.notifyIncomingTransfer(
                        txHash: tx.hash, tokenSymbol: tx.tokenSymbol,
                        amount: tx.amount, from: tx.from, chain: chainName
                    )
                }
            }
        }
    }

    func forceRefreshTransactions() async throws {
        TransactionHistoryService.shared.invalidateCache()
        try await refreshTransactions()
    }

    // MARK: - Chain Preferences

    /// Rebuilds the token list when chain preferences change (user toggles a chain on/off).
    private func rebuildTokensForEnabledChains() {
        let prefs = ChainPreferencesStore.shared
        var newTokens = TokenModel.enabledDefaultTokens()

        guard let ethAddr = addresses["ethereum"] else {
            tokens = newTokens
            return
        }

        let persisted = TokenDiscoveryService.shared.loadPersistedTokens(for: ethAddr)
        let manualTokens = ManualTokenService.shared.loadPersistedTokens(for: ethAddr)

        var knownContracts = Set(newTokens.compactMap { $0.contractAddress?.lowercased() })
        for dt in persisted {
            guard prefs.isEnabled(dt.chain) else { continue }
            guard !knownContracts.contains(dt.contractAddress.lowercased()) else { continue }
            knownContracts.insert(dt.contractAddress.lowercased())
            newTokens.append(TokenModel(
                id: UUID(), symbol: dt.symbol, name: dt.name, chain: dt.chain,
                contractAddress: dt.contractAddress, decimals: dt.decimals, balance: 0, priceUsd: 0
            ))
        }

        for mt in manualTokens {
            guard prefs.isEnabled(mt.chain) else { continue }
            guard !knownContracts.contains(mt.contractAddress.lowercased()) else { continue }
            knownContracts.insert(mt.contractAddress.lowercased())
            newTokens.append(TokenModel(
                id: UUID(), symbol: mt.symbol, name: mt.name, chain: mt.chain,
                contractAddress: mt.contractAddress, decimals: mt.decimals, balance: 0, priceUsd: 0
            ))
        }

        tokens = newTokens

        Task {
            try? await refreshBalances()
            try? await refreshPrices()
        }
    }

    // MARK: - Private Helpers

    private func authenticateForSigningIfEnabled(reason: String) async throws {
        guard securityService.isBiometricAuthEnabled else { return }
        let authenticated = try await biometric.authenticate(reason: reason)
        guard authenticated else {
            throw AppWalletError.authenticationFailed
        }
    }

    /// Authenticates with Face ID and returns the LAContext so the Secure Enclave
    /// can reuse it without prompting a second time.
    private func authenticateForSigning(reason: String) async throws -> LAContext? {
        guard securityService.isBiometricAuthEnabled else { return nil }

        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return nil
        }

        let success = try await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        )
        guard success else {
            throw AppWalletError.authenticationFailed
        }

        return context
    }

    /// Decrypts the seed using the full SE + password pipeline.
    private func decryptSeed(password: String, context: LAContext? = nil) throws -> Data {
        guard let doubleEncrypted = try keychain.load(key: WalletKeychainKeys.encryptedSeed) else {
            throw AppWalletError.seedNotFound
        }
        let packed = try secureEnclave.decrypt(data: doubleEncrypted, context: context)
        let (salt, ciphertext) = try backup.unpackSaltAndCiphertext(from: packed)
        return try decryptSeedWithPassword(
            ciphertext: ciphertext,
            salt: salt,
            password: password
        )
    }

    private func loadWalletMetadata() {
        guard let wallet = accountManager.loadWalletMetadata() else { return }

        currentWallet = wallet
        activeAccountIndex = wallet.accountIndex
        addresses = wallet.addresses
        tokens = TokenModel.enabledDefaultTokens()

        if let loadedAccounts = accountManager.loadAccountsMetadata() {
            accounts = loadedAccounts
        } else {
            accounts = [wallet]
        }

        guard let ethAddr = addresses["ethereum"] else { return }
        let persisted = TokenDiscoveryService.shared.loadPersistedTokens(for: ethAddr)
        let existingContracts = Set(tokens.compactMap { $0.contractAddress?.lowercased() })
        for dt in persisted {
            if existingContracts.contains(dt.contractAddress.lowercased()) { continue }
            tokens.append(TokenModel(
                id: UUID(), symbol: dt.symbol, name: dt.name, chain: dt.chain,
                contractAddress: dt.contractAddress, decimals: dt.decimals, balance: 0, priceUsd: 0
            ))
        }

        let manualTokens = ManualTokenService.shared.loadPersistedTokens(for: ethAddr)
        let existingAfterDiscovery = Set(tokens.compactMap { $0.contractAddress?.lowercased() })
        for mt in manualTokens {
            if existingAfterDiscovery.contains(mt.contractAddress.lowercased()) { continue }
            tokens.append(TokenModel(
                id: UUID(), symbol: mt.symbol, name: mt.name, chain: mt.chain,
                contractAddress: mt.contractAddress, decimals: mt.decimals, balance: 0, priceUsd: 0
            ))
        }
    }
}

// MARK: - SessionLockDelegate

extension WalletService: SessionLockDelegate {
    func validatePassword(_ password: String) async throws {
        try await setSessionPassword(password)
    }

    func cacheSessionPassword(_ password: String) {
        sessionPasswordBytes = ContiguousArray(password.utf8)
    }

    func didUnlock() async {
        try? await refreshBalances()
        try? await refreshPrices()
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
