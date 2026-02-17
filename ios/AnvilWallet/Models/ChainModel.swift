import Foundation

struct ChainModel: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let iconName: String
    let rpcUrl: String
    let explorerUrl: String
    let isTestnet: Bool
    let chainType: ChainType

    enum ChainType: String, Codable, Hashable {
        case evm
        case solana
        case bitcoin
    }

    init(
        id: String,
        name: String,
        symbol: String,
        iconName: String,
        rpcUrl: String,
        explorerUrl: String,
        isTestnet: Bool = false,
        chainType: ChainType = .evm
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.iconName = iconName
        self.rpcUrl = rpcUrl
        self.explorerUrl = explorerUrl
        self.isTestnet = isTestnet
        self.chainType = chainType
    }

    func explorerTransactionUrl(hash: String) -> URL? {
        URL(string: "\(explorerUrl)/tx/\(hash)")
    }

    func explorerAddressUrl(address: String) -> URL? {
        URL(string: "\(explorerUrl)/address/\(address)")
    }

    // MARK: - Default Chains

    static let ethereum = ChainModel(
        id: "ethereum",
        name: "Ethereum",
        symbol: "ETH",
        iconName: "ethereum_icon",
        rpcUrl: "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY",
        explorerUrl: "https://etherscan.io",
        chainType: .evm
    )

    static let polygon = ChainModel(
        id: "polygon",
        name: "Polygon",
        symbol: "MATIC",
        iconName: "polygon_icon",
        rpcUrl: "https://polygon-rpc.com",
        explorerUrl: "https://polygonscan.com",
        chainType: .evm
    )

    static let arbitrum = ChainModel(
        id: "arbitrum",
        name: "Arbitrum",
        symbol: "ETH",
        iconName: "arbitrum_icon",
        rpcUrl: "https://arb1.arbitrum.io/rpc",
        explorerUrl: "https://arbiscan.io",
        chainType: .evm
    )

    static let base = ChainModel(
        id: "base",
        name: "Base",
        symbol: "ETH",
        iconName: "base_icon",
        rpcUrl: "https://mainnet.base.org",
        explorerUrl: "https://basescan.org",
        chainType: .evm
    )

    static let solana = ChainModel(
        id: "solana",
        name: "Solana",
        symbol: "SOL",
        iconName: "solana_icon",
        rpcUrl: "https://api.mainnet-beta.solana.com",
        explorerUrl: "https://solscan.io",
        chainType: .solana
    )

    static let bitcoin = ChainModel(
        id: "bitcoin",
        name: "Bitcoin",
        symbol: "BTC",
        iconName: "bitcoin_icon",
        rpcUrl: "https://blockstream.info/api",
        explorerUrl: "https://blockstream.info",
        chainType: .bitcoin
    )

    // Testnets
    static let sepolia = ChainModel(
        id: "sepolia",
        name: "Sepolia",
        symbol: "ETH",
        iconName: "ethereum_icon",
        rpcUrl: "https://rpc.sepolia.org",
        explorerUrl: "https://sepolia.etherscan.io",
        isTestnet: true,
        chainType: .evm
    )

    static let defaults: [ChainModel] = [
        .ethereum,
        .polygon,
        .arbitrum,
        .base,
        .solana,
        .bitcoin,
    ]

    static let allChains: [ChainModel] = [
        .ethereum,
        .polygon,
        .arbitrum,
        .base,
        .solana,
        .bitcoin,
        .sepolia,
    ]
}
