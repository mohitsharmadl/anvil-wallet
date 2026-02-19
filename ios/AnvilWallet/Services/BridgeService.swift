import Foundation

/// Service for cross-chain token bridging via Socket (Bungee) API.
///
/// Fetches bridge routes and quotes for transferring tokens between supported
/// EVM chains. The actual transaction is built by Socket's API and signed
/// locally using the existing EVM signing infrastructure.
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

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
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
    }

    struct BridgeQuote {
        let fromChainId: Int
        let toChainId: Int
        let fromToken: String
        let toToken: String
        let amount: String
        let routes: [BridgeRoute]
    }

    // MARK: - Quote Fetching

    /// Fetches bridge routes for a given token transfer across chains.
    ///
    /// Uses a simplified quote model. In production this would call
    /// Socket/Bungee, Li.Fi, or similar bridge aggregator APIs.
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

        // Build Socket API quote URL
        // Socket API: https://docs.socket.tech/socket-api/v2
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
        // Socket API key — free tier public key for basic access
        request.setValue("72a5b4b0-e727-48be-8aa1-5da9d62fe635", forHTTPHeaderField: "API-KEY")

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

    // MARK: - Parsing

    private func parseQuoteResponse(data: Data, decimals: Int) throws -> [BridgeRoute] {
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
                outputSymbol: ""
            )
        }
    }

    private func formatAmount(_ amount: Double) -> String {
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
        // Socket uses 0xEEE...EEE for native tokens on all chains
        "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    }
}
