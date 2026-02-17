import Foundation

struct TokenModel: Identifiable, Codable, Hashable {
    let id: UUID
    let symbol: String
    let name: String
    let chain: String
    let contractAddress: String?
    let decimals: Int
    var balance: Double
    var priceUsd: Double

    init(
        id: UUID = UUID(),
        symbol: String,
        name: String,
        chain: String,
        contractAddress: String? = nil,
        decimals: Int = 18,
        balance: Double = 0.0,
        priceUsd: Double = 0.0
    ) {
        self.id = id
        self.symbol = symbol
        self.name = name
        self.chain = chain
        self.contractAddress = contractAddress
        self.decimals = decimals
        self.balance = balance
        self.priceUsd = priceUsd
    }

    var balanceUsd: Double {
        balance * priceUsd
    }

    var isNativeToken: Bool {
        contractAddress == nil
    }

    var formattedBalance: String {
        String(format: "%.4f", balance)
    }

    var formattedBalanceUsd: String {
        String(format: "$%.2f", balanceUsd)
    }

    // MARK: - Default Tokens

    static let ethereumDefaults: [TokenModel] = [
        TokenModel(symbol: "ETH", name: "Ethereum", chain: "ethereum", decimals: 18),
        TokenModel(
            symbol: "USDC",
            name: "USD Coin",
            chain: "ethereum",
            contractAddress: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            decimals: 6
        ),
        TokenModel(
            symbol: "USDT",
            name: "Tether USD",
            chain: "ethereum",
            contractAddress: "0xdAC17F958D2ee523a2206206994597C13D831ec7",
            decimals: 6
        ),
    ]

    static let solanaDefaults: [TokenModel] = [
        TokenModel(symbol: "SOL", name: "Solana", chain: "solana", decimals: 9),
    ]

    static let bitcoinDefaults: [TokenModel] = [
        TokenModel(symbol: "BTC", name: "Bitcoin", chain: "bitcoin", decimals: 8),
    ]
}
