use serde::Serialize;

/// Definition of an EVM-compatible blockchain network.
#[derive(Debug, Clone, Serialize)]
pub struct EvmChain {
    pub chain_id: u64,
    pub name: &'static str,
    pub symbol: &'static str,
    pub decimals: u8,
    pub rpc_url: &'static str,
    pub explorer_url: &'static str,
    pub is_testnet: bool,
}

/// Ethereum Mainnet (chain ID 1).
pub const ETHEREUM: EvmChain = EvmChain {
    chain_id: 1,
    name: "Ethereum",
    symbol: "ETH",
    decimals: 18,
    rpc_url: "https://eth.llamarpc.com",
    explorer_url: "https://etherscan.io",
    is_testnet: false,
};

/// Polygon PoS (chain ID 137).
pub const POLYGON: EvmChain = EvmChain {
    chain_id: 137,
    name: "Polygon",
    symbol: "MATIC",
    decimals: 18,
    rpc_url: "https://polygon-rpc.com",
    explorer_url: "https://polygonscan.com",
    is_testnet: false,
};

/// Arbitrum One (chain ID 42161).
pub const ARBITRUM: EvmChain = EvmChain {
    chain_id: 42161,
    name: "Arbitrum One",
    symbol: "ETH",
    decimals: 18,
    rpc_url: "https://arb1.arbitrum.io/rpc",
    explorer_url: "https://arbiscan.io",
    is_testnet: false,
};

/// Base (chain ID 8453).
pub const BASE: EvmChain = EvmChain {
    chain_id: 8453,
    name: "Base",
    symbol: "ETH",
    decimals: 18,
    rpc_url: "https://mainnet.base.org",
    explorer_url: "https://basescan.org",
    is_testnet: false,
};

/// Optimism (chain ID 10).
pub const OPTIMISM: EvmChain = EvmChain {
    chain_id: 10,
    name: "Optimism",
    symbol: "ETH",
    decimals: 18,
    rpc_url: "https://mainnet.optimism.io",
    explorer_url: "https://optimistic.etherscan.io",
    is_testnet: false,
};

/// BNB Smart Chain (chain ID 56).
pub const BSC: EvmChain = EvmChain {
    chain_id: 56,
    name: "BNB Smart Chain",
    symbol: "BNB",
    decimals: 18,
    rpc_url: "https://bsc-dataseed.binance.org",
    explorer_url: "https://bscscan.com",
    is_testnet: false,
};

/// Avalanche C-Chain (chain ID 43114).
pub const AVALANCHE: EvmChain = EvmChain {
    chain_id: 43114,
    name: "Avalanche C-Chain",
    symbol: "AVAX",
    decimals: 18,
    rpc_url: "https://api.avax.network/ext/bc/C/rpc",
    explorer_url: "https://snowtrace.io",
    is_testnet: false,
};

/// Sepolia Testnet (chain ID 11155111).
pub const SEPOLIA: EvmChain = EvmChain {
    chain_id: 11155111,
    name: "Sepolia",
    symbol: "ETH",
    decimals: 18,
    rpc_url: "https://rpc.sepolia.org",
    explorer_url: "https://sepolia.etherscan.io",
    is_testnet: true,
};

/// Polygon Amoy Testnet (chain ID 80002).
pub const POLYGON_AMOY: EvmChain = EvmChain {
    chain_id: 80002,
    name: "Polygon Amoy",
    symbol: "MATIC",
    decimals: 18,
    rpc_url: "https://rpc-amoy.polygon.technology",
    explorer_url: "https://amoy.polygonscan.com",
    is_testnet: true,
};

/// All supported EVM chains.
const ALL_CHAINS: &[&EvmChain] = &[
    &ETHEREUM,
    &POLYGON,
    &ARBITRUM,
    &BASE,
    &OPTIMISM,
    &BSC,
    &AVALANCHE,
    &SEPOLIA,
    &POLYGON_AMOY,
];

/// Returns the chain definition for a given chain ID, or `None` if unsupported.
pub fn get_chain(chain_id: u64) -> Option<&'static EvmChain> {
    ALL_CHAINS
        .iter()
        .find(|c| c.chain_id == chain_id)
        .copied()
}

/// Returns all supported EVM chain definitions.
pub fn supported_chains() -> Vec<&'static EvmChain> {
    ALL_CHAINS.to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn get_ethereum() {
        let chain = get_chain(1).expect("Ethereum should be supported");
        assert_eq!(chain.name, "Ethereum");
        assert_eq!(chain.symbol, "ETH");
        assert_eq!(chain.decimals, 18);
        assert!(!chain.is_testnet);
    }

    #[test]
    fn get_polygon() {
        let chain = get_chain(137).expect("Polygon should be supported");
        assert_eq!(chain.name, "Polygon");
        assert_eq!(chain.symbol, "MATIC");
    }

    #[test]
    fn get_arbitrum() {
        let chain = get_chain(42161).expect("Arbitrum should be supported");
        assert_eq!(chain.name, "Arbitrum One");
    }

    #[test]
    fn get_base() {
        let chain = get_chain(8453).expect("Base should be supported");
        assert_eq!(chain.name, "Base");
    }

    #[test]
    fn get_optimism() {
        let chain = get_chain(10).expect("Optimism should be supported");
        assert_eq!(chain.name, "Optimism");
    }

    #[test]
    fn get_bsc() {
        let chain = get_chain(56).expect("BSC should be supported");
        assert_eq!(chain.name, "BNB Smart Chain");
        assert_eq!(chain.symbol, "BNB");
    }

    #[test]
    fn get_avalanche() {
        let chain = get_chain(43114).expect("Avalanche should be supported");
        assert_eq!(chain.name, "Avalanche C-Chain");
        assert_eq!(chain.symbol, "AVAX");
    }

    #[test]
    fn get_sepolia_testnet() {
        let chain = get_chain(11155111).expect("Sepolia should be supported");
        assert_eq!(chain.name, "Sepolia");
        assert!(chain.is_testnet);
    }

    #[test]
    fn get_polygon_amoy_testnet() {
        let chain = get_chain(80002).expect("Polygon Amoy should be supported");
        assert_eq!(chain.name, "Polygon Amoy");
        assert!(chain.is_testnet);
    }

    #[test]
    fn unsupported_chain_returns_none() {
        assert!(get_chain(999999).is_none());
    }

    #[test]
    fn supported_chains_includes_all() {
        let chains = supported_chains();
        assert_eq!(chains.len(), 9);
    }

    #[test]
    fn supported_chains_contains_testnets() {
        let chains = supported_chains();
        let testnets: Vec<_> = chains.iter().filter(|c| c.is_testnet).collect();
        assert_eq!(testnets.len(), 2);
    }

    #[test]
    fn all_chains_have_18_decimals() {
        for chain in supported_chains() {
            assert_eq!(chain.decimals, 18, "{} should have 18 decimals", chain.name);
        }
    }

    #[test]
    fn all_chains_have_rpc_url() {
        for chain in supported_chains() {
            assert!(
                chain.rpc_url.starts_with("https://"),
                "{} rpc_url should start with https://",
                chain.name
            );
        }
    }

    #[test]
    fn all_chains_have_explorer_url() {
        for chain in supported_chains() {
            assert!(
                chain.explorer_url.starts_with("https://"),
                "{} explorer_url should start with https://",
                chain.name
            );
        }
    }
}
