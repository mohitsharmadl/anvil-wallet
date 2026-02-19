import Foundation

/// Service for fetching staking APY rates and building staking transactions.
///
/// Supports:
///   - ETH staking via Lido (stETH) — fetches real APY from Lido API
///   - SOL native staking — fetches epoch info for estimated APY
final class StakingService: ObservableObject {

    static let shared = StakingService()

    @Published var ethApy: Double?
    @Published var solApy: Double?
    @Published var isLoading = false

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(
            configuration: config,
            delegate: CertificatePinner(),
            delegateQueue: nil
        )
    }

    // MARK: - Models

    struct StakingOption: Identifiable {
        let id: String
        let chain: String
        let protocol_: String
        let tokenSymbol: String
        let stakedTokenSymbol: String
        let apy: Double
        let minAmount: Double
        let description: String
    }

    var availableOptions: [StakingOption] {
        var options: [StakingOption] = []

        if let ethApy {
            options.append(StakingOption(
                id: "lido-eth",
                chain: "ethereum",
                protocol_: "Lido",
                tokenSymbol: "ETH",
                stakedTokenSymbol: "stETH",
                apy: ethApy,
                minAmount: 0.001,
                description: "Stake ETH via Lido and receive stETH. No minimum, liquid staking."
            ))
        }

        if let solApy {
            options.append(StakingOption(
                id: "native-sol",
                chain: "solana",
                protocol_: "Native",
                tokenSymbol: "SOL",
                stakedTokenSymbol: "Staked SOL",
                apy: solApy,
                minAmount: 0.01,
                description: "Native Solana staking via delegation. Unstaking takes ~2-3 days."
            ))
        }

        return options
    }

    // MARK: - APY Fetching

    /// Fetches current staking APY rates for all supported protocols.
    func fetchAPYs() async {
        await MainActor.run { isLoading = true }

        async let ethResult = fetchLidoAPY()
        async let solResult = fetchSolanaAPY()

        let (eth, sol) = await (ethResult, solResult)

        await MainActor.run {
            ethApy = eth
            solApy = sol
            isLoading = false
        }
    }

    /// Fetches Lido's current stETH APR from their public API.
    private func fetchLidoAPY() async -> Double? {
        guard let url = URL(string: "https://eth-api.lido.fi/v1/protocol/steth/apr/sma") else {
            return nil
        }

        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            // Response shape: { "data": { "smaApr": "3.5" } }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let aprString = dataObj["smaApr"] as? String,
               let apr = Double(aprString) {
                return apr
            }
        } catch {
            // Fallback to a reasonable default
        }

        return nil
    }

    /// Estimates Solana staking APY from epoch schedule.
    /// Uses a heuristic based on recent SOL inflation schedule (~6-7% first year, declining).
    private func fetchSolanaAPY() async -> Double? {
        // Solana staking APY is approximately inflation rate * (1 - validator commission).
        // Current inflation ~5.5%, typical commission 5-10%, so APY ~5-5.2%.
        // In production this would query getInflationRate RPC.
        guard let url = URL(string: "https://api.mainnet-beta.solana.com") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = """
        {"jsonrpc":"2.0","id":1,"method":"getInflationRate"}
        """.data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let validator = result["validator"] as? Double {
                // validator field is the effective staking yield as a decimal (e.g. 0.052)
                return validator * 100
            }
        } catch {
            // Fallback
        }

        return nil
    }

    // MARK: - Lido Staking

    /// Builds the transaction data for staking ETH via Lido.
    /// Lido's stETH contract accepts plain ETH transfers to its submit() function.
    static let lidoContractAddress = "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84"

    /// The submit() function selector for Lido stETH contract.
    /// submit(address _referral) -> 0xa1903eab
    static let lidoSubmitSelector = "a1903eab"
}
