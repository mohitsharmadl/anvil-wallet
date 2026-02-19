import Foundation

/// Service for cross-chain token bridging via Socket (Bungee) API.
///
/// Flow: fetchRoutes -> user picks route -> buildBridgeTxParams returns params for signing.
/// Uses CertificatePinner for TLS hardening. API key loaded from Info.plist.
final class BridgeService: ObservableObject {

    static let shared = BridgeService()

    /// Supported bridge chains (EVM only — Socket supports these).
    static let supportedChains: [(name: String, chainId: Int)] = [
        ("Ethereum", 1),
        ("Polygon", 137),
        ("Arbitrum", 42161),
        ("Optimism", 10),
        ("Base", 8453),
        ("BSC", 56),
        ("Avalanche", 43114),
    ]

    @Published var routes: [BridgeRoute] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let session: URLSession
    private let apiKey: String

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(
            configuration: config,
            delegate: CertificatePinner(),
            delegateQueue: nil
        )
        self.apiKey = Bundle.main.object(forInfoDictionaryKey: "SocketApiKey") as? String ?? ""
    }

    // MARK: - Models

    struct BridgeRoute: Identifiable {
        let id = UUID()
        let bridgeName: String
        let estimatedOutputAmount: Double
        let estimatedOutputFormatted: String
        let estimatedGasUsd: Double
        let estimatedTimeMinutes: Int
        let outputSymbol: String
        /// Raw route JSON from Socket API, needed for the build-tx call.
        let routeJSON: [String: Any]
    }

    /// Transaction parameters returned by Socket's build-tx endpoint.
    struct BridgeTxParams {
        let to: String
        let data: Data
        let valueWeiHex: String
        let chainId: UInt64
    }

    // MARK: - Quote Fetching

    /// Fetches bridge routes from the Socket v2 quote API.
    func fetchRoutes(
        fromChainId: Int,
        toChainId: Int,
        fromTokenAddress: String,
        toTokenAddress: String,
        amount: String,
        userAddress: String,
        decimals: Int
    ) async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
            routes = []
        }

        let baseURL = "https://api.socket.tech/v2/quote"
        var components = URLComponents(string: baseURL)!
        components.queryItems = [
            URLQueryItem(name: "fromChainId", value: "\(fromChainId)"),
            URLQueryItem(name: "toChainId", value: "\(toChainId)"),
            URLQueryItem(name: "fromTokenAddress", value: fromTokenAddress),
            URLQueryItem(name: "toTokenAddress", value: toTokenAddress),
            URLQueryItem(name: "fromAmount", value: amount),
            URLQueryItem(name: "userAddress", value: userAddress),
            URLQueryItem(name: "uniqueRoutesPerBridge", value: "true"),
            URLQueryItem(name: "sort", value: "output"),
        ]

        guard let url = components.url else {
            await MainActor.run {
                isLoading = false
                errorMessage = "Invalid request parameters"
            }
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "API-KEY")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "Bridge API returned an error"
                }
                return
            }

            let parsed = try parseQuoteResponse(data: data, decimals: decimals)

            await MainActor.run {
                routes = parsed
                isLoading = false
                if parsed.isEmpty {
                    errorMessage = "No bridge routes found for this pair"
                }
            }
        } catch {
            await MainActor.run {
                isLoading = false
                errorMessage = "Failed to fetch routes: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Build Transaction

    /// Calls Socket's /v2/route/start to get the raw transaction params to sign.
    func buildBridgeTxParams(route: BridgeRoute) async throws -> BridgeTxParams {
        let startURL = URL(string: "https://api.socket.tech/v2/route/start")!
        var startRequest = URLRequest(url: startURL)
        startRequest.httpMethod = "POST"
        startRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        startRequest.setValue(apiKey, forHTTPHeaderField: "API-KEY")

        let body: [String: Any] = ["route": route.routeJSON]
        startRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: startRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw BridgeError.buildTxFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let txData = result["txData"] as? [String: Any],
              let to = txData["to"] as? String,
              let dataHex = txData["data"] as? String,
              let valueStr = txData["value"] as? String,
              let chainIdNum = txData["chainId"] as? Int else {
            throw BridgeError.invalidTxData
        }

        guard let calldata = Data(hexString: dataHex) else {
            throw BridgeError.invalidTxData
        }

        return BridgeTxParams(
            to: to,
            data: calldata,
            valueWeiHex: valueStr,
            chainId: UInt64(chainIdNum)
        )
    }

    enum BridgeError: LocalizedError {
        case buildTxFailed
        case invalidTxData

        var errorDescription: String? {
            switch self {
            case .buildTxFailed: return "Failed to build bridge transaction"
            case .invalidTxData: return "Bridge returned invalid transaction data"
            }
        }
    }

    // MARK: - Parsing

    func parseQuoteResponse(data: Data, decimals: Int) throws -> [BridgeRoute] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let routesArray = result["routes"] as? [[String: Any]] else {
            return []
        }

        let divisor = pow(10.0, Double(decimals))

        return routesArray.compactMap { routeDict -> BridgeRoute? in
            guard let usedBridges = routeDict["usedBridgeNames"] as? [String],
                  let toAmountStr = routeDict["toAmount"] as? String,
                  let toAmount = Double(toAmountStr),
                  let serviceTimeSeconds = routeDict["serviceTime"] as? Int,
                  let _ = routeDict["outputValueInUsd"] as? Double else {
                return nil
            }

            let bridgeName = usedBridges.joined(separator: " + ")
            let outputAmount = toAmount / divisor
            let gasUsd = (routeDict["totalGasFeesInUsd"] as? Double) ?? 0

            return BridgeRoute(
                bridgeName: bridgeName.isEmpty ? "Unknown" : bridgeName,
                estimatedOutputAmount: outputAmount,
                estimatedOutputFormatted: formatAmount(outputAmount),
                estimatedGasUsd: gasUsd,
                estimatedTimeMinutes: max(1, serviceTimeSeconds / 60),
                outputSymbol: "",
                routeJSON: routeDict
            )
        }
    }

    func formatAmount(_ amount: Double) -> String {
        if amount >= 1 {
            return String(format: "%.4f", amount)
        } else if amount > 0 {
            return String(format: "%.6f", amount)
        }
        return "0"
    }

    // MARK: - Native Token Addresses

    /// Returns the "native token" address convention used by Socket for a given chain.
    static func nativeTokenAddress(chainId: Int) -> String {
        "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    }
}
