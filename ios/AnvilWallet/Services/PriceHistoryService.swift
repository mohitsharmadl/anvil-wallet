import Foundation

/// A single price point in a price history chart.
struct PricePoint: Identifiable {
    let id = UUID()
    let date: Date
    let price: Double
}

/// Time range options for the price chart.
enum PriceTimeRange: String, CaseIterable, Identifiable {
    case day = "1D"
    case week = "1W"
    case month = "1M"
    case threeMonths = "3M"
    case year = "1Y"
    case all = "ALL"

    var id: String { rawValue }

    /// Number of days to request from CoinGecko.
    var days: String {
        switch self {
        case .day:         return "1"
        case .week:        return "7"
        case .month:       return "30"
        case .threeMonths: return "90"
        case .year:        return "365"
        case .all:         return "max"
        }
    }

    /// Cache time-to-live in seconds. Short ranges refresh faster.
    var cacheTTL: TimeInterval {
        switch self {
        case .day:         return 5 * 60      // 5 minutes
        case .week:        return 15 * 60     // 15 minutes
        case .month:       return 30 * 60     // 30 minutes
        case .threeMonths: return 30 * 60     // 30 minutes
        case .year:        return 60 * 60     // 1 hour
        case .all:         return 60 * 60     // 1 hour
        }
    }
}

/// Fetches historical price data from CoinGecko's free API.
///
/// Features:
///   - Maps token symbols and chain IDs to CoinGecko coin IDs
///   - Per-range in-memory cache with configurable TTL
///   - Rate-limit aware: CoinGecko free tier allows 10-30 calls/min
final class PriceHistoryService {

    static let shared = PriceHistoryService()

    private let baseURL = "https://api.coingecko.com/api/v3"
    private let session: URLSession

    // MARK: - Cache

    private struct CacheKey: Hashable {
        let geckoId: String
        let range: PriceTimeRange
    }

    private struct CachedHistory {
        let points: [PricePoint]
        let timestamp: Date
        let ttl: TimeInterval

        var isExpired: Bool {
            Date().timeIntervalSince(timestamp) > ttl
        }
    }

    private var cache: [CacheKey: CachedHistory] = [:]

    // MARK: - CoinGecko ID Mapping

    /// Maps lowercase token symbol to CoinGecko coin ID for native/major tokens.
    private let symbolToGeckoId: [String: String] = [
        "btc":   "bitcoin",
        "eth":   "ethereum",
        "sol":   "solana",
        "matic": "matic-network",
        "bnb":   "binancecoin",
        "avax":  "avalanche-2",
        "usdc":  "usd-coin",
        "usdt":  "tether",
        "dai":   "dai",
        "link":  "chainlink",
        "uni":   "uniswap",
        "aave":  "aave",
        "arb":   "arbitrum",
        "weth":  "weth",
        "wbtc":  "wrapped-bitcoin",
    ]

    /// Maps the app's chain ID string to CoinGecko's platform ID
    /// (used for contract-address lookups of ERC-20 tokens).
    private let chainToPlatform: [String: String] = [
        "ethereum":  "ethereum",
        "polygon":   "polygon-pos",
        "arbitrum":  "arbitrum-one",
        "base":      "base",
        "optimism":  "optimistic-ethereum",
        "bsc":       "binance-smart-chain",
        "avalanche": "avalanche",
    ]

    // MARK: - Init

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        session = URLSession(
            configuration: config,
            delegate: CertificatePinner(),
            delegateQueue: nil
        )
    }

    // MARK: - Public API

    /// Returns true if we can resolve a CoinGecko ID for this token.
    func hasPriceHistory(symbol: String, contractAddress: String?, chain: String) -> Bool {
        if symbolToGeckoId[symbol.lowercased()] != nil {
            return true
        }
        if contractAddress != nil, chainToPlatform[chain] != nil {
            return true
        }
        return false
    }

    /// Fetches price history for a token over the given time range.
    ///
    /// - Parameters:
    ///   - symbol: Token symbol (e.g., "ETH", "BTC")
    ///   - contractAddress: ERC-20 contract address, or nil for native tokens
    ///   - chain: The app's chain ID (e.g., "ethereum", "polygon")
    ///   - range: Desired time range
    /// - Returns: Array of PricePoint sorted by date ascending, or empty on failure.
    func fetchHistory(
        symbol: String,
        contractAddress: String?,
        chain: String,
        range: PriceTimeRange
    ) async -> [PricePoint] {
        // Resolve CoinGecko ID
        guard let geckoId = resolveGeckoId(symbol: symbol, contractAddress: contractAddress, chain: chain) else {
            return []
        }

        let key = CacheKey(geckoId: geckoId, range: range)

        // Return cached data if still fresh
        if let cached = cache[key], !cached.isExpired {
            return cached.points
        }

        // Fetch from CoinGecko market_chart endpoint
        let urlString: String
        if let contract = contractAddress, let platform = chainToPlatform[chain] {
            // ERC-20 token by contract address
            urlString = "\(baseURL)/coins/\(platform)/contract/\(contract.lowercased())/market_chart?vs_currency=usd&days=\(range.days)"
        } else {
            // Native token by CoinGecko ID
            urlString = "\(baseURL)/coins/\(geckoId)/market_chart?vs_currency=usd&days=\(range.days)"
        }

        guard let url = URL(string: urlString) else { return [] }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                // On rate-limit or error, return stale cache if available
                return cache[key]?.points ?? []
            }

            let decoded = try JSONDecoder().decode(MarketChartResponse.self, from: data)
            let points = decoded.prices.map { pair -> PricePoint in
                let timestamp = pair[0] / 1000.0 // CoinGecko returns milliseconds
                let price = pair[1]
                return PricePoint(date: Date(timeIntervalSince1970: timestamp), price: price)
            }

            // Update cache
            cache[key] = CachedHistory(points: points, timestamp: Date(), ttl: range.cacheTTL)

            return points
        } catch {
            // Return stale cache on network errors
            return cache[key]?.points ?? []
        }
    }

    /// Clears the entire price history cache.
    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Private

    private func resolveGeckoId(symbol: String, contractAddress: String?, chain: String) -> String? {
        // Try symbol mapping first (covers native tokens and major ERC-20s)
        if let id = symbolToGeckoId[symbol.lowercased()] {
            return id
        }

        // For unknown ERC-20 tokens, we use the contract address endpoint directly
        // (no CoinGecko ID needed — the endpoint uses platform + address)
        if contractAddress != nil, chainToPlatform[chain] != nil {
            return "contract-lookup" // placeholder; the URL builder uses the contract path
        }

        return nil
    }

    // MARK: - Response Model

    private struct MarketChartResponse: Decodable {
        let prices: [[Double]]
    }
}
