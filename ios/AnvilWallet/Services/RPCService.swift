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
///   - Certificate pinning via TrustKit (placeholder for Phase 3)
///   - All connections over HTTPS
///   - Request timeout of 30 seconds
final class RPCService {

    static let shared = RPCService()

    private let session: URLSession
    private let requestTimeout: TimeInterval = 30

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
        guard let endpoint = URL(string: url) else {
            throw RPCServiceError.invalidURL
        }

        // Reject non-HTTPS endpoints — all RPC calls must be encrypted
        guard endpoint.scheme == "https" else {
            throw RPCServiceError.invalidURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let rpcRequest = RPCRequest(method: method, params: params, id: 1)
        request.httpBody = try JSONEncoder().encode(rpcRequest)

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
        /// Returns nil on invalid input or checksum failure.
        static func decode(_ addr: String) -> Data? {
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

    /// Fetches recommended fee rates from Blockstream/Mempool API.
    /// Returns the recommended fee rate in sat/vbyte for medium-priority confirmation.
    func getBitcoinFeeRate(apiUrl: String) async throws -> UInt64 {
        let url = try httpsURL("\(apiUrl)/fee-estimates")

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw RPCServiceError.invalidResponse
        }

        // Response is { "1": 50.5, "3": 30.2, "6": 15.1, ... } (sat/vbyte per block target)
        let estimates = try JSONDecoder().decode([String: Double].self, from: data)

        // Use 6-block target (~1 hour) as medium priority, fallback to 3-block or 1 sat/vbyte
        let feeRate = estimates["6"] ?? estimates["3"] ?? 1.0
        return UInt64(feeRate.rounded(.up))
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

    // MARK: - Base58 Decoder (for Solana blockhash)

    private enum Base58 {
        private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

        static func decode(_ string: String) -> Data? {
            var result: [UInt8] = [0]
            for char in string {
                guard let charIndex = alphabet.firstIndex(of: char) else { return nil }
                var carry = Int(charIndex - alphabet.startIndex)
                for j in stride(from: result.count - 1, through: 0, by: -1) {
                    carry += 58 * Int(result[j])
                    result[j] = UInt8(carry % 256)
                    carry /= 256
                }
                while carry > 0 {
                    result.insert(UInt8(carry % 256), at: 0)
                    carry /= 256
                }
            }
            // Add leading zeros
            let leadingZeros = string.prefix(while: { $0 == "1" }).count
            let zeros = [UInt8](repeating: 0, count: leadingZeros)
            // Remove leading zero from bignum result
            let stripped = result.drop(while: { $0 == 0 })
            return Data(zeros + stripped)
        }
    }

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
