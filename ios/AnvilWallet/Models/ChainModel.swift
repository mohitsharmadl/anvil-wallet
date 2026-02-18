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
        rpcUrl: "https://rpc.ankr.com/eth",
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

    static let optimism = ChainModel(
        id: "optimism",
        name: "Optimism",
        symbol: "ETH",
        iconName: "optimism_icon",
        rpcUrl: "https://mainnet.optimism.io",
        explorerUrl: "https://optimistic.etherscan.io",
        chainType: .evm
    )

    static let bsc = ChainModel(
        id: "bsc",
        name: "BNB Smart Chain",
        symbol: "BNB",
        iconName: "bsc_icon",
        rpcUrl: "https://bsc-dataseed.binance.org",
        explorerUrl: "https://bscscan.com",
        chainType: .evm
    )

    static let avalanche = ChainModel(
        id: "avalanche",
        name: "Avalanche C-Chain",
        symbol: "AVAX",
        iconName: "avalanche_icon",
        rpcUrl: "https://api.avax.network/ext/bc/C/rpc",
        explorerUrl: "https://snowtrace.io",
        chainType: .evm
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

    static let bitcoinTestnet = ChainModel(
        id: "bitcoin_testnet",
        name: "Bitcoin Testnet",
        symbol: "tBTC",
        iconName: "bitcoin_icon",
        rpcUrl: "https://blockstream.info/testnet/api",
        explorerUrl: "https://blockstream.info/testnet",
        isTestnet: true,
        chainType: .bitcoin
    )

    static let solanaDevnet = ChainModel(
        id: "solana_devnet",
        name: "Solana Devnet",
        symbol: "SOL",
        iconName: "solana_icon",
        rpcUrl: "https://api.devnet.solana.com",
        explorerUrl: "https://solscan.io/?cluster=devnet",
        isTestnet: true,
        chainType: .solana
    )

    static let polygonAmoy = ChainModel(
        id: "polygon_amoy",
        name: "Polygon Amoy",
        symbol: "MATIC",
        iconName: "polygon_icon",
        rpcUrl: "https://rpc-amoy.polygon.technology",
        explorerUrl: "https://amoy.polygonscan.com",
        isTestnet: true,
        chainType: .evm
    )

    static let defaults: [ChainModel] = [
        .ethereum,
        .polygon,
        .arbitrum,
        .base,
        .optimism,
        .bsc,
        .avalanche,
        .solana,
        .bitcoin,
    ]

    static let allChains: [ChainModel] = [
        .ethereum,
        .polygon,
        .arbitrum,
        .base,
        .optimism,
        .bsc,
        .avalanche,
        .solana,
        .bitcoin,
        .sepolia,
        .bitcoinTestnet,
        .solanaDevnet,
        .polygonAmoy,
    ]

    /// EIP-155 chain ID for EVM chains. Returns nil for non-EVM chains or unknown chains.
    var evmChainId: UInt64? {
        switch id {
        case "ethereum": return 1
        case "polygon": return 137
        case "arbitrum": return 42161
        case "base": return 8453
        case "optimism": return 10
        case "bsc": return 56
        case "avalanche": return 43114
        case "sepolia": return 11155111
        case "polygon_amoy": return 80002
        default: return nil
        }
    }
}
