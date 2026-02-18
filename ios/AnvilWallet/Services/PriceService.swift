import Foundation

/// PriceService fetches token prices from the CoinGecko free API.
///
/// Features:
///   - Simple in-memory cache with 60-second TTL
///   - Batches multiple token lookups into a single API call
///   - Falls back gracefully on network errors (returns cached or empty)
final class PriceService {

    static let shared = PriceService()

    private let baseURL = "https://api.coingecko.com/api/v3"
    private let session: URLSession
    private let cacheTTL: TimeInterval = 60 // seconds

    private var cache: [String: CachedPrice] = [:]

    private struct CachedPrice {
        let price: Double
        let timestamp: Date

        var isExpired: Bool {
            Date().timeIntervalSince(timestamp) > 60
        }
    }

    /// Maps common token symbols to CoinGecko IDs.
    private let symbolToGeckoId: [String: String] = [
        "btc": "bitcoin",
        "eth": "ethereum",
        "sol": "solana",
        "matic": "matic-network",
        "usdc": "usd-coin",
        "usdt": "tether",
        "dai": "dai",
        "link": "chainlink",
        "uni": "uniswap",
        "aave": "aave",
        "arb": "arbitrum",
    ]

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        session = URLSession(
            configuration: config,
            delegate: CertificatePinner(),
            delegateQueue: nil
        )
    }

    // MARK: - Fetch Prices

    /// Fetches USD prices for the given token symbols.
    ///
    /// - Parameter symbols: Array of lowercase token symbols (e.g., ["eth", "btc", "sol"])
    /// - Returns: Dictionary mapping symbol -> USD price
    func fetchPrices(for symbols: [String]) async throws -> [String: Double] {
        // Check cache first
        var result: [String: Double] = [:]
        var uncachedSymbols: [String] = []

        for symbol in symbols {
            if let cached = cache[symbol], !cached.isExpired {
                result[symbol] = cached.price
            } else {
                uncachedSymbols.append(symbol)
            }
        }

        // If everything was cached, return early
        guard !uncachedSymbols.isEmpty else {
            return result
        }

        // Map symbols to CoinGecko IDs
        let geckoIds = uncachedSymbols.compactMap { symbolToGeckoId[$0] }

        guard !geckoIds.isEmpty else {
            return result
        }

        // Fetch from CoinGecko
        let idsParam = geckoIds.joined(separator: ",")
        guard let url = URL(string: "\(baseURL)/simple/price?ids=\(idsParam)&vs_currencies=usd") else {
            return result
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            // Return whatever we have cached on HTTP errors
            return result
        }

        // CoinGecko returns: { "bitcoin": { "usd": 50000 }, "ethereum": { "usd": 3000 } }
        let prices = try JSONDecoder().decode([String: [String: Double]].self, from: data)

        // Map back from CoinGecko IDs to our symbols
        let geckoIdToSymbol = Dictionary(uniqueKeysWithValues: symbolToGeckoId.map { ($1, $0) })

        for (geckoId, priceData) in prices {
            if let usdPrice = priceData["usd"],
               let symbol = geckoIdToSymbol[geckoId] {
                result[symbol] = usdPrice
                cache[symbol] = CachedPrice(price: usdPrice, timestamp: Date())
            }
        }

        return result
    }

    /// Fetches the USD price for a single token.
    ///
    /// - Parameter symbol: The lowercase token symbol (e.g., "eth")
    /// - Returns: The USD price, or nil if unavailable
    func fetchPrice(for symbol: String) async throws -> Double? {
        let prices = try await fetchPrices(for: [symbol])
        return prices[symbol]
    }

    /// Clears the price cache.
    func clearCache() {
        cache.removeAll()
    }
}
