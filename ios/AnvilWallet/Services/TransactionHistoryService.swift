import Foundation

/// TransactionHistoryService fetches transaction history from blockchain explorers.
///
/// Supported chains:
///   - Bitcoin: Blockstream REST API (no auth)
///   - Solana: getSignaturesForAddress RPC (no auth)
///   - EVM (Ethereum): Etherscan API (free tier API key)
final class TransactionHistoryService {
    static let shared = TransactionHistoryService()

    private let session: URLSession
    // Etherscan API key injected via Secrets.xcconfig → Info.plist at build time.
    // Empty = EVM tx history silently disabled.
    private let etherscanApiKey: String = {
        Bundle.main.object(forInfoDictionaryKey: "EtherscanApiKey") as? String ?? ""
    }()

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(
            configuration: config,
            delegate: CertificatePinner(),
            delegateQueue: nil
        )
    }

    /// Fetches transactions for all chains that have an address.
    func fetchAllTransactions(addresses: [String: String]) async throws -> [TransactionModel] {
        var allTransactions: [TransactionModel] = []

        // Fetch in parallel using a task group
        try await withThrowingTaskGroup(of: [TransactionModel].self) { group in
            for (chainId, address) in addresses {
                guard let chain = ChainModel.defaults.first(where: { $0.id == chainId }) else { continue }
                // Only fetch for primary chains (not duplicated EVM addresses)
                let shouldFetch: Bool
                switch chain.chainType {
                case .bitcoin: shouldFetch = true
                case .solana: shouldFetch = true
                case .evm: shouldFetch = (chainId == "ethereum") // Start with ETH mainnet only
                }
                guard shouldFetch else { continue }

                group.addTask { [self] in
                    do {
                        switch chain.chainType {
                        case .bitcoin:
                            return try await self.fetchBitcoinTransactions(address: address, apiUrl: chain.rpcUrl)
                        case .solana:
                            return try await self.fetchSolanaTransactions(address: address, rpcUrl: chain.rpcUrl)
                        case .evm:
                            return try await self.fetchEVMTransactions(address: address, chain: chain)
                        }
                    } catch {
                        return [] // Don't fail the whole batch for one chain
                    }
                }
            }

            for try await txs in group {
                allTransactions.append(contentsOf: txs)
            }
        }

        // Sort by timestamp descending (newest first)
        return allTransactions.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - Bitcoin (Blockstream API)

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
                fee: "0",
                status: tx.status.confirmed ? .confirmed : .pending,
                timestamp: timestamp,
                tokenSymbol: "BTC",
                tokenDecimals: 8
            )
        }
    }

    // MARK: - Solana (RPC getSignaturesForAddress + getTransaction)

    private func fetchSolanaTransactions(address: String, rpcUrl: String) async throws -> [TransactionModel] {
        let rpc = RPCService.shared

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

        let signatures: [SigInfo] = try await rpc.call(
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
            // Fallback if getTransaction fails — show basic entry
            return TransactionModel(
                hash: signature,
                chain: "solana",
                from: userAddress,
                to: "unknown",
                amount: "—",
                fee: "0",
                status: hasError ? .failed : .confirmed,
                timestamp: timestamp,
                tokenSymbol: "SOL",
                tokenDecimals: 9
            )
        }
    }

    // MARK: - EVM (Etherscan API)

    private func fetchEVMTransactions(address: String, chain: ChainModel) async throws -> [TransactionModel] {
        // Only Ethereum mainnet for now (requires Etherscan API key)
        guard chain.id == "ethereum", !etherscanApiKey.isEmpty else { return [] }

        let urlString = "https://api.etherscan.io/api?module=account&action=txlist&address=\(address)&startblock=0&endblock=99999999&page=1&offset=50&sort=desc&apikey=\(etherscanApiKey)"
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

        return txs.compactMap { tx in
            let weiValue = Double(tx.value) ?? 0
            let ethValue = weiValue / 1e18
            let gasUsed = Double(tx.gasUsed) ?? 0
            let gasPrice = Double(tx.gasPrice) ?? 0
            let feeEth = (gasUsed * gasPrice) / 1e18
            let timestamp = Date(timeIntervalSince1970: TimeInterval(Int(tx.timeStamp) ?? 0))

            return TransactionModel(
                hash: tx.hash,
                chain: "ethereum",
                from: tx.from,
                to: tx.to,
                amount: String(format: "%.6f", ethValue),
                fee: String(format: "%.6f", feeEth),
                status: tx.isError == "0" ? .confirmed : .failed,
                timestamp: timestamp,
                tokenSymbol: "ETH",
                tokenDecimals: 18
            )
        }
    }
}
