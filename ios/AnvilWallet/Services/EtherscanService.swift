import Foundation

/// Shared Etherscan API client with rate limiting (5 calls/sec).
/// Uses the existing CertificatePinner — api.etherscan.io is already pinned.
actor EtherscanService {

    static let shared = EtherscanService()

    private let session: URLSession
    private let baseUrl = "https://api.etherscan.io/api"
    private let apiKey: String

    // Rate limiter: max 5 calls per second
    private var callTimestamps: [Date] = []
    private let maxCallsPerSecond = 5

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        session = URLSession(
            configuration: config,
            delegate: CertificatePinner(),
            delegateQueue: nil
        )

        apiKey = Bundle.main.object(forInfoDictionaryKey: "EtherscanApiKey") as? String ?? ""
    }

    // MARK: - Rate Limiter

    private func waitForRateLimit() async {
        let now = Date()
        callTimestamps = callTimestamps.filter { now.timeIntervalSince($0) < 1.0 }

        if callTimestamps.count >= maxCallsPerSecond {
            let oldest = callTimestamps.first!
            let waitTime = 1.0 - now.timeIntervalSince(oldest)
            if waitTime > 0 {
                try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            }
            callTimestamps = callTimestamps.filter { Date().timeIntervalSince($0) < 1.0 }
        }
        callTimestamps.append(Date())
    }

    // MARK: - Generic Request

    private func request(params: [String: String]) async throws -> Data {
        await waitForRateLimit()

        var components = URLComponents(string: baseUrl)!
        var queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        queryItems.append(URLQueryItem(name: "apikey", value: apiKey))
        components.queryItems = queryItems

        guard let url = components.url else {
            throw EtherscanError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw EtherscanError.httpError
        }

        return data
    }

    // MARK: - Token Transfers

    struct TokenTransfer: Decodable {
        let contractAddress: String
        let tokenName: String
        let tokenSymbol: String
        let tokenDecimal: String
    }

    /// Fetches ERC-20 token transfer events for an address.
    /// Returns unique token contracts that have interacted with the address.
    func fetchTokenTransfers(address: String) async throws -> [TokenTransfer] {
        let data = try await request(params: [
            "module": "account",
            "action": "tokentx",
            "address": address,
            "startblock": "0",
            "endblock": "99999999",
            "sort": "desc",
            "page": "1",
            "offset": "100",
        ])

        struct Response: Decodable {
            let status: String
            let result: [TokenTransfer]?
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.status == "1", let transfers = response.result else {
            return []
        }

        // Deduplicate by contract address
        var seen = Set<String>()
        return transfers.filter { seen.insert($0.contractAddress.lowercased()).inserted }
    }

    // MARK: - Approval Event Logs

    struct ApprovalLog: Decodable {
        let address: String      // token contract
        let topics: [String]     // [sig, owner, spender]
        let data: String         // allowance amount
        let blockNumber: String
        let transactionHash: String
    }

    /// Fetches Approval event logs where the given address is the token owner.
    /// topic0 = keccak256("Approval(address,address,uint256)")
    /// topic1 = owner address (left-padded to 32 bytes)
    func fetchApprovalLogs(owner: String) async throws -> [ApprovalLog] {
        let cleanOwner = owner.hasPrefix("0x") ? String(owner.dropFirst(2)) : owner
        let paddedOwner = "0x" + String(repeating: "0", count: 24) + cleanOwner.lowercased()

        // Approval(address,address,uint256) event signature
        let approvalTopic = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925"

        let data = try await request(params: [
            "module": "logs",
            "action": "getLogs",
            "fromBlock": "0",
            "toBlock": "latest",
            "topic0": approvalTopic,
            "topic1": paddedOwner,
            "topic0_1_opr": "and",
            "page": "1",
            "offset": "200",
        ])

        struct Response: Decodable {
            let status: String
            let result: [ApprovalLog]?
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.status == "1", let logs = response.result else {
            return []
        }

        return logs
    }

    // MARK: - Errors

    enum EtherscanError: LocalizedError {
        case invalidURL
        case httpError
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid Etherscan URL."
            case .httpError: return "Etherscan API request failed."
            case .apiError(let msg): return "Etherscan: \(msg)"
            }
        }
    }
}
