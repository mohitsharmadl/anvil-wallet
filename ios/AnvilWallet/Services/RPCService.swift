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

        // TODO: Phase 3 - Configure TrustKit certificate pinning delegate
        // let pinningDelegate = TrustKitPinningDelegate()
        // session = URLSession(configuration: config, delegate: pinningDelegate, delegateQueue: nil)
        session = URLSession(configuration: config)
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

    // MARK: - Bitcoin-specific Methods (REST API)

    /// Gets Bitcoin address info via Blockstream/Mempool REST API.
    func getBitcoinBalance(apiUrl: String, address: String) async throws -> Int {
        guard let url = URL(string: "\(apiUrl)/address/\(address)") else {
            throw RPCServiceError.invalidURL
        }

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
