import Foundation

/// RPCService provides a generic JSON-RPC client for communicating with
/// blockchain nodes across all supported chains.
///
/// Supports:
///   - EVM chains (Ethereum JSON-RPC)
///   - Solana (JSON-RPC)
///   - Bitcoin (REST API via Blockstream/Mempool)
///
/// Security:
///   - Certificate pinning via native URLSession delegate
///   - All connections over HTTPS
///   - Request timeout of 30 seconds
final class RPCService {

    static let shared = RPCService()

    private let session: URLSession
    private let requestTimeout: TimeInterval = 30
    private let maxRetryAttempts = 2
    /// RPC endpoint fallbacks by primary URL.
    /// These are only used when the primary endpoint fails.
    private let rpcFallbacks: [String: [String]] = [
        "https://rpc.ankr.com/eth": ["https://ethereum.publicnode.com"],
        "https://polygon-rpc.com": ["https://polygon-bor-rpc.publicnode.com"],
        "https://arb1.arbitrum.io/rpc": ["https://arbitrum-one-rpc.publicnode.com"],
        "https://mainnet.base.org": ["https://base-rpc.publicnode.com"],
        "https://mainnet.optimism.io": ["https://optimism-rpc.publicnode.com"],
        "https://bsc-dataseed.binance.org": ["https://bsc-rpc.publicnode.com"],
        "https://api.avax.network/ext/bc/C/rpc": ["https://avalanche-c-chain-rpc.publicnode.com"],
        "https://api.mainnet-beta.solana.com": ["https://solana-rpc.publicnode.com"]
    ]

    struct RPCRequest: Encodable {
        let jsonrpc: String = "2.0"
        let method: String
        let params: [RPCParam]
        let id: Int

        enum RPCParam: Encodable {
            case string(String)
            case int(Int)
            case bool(Bool)
            case array([RPCParam])
            case dictionary([String: RPCParam])
            case null

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .string(let value):
                    try container.encode(value)
                case .int(let value):
                    try container.encode(value)
                case .bool(let value):
                    try container.encode(value)
                case .array(let value):
                    try container.encode(value)
                case .dictionary(let value):
                    try container.encode(value)
                case .null:
                    try container.encodeNil()
                }
            }
        }
    }

    struct RPCResponse<T: Decodable>: Decodable {
        let jsonrpc: String?
        let id: Int?
        let result: T?
        let error: RPCError?
    }

    struct RPCError: Decodable, LocalizedError {
        let code: Int
        let message: String
        let data: String?

        var errorDescription: String? {
            "RPC Error \(code): \(message)"
        }
    }

    enum RPCServiceError: LocalizedError {
        case invalidURL
        case invalidResponse
        case httpError(Int)
        case rpcError(RPCError)
        case decodingError(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid RPC endpoint URL."
            case .invalidResponse:
                return "Invalid response from RPC server."
            case .httpError(let code):
                return "HTTP error \(code)."
            case .rpcError(let error):
                return error.errorDescription
            case .decodingError(let message):
                return "Failed to decode RPC response: \(message)"
            }
        }
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout * 2
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        session = URLSession(
            configuration: config,
            delegate: CertificatePinner(),
            delegateQueue: nil
        )
    }

    // MARK: - Generic RPC Call

    /// Performs a JSON-RPC call and returns the decoded result.
    ///
    /// - Parameters:
    ///   - url: The RPC endpoint URL string
    ///   - method: The RPC method name (e.g., "eth_getBalance")
    ///   - params: The method parameters
    /// - Returns: The decoded result of type T
    func call<T: Decodable>(
        url: String,
        method: String,
        params: [RPCRequest.RPCParam]
    ) async throws -> T {
        let candidates = [url] + (rpcFallbacks[url] ?? [])
        var lastError: Error?

        for candidateUrl in candidates {
            do {
                guard let endpoint = URL(string: candidateUrl), endpoint.scheme == "https" else {
                    continue
                }

                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                let rpcRequest = RPCRequest(method: method, params: params, id: 1)
                request.httpBody = try JSONEncoder().encode(rpcRequest)

                return try await withRetry { [self] in
                    let (data, response) = try await session.data(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw RPCServiceError.invalidResponse
                    }

                    guard (200...299).contains(httpResponse.statusCode) else {
                        throw RPCServiceError.httpError(httpResponse.statusCode)
                    }

                    let rpcResponse = try JSONDecoder().decode(RPCResponse<T>.self, from: data)

                    if let error = rpcResponse.error {
                        throw RPCServiceError.rpcError(error)
                    }

                    guard let result = rpcResponse.result else {
                        throw RPCServiceError.invalidResponse
                    }

                    return result
                }
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? RPCServiceError.invalidURL
    }

    /// Retries transient networking failures with small exponential backoff.
    private func withRetry<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        var attempt = 0
        var lastError: Error?

        while attempt <= maxRetryAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                if !isRetryable(error) || attempt == maxRetryAttempts {
                    throw error
                }
                let backoffMs = UInt64(250 * (1 << attempt))
                try? await Task.sleep(nanoseconds: backoffMs * 1_000_000)
                attempt += 1
            }
        }

        throw lastError ?? RPCServiceError.invalidResponse
    }

    private func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet:
                return true
            default:
                return false
            }
        }
        if let rpcError = error as? RPCServiceError,
           case .httpError(let statusCode) = rpcError {
            return statusCode >= 500
        }
        return false
    }

    // MARK: - EVM-specific Methods

    /// Gets the balance of an EVM address in wei (returned as hex string).
    func getBalance(rpcUrl: String, address: String) async throws -> String {
        try await call(
            url: rpcUrl,
            method: "eth_getBalance",
            params: [.string(address), .string("latest")]
        )
    }

    /// Gets the transaction count (nonce) for an EVM address.
    func getTransactionCount(rpcUrl: String, address: String) async throws -> String {
        try await call(
            url: rpcUrl,
            method: "eth_getTransactionCount",
            params: [.string(address), .string("latest")]
        )
    }

    /// Estimates gas for a transaction.
    func estimateGas(rpcUrl: String, from: String, to: String, value: String, data: String?) async throws -> String {
        var txParams: [String: RPCRequest.RPCParam] = [
            "from": .string(from),
            "to": .string(to),
            "value": .string(value),
        ]
        if let data = data {
            txParams["data"] = .string(data)
        }
        return try await call(
            url: rpcUrl,
            method: "eth_estimateGas",
            params: [.dictionary(txParams)]
        )
    }

    /// Gets the current gas price.
    func gasPrice(rpcUrl: String) async throws -> String {
        try await call(
            url: rpcUrl,
            method: "eth_gasPrice",
            params: []
        )
    }

    /// Sends a signed transaction.
    func sendRawTransaction(rpcUrl: String, signedTx: String) async throws -> String {
        try await call(
            url: rpcUrl,
            method: "eth_sendRawTransaction",
            params: [.string(signedTx)]
        )
    }

    /// Returns true if an EVM transaction has a mined receipt.
    func isEvmTransactionConfirmed(rpcUrl: String, txHash: String) async throws -> Bool {
        struct Receipt: Decodable {
            let blockNumber: String?
        }

        let receipt: Receipt? = try await call(
            url: rpcUrl,
            method: "eth_getTransactionReceipt",
            params: [.string(txHash)]
        )

        return receipt?.blockNumber != nil
    }

    /// Calls a contract function without sending a transaction (read-only).
    func ethCall(rpcUrl: String, to: String, data: String) async throws -> String {
        try await call(
            url: rpcUrl,
            method: "eth_call",
            params: [
                .dictionary(["to": .string(to), "data": .string(data)]),
                .string("latest"),
            ]
        )
    }

    /// Calls a contract function with a `from` address (for simulation).
    func ethCall(rpcUrl: String, from: String, to: String, value: String?, data: String) async throws -> String {
        var txParams: [String: RPCRequest.RPCParam] = [
            "from": .string(from),
            "to": .string(to),
            "data": .string(data),
        ]
        if let value = value {
            txParams["value"] = .string(value)
        }
        return try await call(
            url: rpcUrl,
            method: "eth_call",
            params: [
                .dictionary(txParams),
                .string("latest"),
            ]
        )
    }

    /// Gets the current block number.
    func blockNumber(rpcUrl: String) async throws -> String {
        try await call(
            url: rpcUrl,
            method: "eth_blockNumber",
            params: []
        )
    }

    /// Fetches EIP-1559 fee data: base fee from the latest block + priority fee percentiles.
    /// Returns (baseFeePerGas, suggestedPriorityFee) as hex strings.
    func feeHistory(rpcUrl: String) async throws -> (baseFeeHex: String, priorityFeeHex: String) {
        // Request 1 block of history, 50th percentile of priority fees
        struct FeeHistoryResult: Decodable {
            let baseFeePerGas: [String]?
            let reward: [[String]]?
        }

        let result: FeeHistoryResult = try await call(
            url: rpcUrl,
            method: "eth_feeHistory",
            params: [.string("0x1"), .string("latest"), .array([.int(50)])]
        )

        // baseFeePerGas has N+1 entries for N blocks; last entry is the pending block's base fee
        let baseFeeHex = result.baseFeePerGas?.last ?? "0x0"
        // reward[0][0] is the 50th-percentile priority fee from the sampled block
        let priorityFeeHex = result.reward?.first?.first ?? "0x59682f00" // fallback: 1.5 gwei

        return (baseFeeHex: baseFeeHex, priorityFeeHex: priorityFeeHex)
    }

    // MARK: - Solana-specific Methods

    /// Gets the SOL balance for a Solana address.
    func getSolanaBalance(rpcUrl: String, address: String) async throws -> Int {
        // Solana getBalance returns { value: <lamports> }
        let result: [String: Int] = try await call(
            url: rpcUrl,
            method: "getBalance",
            params: [.string(address)]
        )
        return result["value"] ?? 0
    }

    /// Gets a recent blockhash from Solana for transaction signing.
    /// Returns 32 bytes of the blockhash decoded from base58.
    func getRecentBlockhash(rpcUrl: String) async throws -> Data {
        struct BlockhashResult: Decodable {
            struct Value: Decodable {
                let blockhash: String
            }
            let value: Value
        }

        let result: BlockhashResult = try await call(
            url: rpcUrl,
            method: "getLatestBlockhash",
            params: []
        )

        // Decode base58 blockhash to 32 bytes
        guard let hashData = Base58.decode(result.value.blockhash),
              hashData.count == 32 else {
            throw RPCServiceError.decodingError("Invalid blockhash from Solana RPC")
        }
        return hashData
    }

    /// Returns the minimum lamports required for rent exemption for given account size.
    func getSolanaRentExemption(rpcUrl: String, dataSize: Int) async throws -> UInt64 {
        let result: UInt64 = try await call(
            url: rpcUrl,
            method: "getMinimumBalanceForRentExemption",
            params: [.int(dataSize)]
        )
        return result
    }

    /// Returns a high-stake, low-commission validator vote account for delegation.
    func getTopSolanaValidatorVoteAccount(rpcUrl: String) async throws -> String {
        struct VoteAccounts: Decodable {
            struct Vote: Decodable {
                let votePubkey: String
                let activatedStake: String?
                let commission: Int?
            }
            let current: [Vote]
        }

        let result: VoteAccounts = try await call(
            url: rpcUrl,
            method: "getVoteAccounts",
            params: []
        )

        let filtered = result.current.filter { ($0.commission ?? 100) <= 10 }
        let sorted = filtered.sorted {
            (UInt64($0.activatedStake ?? "0") ?? 0) > (UInt64($1.activatedStake ?? "0") ?? 0)
        }
        return sorted.first?.votePubkey ?? result.current.first?.votePubkey ?? ""
    }

    /// Sends a signed Solana transaction. Returns the transaction signature.
    func sendSolanaTransaction(rpcUrl: String, signedTx: String) async throws -> String {
        try await call(
            url: rpcUrl,
            method: "sendTransaction",
            params: [
                .string(signedTx),
                .dictionary(["encoding": .string("base64")])
            ]
        )
    }

    /// Returns true if a Solana signature is confirmed/finalized.
    func isSolanaTransactionConfirmed(rpcUrl: String, signature: String) async throws -> Bool {
        struct SignatureStatuses: Decodable {
            struct Status: Decodable {
                let confirmationStatus: String?
            }
            let value: [Status?]
        }

        let statuses: SignatureStatuses = try await call(
            url: rpcUrl,
            method: "getSignatureStatuses",
            params: [
                .array([.string(signature)]),
                .dictionary(["searchTransactionHistory": .bool(true)])
            ]
        )

        guard let status = statuses.value.first ?? nil else { return false }
        return status.confirmationStatus == "confirmed" || status.confirmationStatus == "finalized"
    }

    /// Validates a URL string is well-formed and uses HTTPS.
    private func httpsURL(_ urlString: String) throws -> URL {
        guard let url = URL(string: urlString), url.scheme == "https" else {
            throw RPCServiceError.invalidURL
        }
        return url
    }

    // MARK: - Bitcoin-specific Methods (REST API)

    /// Fetches unspent transaction outputs (UTXOs) for a Bitcoin address.
    /// Uses Blockstream/Mempool REST API.
    ///
    /// Populates script_pubkey from the address: for P2WPKH (bc1q/tb1q),
    /// the script is `OP_0 <20-byte witness program>` derived from bech32.
    func getBitcoinUtxos(apiUrl: String, address: String) async throws -> [UtxoData] {
        let url = try httpsURL("\(apiUrl)/address/\(address)/utxo")

        // Derive P2WPKH scriptPubkey from the bech32 address
        let scriptPubkey = try Self.p2wpkhScriptPubkey(from: address)

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw RPCServiceError.invalidResponse
        }

        struct BlockstreamUtxo: Decodable {
            let txid: String
            let vout: UInt32
            let value: UInt64
            let status: Status

            struct Status: Decodable {
                let confirmed: Bool
            }
        }

        let utxos = try JSONDecoder().decode([BlockstreamUtxo].self, from: data)

        return utxos
            .filter { $0.status.confirmed }
            .map { utxo in
                UtxoData(
                    txid: utxo.txid,
                    vout: utxo.vout,
                    amountSat: utxo.value,
                    scriptPubkey: scriptPubkey
                )
            }
    }

    /// Derives P2WPKH scriptPubkey (OP_0 + PUSH20 + 20-byte witness program)
    /// from a bech32/bech32m address (bc1q... or tb1q...).
    private static func p2wpkhScriptPubkey(from address: String) throws -> Data {
        // Bech32 decode: strip HRP (bc1/tb1), decode the witness program
        guard let witnessProgram = Bech32.decode(address) else {
            throw RPCServiceError.decodingError("Invalid bech32 address: \(address)")
        }
        guard witnessProgram.count == 20 else {
            throw RPCServiceError.decodingError("Expected 20-byte witness program, got \(witnessProgram.count)")
        }
        // P2WPKH scriptPubkey: OP_0 (0x00) + OP_PUSH20 (0x14) + 20 bytes
        var script = Data([0x00, 0x14])
        script.append(witnessProgram)
        return script
    }

    /// Minimal bech32 decoder — extracts the witness program bytes from a bech32 address.
    private enum Bech32 {
        private static let charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

        /// Decodes a bech32/bech32m address and returns the witness program bytes.
        /// Returns nil on invalid input, mixed case, or checksum failure.
        static func decode(_ addr: String) -> Data? {
            // BIP-173: mixed case is invalid — must be all-lowercase or all-uppercase
            let hasLower = addr.contains(where: { $0.isLowercase && $0.isLetter })
            let hasUpper = addr.contains(where: { $0.isUppercase && $0.isLetter })
            guard !(hasLower && hasUpper) else { return nil }

            let lower = addr.lowercased()
            guard let sepIndex = lower.lastIndex(of: "1") else { return nil }
            let hrp = String(lower[lower.startIndex..<sepIndex])
            let dataPart = lower[lower.index(after: sepIndex)...]
            guard dataPart.count >= 7 else { return nil } // 1 witness version + 6 checksum

            // Decode from charset to 5-bit values
            var values: [UInt8] = []
            for char in dataPart {
                guard let idx = charset.firstIndex(of: char) else { return nil }
                values.append(UInt8(charset.distance(from: charset.startIndex, to: idx)))
            }

            // Verify checksum before stripping — bech32 polymod must equal 1
            guard verifyChecksum(hrp: hrp, values: values) else { return nil }

            // Strip checksum (last 6 values) and witness version (first value)
            guard values.count > 7 else { return nil }
            let witnessVersion = values[0]
            let data5bit = Array(values[1..<(values.count - 6)])

            // Convert from 5-bit groups to 8-bit bytes
            guard witnessVersion == 0, // P2WPKH uses witness version 0
                  let bytes = convertBits(data: data5bit, fromBits: 5, toBits: 8, pad: false) else {
                return nil
            }
            return Data(bytes)
        }

        /// Verifies the bech32 checksum using the BIP-173 polymod algorithm.
        private static func verifyChecksum(hrp: String, values: [UInt8]) -> Bool {
            let expanded = hrpExpand(hrp) + values
            return polymod(expanded) == 1 // bech32 constant
        }

        /// Expands the HRP for checksum computation per BIP-173.
        private static func hrpExpand(_ hrp: String) -> [UInt8] {
            var result: [UInt8] = []
            for c in hrp.unicodeScalars {
                result.append(UInt8(c.value >> 5))
            }
            result.append(0)
            for c in hrp.unicodeScalars {
                result.append(UInt8(c.value & 31))
            }
            return result
        }

        /// BIP-173 polymod function for bech32 checksum verification.
        private static func polymod(_ values: [UInt8]) -> UInt32 {
            let gen: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
            var chk: UInt32 = 1
            for v in values {
                let top = chk >> 25
                chk = ((chk & 0x1ffffff) << 5) ^ UInt32(v)
                for i in 0..<5 {
                    if (top >> i) & 1 != 0 {
                        chk ^= gen[i]
                    }
                }
            }
            return chk
        }

        /// Converts between bit groupings (e.g., 5-bit to 8-bit for bech32).
        private static func convertBits(data: [UInt8], fromBits: Int, toBits: Int, pad: Bool) -> [UInt8]? {
            var acc = 0
            var bits = 0
            var result: [UInt8] = []
            let maxv = (1 << toBits) - 1

            for value in data {
                if value < 0 || (value >> fromBits) != 0 { return nil }
                acc = (acc << fromBits) | Int(value)
                bits += fromBits
                while bits >= toBits {
                    bits -= toBits
                    result.append(UInt8((acc >> bits) & maxv))
                }
            }
            if pad {
                if bits > 0 {
                    result.append(UInt8((acc << (toBits - bits)) & maxv))
                }
            } else if bits >= fromBits || ((acc << (toBits - bits)) & maxv) != 0 {
                return nil
            }
            return result
        }
    }

    /// Tiered Bitcoin fee rates (sat/vB) for user selection.
    struct BitcoinFeeRates {
        /// ~10 min confirmation (next 1 block target)
        let fast: UInt64
        /// ~30 min confirmation (3-block target)
        let medium: UInt64
        /// ~60 min confirmation (6-block target)
        let slow: UInt64

        /// Human-readable labels for display.
        static let fastLabel = "Fast (~10 min)"
        static let mediumLabel = "Medium (~30 min)"
        static let slowLabel = "Slow (~60 min)"
    }

    /// Fetches recommended fee rates from Blockstream/Mempool API.
    /// Returns the recommended fee rate in sat/vbyte for medium-priority confirmation.
    func getBitcoinFeeRate(apiUrl: String) async throws -> UInt64 {
        let rates = try await getBitcoinFeeRates(apiUrl: apiUrl)
        return rates.medium
    }

    /// Fetches tiered fee rates (fast/medium/slow) from Blockstream/Mempool REST API.
    /// Response format: { "1": 50.5, "3": 30.2, "6": 15.1, ... } (sat/vB per block target).
    func getBitcoinFeeRates(apiUrl: String) async throws -> BitcoinFeeRates {
        let url = try httpsURL("\(apiUrl)/fee-estimates")

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw RPCServiceError.invalidResponse
        }

        let estimates = try JSONDecoder().decode([String: Double].self, from: data)

        // Map block targets to fee tiers; fall back gracefully
        let fast = estimates["1"] ?? estimates["2"] ?? 10.0
        let medium = estimates["3"] ?? estimates["6"] ?? fast
        let slow = estimates["6"] ?? estimates["12"] ?? medium

        return BitcoinFeeRates(
            fast: max(1, UInt64(fast.rounded(.up))),
            medium: max(1, UInt64(medium.rounded(.up))),
            slow: max(1, UInt64(slow.rounded(.up)))
        )
    }

    /// Broadcasts a signed Bitcoin transaction via Blockstream/Mempool API.
    /// Returns the transaction ID (txid) on success.
    func broadcastBitcoinTransaction(apiUrl: String, txHex: String) async throws -> String {
        let url = try httpsURL("\(apiUrl)/tx")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = txHex.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw RPCServiceError.decodingError("Broadcast failed: \(errorBody)")
        }

        guard let txid = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !txid.isEmpty else {
            throw RPCServiceError.invalidResponse
        }

        return txid
    }

    /// Returns true if a Bitcoin transaction is confirmed.
    func isBitcoinTransactionConfirmed(apiUrl: String, txid: String) async throws -> Bool {
        let url = try httpsURL("\(apiUrl)/tx/\(txid)/status")
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return false
        }

        struct TxStatus: Decodable {
            let confirmed: Bool
        }
        let parsed = try JSONDecoder().decode(TxStatus.self, from: data)
        return parsed.confirmed
    }

    // MARK: - Zcash-specific Methods (REST API via Blockchair)

    /// Fetches the ZEC balance for a transparent Zcash address (in zatoshi).
    /// Uses the Blockchair API for address info.
    func getZcashBalance(address: String) async throws -> Int {
        let url = try httpsURL("https://api.blockchair.com/zcash/dashboards/address/\(address)")

        let (data, response) = try await withRetry { [self] in try await session.data(from: url) }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw RPCServiceError.invalidResponse
        }

        struct BlockchairResponse: Decodable {
            struct Data: Decodable {
                struct AddressData: Decodable {
                    struct Address: Decodable {
                        let balance: Int
                    }
                    let address: Address
                }
            }
            let data: [String: Data.AddressData]
        }

        let result = try JSONDecoder().decode(BlockchairResponse.self, from: data)
        guard let addressData = result.data.values.first else {
            return 0
        }
        return addressData.address.balance
    }

    /// Fetches UTXOs for a transparent Zcash address.
    /// Uses the Blockchair API for UTXO data.
    func getZcashUtxos(address: String) async throws -> [ZecUtxoData] {
        let url = try httpsURL("https://api.blockchair.com/zcash/dashboards/address/\(address)?limit=100")

        let (data, response) = try await withRetry { [self] in try await session.data(from: url) }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw RPCServiceError.invalidResponse
        }

        struct BlockchairUtxoResponse: Decodable {
            struct Data: Decodable {
                struct AddressData: Decodable {
                    let utxo: [Utxo]
                }
                struct Utxo: Decodable {
                    let transaction_hash: String
                    let index: UInt32
                    let value: UInt64
                    let script_hex: String
                }
            }
            let data: [String: Data.AddressData]
        }

        let result = try JSONDecoder().decode(BlockchairUtxoResponse.self, from: data)
        guard let addressData = result.data.values.first else {
            return []
        }

        return addressData.utxo.map { utxo in
            let scriptBytes: Data
            if let decoded = Self.hexToData(utxo.script_hex) {
                scriptBytes = decoded
            } else {
                scriptBytes = Data()
            }
            return ZecUtxoData(
                txid: utxo.transaction_hash,
                vout: utxo.index,
                amountZatoshi: utxo.value,
                scriptPubkey: scriptBytes
            )
        }
    }

    /// Broadcasts a signed Zcash transaction via Blockchair push API.
    /// Returns the transaction hash on success.
    func broadcastZcashTransaction(txHex: String) async throws -> String {
        let url = try httpsURL("https://api.blockchair.com/zcash/push/transaction")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["data": txHex]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await withRetry { [self] in try await session.data(for: request) }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw RPCServiceError.decodingError("ZEC broadcast failed: \(errorBody)")
        }

        struct PushResponse: Decodable {
            struct Data: Decodable {
                let transaction_hash: String
            }
            let data: Data
        }

        let pushResult = try JSONDecoder().decode(PushResponse.self, from: data)
        return pushResult.data.transaction_hash
    }

    /// Returns true if a Zcash transaction is confirmed (has a block id on Blockchair).
    func isZcashTransactionConfirmed(txHash: String) async throws -> Bool {
        let url = try httpsURL("https://api.blockchair.com/zcash/dashboards/transaction/\(txHash)")
        let (data, response) = try await withRetry { [self] in try await session.data(from: url) }
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return false
        }

        struct TxResponse: Decodable {
            struct TxContainer: Decodable {
                struct TxCore: Decodable {
                    let block_id: Int?
                }
                let transaction: TxCore
            }
            let data: [String: TxContainer]
        }

        let parsed = try JSONDecoder().decode(TxResponse.self, from: data)
        guard let tx = parsed.data.values.first else { return false }
        return (tx.transaction.block_id ?? 0) > 0
    }

    /// Fetches latest Zcash tip height from Blockchair stats endpoint.
    func getZcashBestBlockHeight() async throws -> UInt32 {
        let url = try httpsURL("https://api.blockchair.com/zcash/stats")
        let (data, response) = try await withRetry { [self] in try await session.data(from: url) }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw RPCServiceError.invalidResponse
        }

        struct StatsResponse: Decodable {
            struct StatsData: Decodable {
                let best_block_height: UInt32?
                let blocks: UInt32?
            }
            let data: StatsData
        }

        let parsed = try JSONDecoder().decode(StatsResponse.self, from: data)
        return parsed.data.best_block_height ?? parsed.data.blocks ?? 0
    }

    /// Converts a hex string to Data.
    private static func hexToData(_ hex: String) -> Data? {
        let cleaned = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard cleaned.count % 2 == 0 else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }

    // Base58 is now provided by the shared Base58 enum in Extensions/Base58.swift

    /// Gets Bitcoin address info via Blockstream/Mempool REST API.
    func getBitcoinBalance(apiUrl: String, address: String) async throws -> Int {
        let url = try httpsURL("\(apiUrl)/address/\(address)")

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw RPCServiceError.invalidResponse
        }

        struct BitcoinAddressInfo: Decodable {
            struct ChainStats: Decodable {
                let funded_txo_sum: Int
                let spent_txo_sum: Int
            }
            let chain_stats: ChainStats
        }

        let info = try JSONDecoder().decode(BitcoinAddressInfo.self, from: data)
        return info.chain_stats.funded_txo_sum - info.chain_stats.spent_txo_sum
    }
}
