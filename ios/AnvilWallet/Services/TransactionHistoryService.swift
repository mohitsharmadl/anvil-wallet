import Foundation

/// TransactionHistoryService fetches transaction history from blockchain explorers
/// and maintains an in-memory cache to avoid hammering APIs on repeated tab switches.
///
/// Supported chains:
///   - Bitcoin: Blockstream/Mempool REST API (no auth)
///   - Solana: getSignaturesForAddress + getTransaction RPC (no auth)
///   - EVM (all 7 chains): Etherscan-family APIs via `chain.explorerApiUrl`
///   - Zcash: Blockchair address + transaction dashboards
final class TransactionHistoryService {
    static let shared = TransactionHistoryService()

    private let session: URLSession
    // Etherscan API key injected via Secrets.xcconfig -> Info.plist at build time.
    // Empty = Etherscan mainnet tx history silently disabled (other *scan explorers work without key).
    private let etherscanApiKey: String = {
        Bundle.main.object(forInfoDictionaryKey: "EtherscanApiKey") as? String ?? ""
    }()

    // MARK: - Cache

    /// Per-chain cached results with timestamp for TTL expiration.
    private struct CacheEntry {
        let transactions: [TransactionModel]
        let fetchedAt: Date
    }

    /// Cache keyed by chain ID. Protected by serial access (only called from async contexts).
    private var cache: [String: CacheEntry] = [:]

    /// Cache TTL: 60 seconds. Within this window, repeated calls return cached data.
    private let cacheTTL: TimeInterval = 60

    /// Locally-stored pending transactions created in-app (not yet on-chain).
    /// These are merged with fetched history and deduplicated by tx hash.
    private var localPendingTransactions: [TransactionModel] = []

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(
            configuration: config,
            delegate: CertificatePinner(),
            delegateQueue: nil
        )
    }

    // MARK: - Local Pending Transactions

    /// Adds a locally-created transaction (e.g. just sent from ConfirmTransactionView).
    /// This ensures the tx shows up immediately in ActivityView before the indexer picks it up.
    func addLocalTransaction(_ tx: TransactionModel) {
        // Avoid duplicates
        if !localPendingTransactions.contains(where: { $0.hash == tx.hash }) {
            localPendingTransactions.insert(tx, at: 0)
        }
    }

    /// Clears all local pending transactions (e.g. on wallet deletion).
    func clearLocalTransactions() {
        localPendingTransactions.removeAll()
        cache.removeAll()
    }

    // MARK: - Fetch All

    /// Fetches transactions for all chains that have an address.
    /// Merges remote history with local pending transactions and deduplicates by tx hash.
    func fetchAllTransactions(addresses: [String: String]) async throws -> [TransactionModel] {
        var allTransactions: [TransactionModel] = []

        // Fetch in parallel using a task group
        try await withThrowingTaskGroup(of: [TransactionModel].self) { group in
            for (chainId, address) in addresses {
                guard let chain = ChainModel.defaults.first(where: { $0.id == chainId }) else { continue }

                switch chain.chainType {
                case .bitcoin:
                    group.addTask { [self] in
                        await self.fetchWithCache(chainId: chainId) {
                            try await self.fetchBitcoinTransactions(address: address, apiUrl: chain.activeRpcUrl)
                        }
                    }
                case .solana:
                    group.addTask { [self] in
                        await self.fetchWithCache(chainId: chainId) {
                            try await self.fetchSolanaTransactions(address: address, rpcUrl: chain.activeRpcUrl)
                        }
                    }
                case .evm:
                    // Fetch from all EVM chains that have an explorer API URL.
                    // Each chain has its own transaction history even though they share
                    // the same address, so we fetch each one independently.
                    guard chain.explorerApiUrl != nil else { continue }

                    group.addTask { [self] in
                        await self.fetchWithCache(chainId: chainId) {
                            try await self.fetchEVMTransactions(address: address, chain: chain)
                        }
                    }

                case .zcash:
                    group.addTask { [self] in
                        await self.fetchWithCache(chainId: chainId) {
                            try await self.fetchZcashTransactions(address: address)
                        }
                    }
                }
            }

            for try await txs in group {
                allTransactions.append(contentsOf: txs)
            }
        }

        // Merge with local pending transactions
        let localTxs = localPendingTransactions
        allTransactions.append(contentsOf: localTxs)

        // Deduplicate by tx hash (prefer remote/confirmed over local/pending)
        var seen = Set<String>()
        var deduplicated: [TransactionModel] = []

        // Sort so confirmed transactions come first for dedup preference
        let sorted = allTransactions.sorted { lhs, rhs in
            if lhs.status == .confirmed && rhs.status != .confirmed { return true }
            if lhs.status != .confirmed && rhs.status == .confirmed { return false }
            return lhs.timestamp > rhs.timestamp
        }

        for tx in sorted {
            let key = tx.hash.lowercased()
            if seen.insert(key).inserted {
                deduplicated.append(tx)
            }
        }

        // Promote local pending txs that now appear as confirmed
        let confirmedHashes = Set(deduplicated.filter { $0.status == .confirmed }.map { $0.hash.lowercased() })
        localPendingTransactions.removeAll { confirmedHashes.contains($0.hash.lowercased()) }

        // Final sort by timestamp descending
        return deduplicated.sorted { $0.timestamp > $1.timestamp }
    }

    /// Fetches transactions for a single chain, using cache if available.
    /// Returns cached results if within TTL, otherwise fetches fresh data.
    /// On fetch failure, returns cached data if available, otherwise empty array.
    private func fetchWithCache(chainId: String, fetch: () async throws -> [TransactionModel]) async -> [TransactionModel] {
        // Check cache
        if let entry = cache[chainId],
           Date().timeIntervalSince(entry.fetchedAt) < cacheTTL {
            return entry.transactions
        }

        do {
            let txs = try await fetch()
            cache[chainId] = CacheEntry(transactions: txs, fetchedAt: Date())
            return txs
        } catch {
            // On error, return stale cache if available
            return cache[chainId]?.transactions ?? []
        }
    }

    /// Invalidates the cache for all chains, forcing fresh fetches on next call.
    func invalidateCache() {
        cache.removeAll()
    }

    /// Invalidates the cache for a specific chain.
    func invalidateCache(for chainId: String) {
        cache.removeValue(forKey: chainId)
    }

    // MARK: - Bitcoin (Blockstream/Mempool API)

    private func fetchBitcoinTransactions(address: String, apiUrl: String) async throws -> [TransactionModel] {
        guard let url = URL(string: "\(apiUrl)/address/\(address)/txs") else { return [] }
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else { return [] }

        struct BTCTx: Decodable {
            let txid: String
            let status: Status
            let vin: [Vin]
            let vout: [Vout]
            let fee: Int?

            struct Status: Decodable {
                let confirmed: Bool
                let block_time: Int?
            }
            struct Vin: Decodable {
                let prevout: Prevout?
                struct Prevout: Decodable {
                    let scriptpubkey_address: String?
                    let value: Int?
                }
            }
            struct Vout: Decodable {
                let scriptpubkey_address: String?
                let value: Int?
            }
        }

        let txs = try JSONDecoder().decode([BTCTx].self, from: data)
        let lowerAddress = address.lowercased()

        return txs.prefix(50).compactMap { tx in
            let isSent = tx.vin.contains { $0.prevout?.scriptpubkey_address?.lowercased() == lowerAddress }
            let totalReceived = tx.vout
                .filter { $0.scriptpubkey_address?.lowercased() == lowerAddress }
                .compactMap { $0.value }
                .reduce(0, +)
            let totalSent = tx.vin
                .filter { $0.prevout?.scriptpubkey_address?.lowercased() == lowerAddress }
                .compactMap { $0.prevout?.value }
                .reduce(0, +)
            let amount = isSent ? totalSent - totalReceived : totalReceived
            let amountBTC = Double(amount) / 100_000_000.0

            let fromAddr = tx.vin.first?.prevout?.scriptpubkey_address ?? "unknown"
            let toAddr = tx.vout.first(where: { $0.scriptpubkey_address?.lowercased() != lowerAddress })?.scriptpubkey_address
                ?? tx.vout.first?.scriptpubkey_address ?? "unknown"

            let feeBTC = Double(tx.fee ?? 0) / 100_000_000.0

            let timestamp: Date
            if let blockTime = tx.status.block_time {
                timestamp = Date(timeIntervalSince1970: TimeInterval(blockTime))
            } else {
                timestamp = Date()
            }

            return TransactionModel(
                hash: tx.txid,
                chain: "bitcoin",
                from: fromAddr,
                to: toAddr,
                amount: String(format: "%.8f", amountBTC),
                fee: String(format: "%.8f", feeBTC),
                status: tx.status.confirmed ? .confirmed : .pending,
                timestamp: timestamp,
                tokenSymbol: "BTC",
                tokenDecimals: 8
            )
        }
    }

    // MARK: - Solana (RPC getSignaturesForAddress + getTransaction)

    private func fetchSolanaTransactions(address: String, rpcUrl: String) async throws -> [TransactionModel] {
        struct SigInfo: Decodable {
            let signature: String
            let blockTime: Int?
            let err: AnyCodable?
            let memo: String?
        }

        struct AnyCodable: Decodable {
            init(from decoder: Decoder) throws {
                _ = try decoder.singleValueContainer()
            }
        }

        let signatures: [SigInfo] = try await RPCService.shared.call(
            url: rpcUrl,
            method: "getSignaturesForAddress",
            params: [
                .string(address),
                .dictionary(["limit": .int(30)])
            ]
        )

        // Fetch full transaction details in batches of 10
        var transactions: [TransactionModel] = []
        let batchSize = 10

        for startIndex in stride(from: 0, to: signatures.count, by: batchSize) {
            let endIndex = min(startIndex + batchSize, signatures.count)
            let batch = Array(signatures[startIndex..<endIndex])

            await withTaskGroup(of: TransactionModel?.self) { group in
                for sig in batch {
                    group.addTask { [self] in
                        await self.fetchSolanaTransactionDetail(
                            signature: sig.signature,
                            blockTime: sig.blockTime,
                            hasError: sig.err != nil,
                            userAddress: address,
                            rpcUrl: rpcUrl
                        )
                    }
                }
                for await tx in group {
                    if let tx { transactions.append(tx) }
                }
            }
        }

        return transactions.sorted { $0.timestamp > $1.timestamp }
    }

    /// Fetches a single Solana transaction's details via `getTransaction` (jsonParsed).
    private func fetchSolanaTransactionDetail(
        signature: String,
        blockTime: Int?,
        hasError: Bool,
        userAddress: String,
        rpcUrl: String
    ) async -> TransactionModel? {
        struct SolTxResponse: Decodable {
            let transaction: SolTransaction?
            let meta: SolMeta?

            struct SolTransaction: Decodable {
                let message: SolMessage
            }
            struct SolMessage: Decodable {
                let instructions: [SolInstruction]
            }
            struct SolInstruction: Decodable {
                let programId: String?
                let parsed: SolParsed?

                enum CodingKeys: String, CodingKey {
                    case programId, parsed
                }
                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    programId = try container.decodeIfPresent(String.self, forKey: .programId)
                    // parsed may be an object or absent; silently nil on shape mismatch
                    parsed = try? container.decodeIfPresent(SolParsed.self, forKey: .parsed)
                }
            }
            struct SolParsed: Decodable {
                let type: String?
                let info: SolTransferInfo?
            }
            struct SolTransferInfo: Decodable {
                let source: String?
                let destination: String?
                let lamports: UInt64?
            }
            struct SolMeta: Decodable {
                let fee: UInt64?
            }
        }

        let timestamp: Date
        if let blockTime {
            timestamp = Date(timeIntervalSince1970: TimeInterval(blockTime))
        } else {
            timestamp = Date()
        }

        do {
            let result: SolTxResponse = try await RPCService.shared.call(
                url: rpcUrl,
                method: "getTransaction",
                params: [
                    .string(signature),
                    .dictionary([
                        "encoding": .string("jsonParsed"),
                        "maxSupportedTransactionVersion": .int(0)
                    ])
                ]
            )

            // Find system program transfer instruction
            let systemProgramId = "11111111111111111111111111111111"
            let transferInstruction = result.transaction?.message.instructions.first { instr in
                instr.programId == systemProgramId && instr.parsed?.type == "transfer"
            }

            let fee = Double(result.meta?.fee ?? 0) / 1_000_000_000.0

            if let info = transferInstruction?.parsed?.info,
               let lamports = info.lamports {
                let solAmount = Double(lamports) / 1_000_000_000.0
                return TransactionModel(
                    hash: signature,
                    chain: "solana",
                    from: info.source ?? userAddress,
                    to: info.destination ?? "unknown",
                    amount: String(format: "%.9f", solAmount),
                    fee: String(format: "%.9f", fee),
                    status: hasError ? .failed : .confirmed,
                    timestamp: timestamp,
                    tokenSymbol: "SOL",
                    tokenDecimals: 9
                )
            } else {
                // Non-transfer tx (token swap, program call, etc.)
                return TransactionModel(
                    hash: signature,
                    chain: "solana",
                    from: userAddress,
                    to: "unknown",
                    amount: "0",
                    fee: String(format: "%.9f", fee),
                    status: hasError ? .failed : .confirmed,
                    timestamp: timestamp,
                    tokenSymbol: "SOL",
                    tokenDecimals: 9
                )
            }
        } catch {
            // Fallback if getTransaction fails -- show basic entry
            return TransactionModel(
                hash: signature,
                chain: "solana",
                from: userAddress,
                to: "unknown",
                amount: "0",
                fee: "0",
                status: hasError ? .failed : .confirmed,
                timestamp: timestamp,
                tokenSymbol: "SOL",
                tokenDecimals: 9
            )
        }
    }

    // MARK: - EVM (Etherscan-family APIs)

    // MARK: - Zcash (Blockchair API)

    private func fetchZcashTransactions(address: String) async throws -> [TransactionModel] {
        guard let encodedAddress = address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.blockchair.com/zcash/dashboards/address/\(encodedAddress)?limit=30") else {
            return []
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return []
        }

        struct AddressResponse: Decodable {
            struct AddressData: Decodable {
                let transactions: [String]
            }
            let data: [String: AddressData]
        }

        let parsed = try JSONDecoder().decode(AddressResponse.self, from: data)
        guard let txHashes = parsed.data.values.first?.transactions else {
            return []
        }

        var transactions: [TransactionModel] = []
        for hash in txHashes.prefix(30) {
            if let tx = try await fetchZcashTransactionDetail(hash: hash, userAddress: address) {
                transactions.append(tx)
            }
        }

        return transactions.sorted { $0.timestamp > $1.timestamp }
    }

    private func fetchZcashTransactionDetail(hash: String, userAddress: String) async throws -> TransactionModel? {
        guard let url = URL(string: "https://api.blockchair.com/zcash/dashboards/transaction/\(hash)") else {
            return nil
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        struct TxDetailResponse: Decodable {
            struct TxContainer: Decodable {
                struct TxCore: Decodable {
                    let hash: String
                    let time: String?
                    let fee: UInt64?
                }
                struct TxInput: Decodable {
                    let recipient: String?
                    let value: UInt64?
                }
                struct TxOutput: Decodable {
                    let recipient: String?
                    let value: UInt64?
                }

                let transaction: TxCore
                let inputs: [TxInput]
                let outputs: [TxOutput]
            }
            let data: [String: TxContainer]
        }

        let detail = try JSONDecoder().decode(TxDetailResponse.self, from: data)
        guard let tx = detail.data.values.first else { return nil }

        let lowerAddress = userAddress.lowercased()
        let isSent = tx.inputs.contains { $0.recipient?.lowercased() == lowerAddress }

        let totalReceived = tx.outputs
            .filter { $0.recipient?.lowercased() == lowerAddress }
            .compactMap { $0.value }
            .reduce(0, +)
        let totalSent = tx.inputs
            .filter { $0.recipient?.lowercased() == lowerAddress }
            .compactMap { $0.value }
            .reduce(0, +)

        let amountZat = isSent ? max(0, Int64(totalSent) - Int64(totalReceived)) : Int64(totalReceived)
        let amountZec = Double(amountZat) / 100_000_000.0
        let feeZec = Double(tx.transaction.fee ?? 0) / 100_000_000.0

        let fromAddr = tx.inputs.first?.recipient ?? "unknown"
        let toAddr = tx.outputs.first(where: { $0.recipient?.lowercased() != lowerAddress })?.recipient
            ?? tx.outputs.first?.recipient
            ?? "unknown"

        let timestamp: Date = {
            guard let timeStr = tx.transaction.time else { return Date() }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.date(from: timeStr) ?? Date()
        }()

        return TransactionModel(
            hash: tx.transaction.hash,
            chain: "zcash",
            from: fromAddr,
            to: toAddr,
            amount: String(format: "%.8f", amountZec),
            fee: String(format: "%.8f", feeZec),
            status: .confirmed,
            timestamp: timestamp,
            tokenSymbol: "ZEC",
            tokenDecimals: 8
        )
    }

    // MARK: - EVM (Etherscan-family APIs)

    private func fetchEVMTransactions(address: String, chain: ChainModel) async throws -> [TransactionModel] {
        guard let explorerApiUrl = chain.explorerApiUrl else { return [] }

        // Build the txlist query URL using the chain's explorer API
        var urlString = "\(explorerApiUrl)?module=account&action=txlist&address=\(address)&startblock=0&endblock=99999999&page=1&offset=50&sort=desc"

        // Attach Etherscan API key only for etherscan.io domains where our key works
        if !etherscanApiKey.isEmpty, let host = URLComponents(string: explorerApiUrl)?.host,
           host.hasSuffix("etherscan.io") || host.hasSuffix("etherscan.com") {
            urlString += "&apikey=\(etherscanApiKey)"
        }

        guard let url = URL(string: urlString) else { return [] }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else { return [] }

        struct EtherscanResponse: Decodable {
            let status: String
            let result: [EtherscanTx]?

            struct EtherscanTx: Decodable {
                let hash: String
                let from: String
                let to: String
                let value: String
                let gasUsed: String
                let gasPrice: String
                let timeStamp: String
                let isError: String
            }
        }

        let ethResponse = try JSONDecoder().decode(EtherscanResponse.self, from: data)
        guard let txs = ethResponse.result else { return [] }

        let nativeSymbol = chain.symbol

        return txs.compactMap { tx in
            let weiValue = Double(tx.value) ?? 0
            let ethValue = weiValue / 1e18
            let gasUsed = Double(tx.gasUsed) ?? 0
            let gasPrice = Double(tx.gasPrice) ?? 0
            let feeEth = (gasUsed * gasPrice) / 1e18
            let timestamp = Date(timeIntervalSince1970: TimeInterval(Int(tx.timeStamp) ?? 0))

            return TransactionModel(
                hash: tx.hash,
                chain: chain.id,
                from: tx.from,
                to: tx.to,
                amount: String(format: "%.6f", ethValue),
                fee: String(format: "%.6f", feeEth),
                status: tx.isError == "0" ? .confirmed : .failed,
                timestamp: timestamp,
                tokenSymbol: nativeSymbol,
                tokenDecimals: 18
            )
        }
    }
}
