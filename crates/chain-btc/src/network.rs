use bitcoin::Network;

/// Default RPC endpoint for Bitcoin mainnet.
pub const MAINNET_RPC: &str = "https://blockstream.info/api";

/// Default RPC endpoint for Bitcoin testnet.
pub const TESTNET_RPC: &str = "https://blockstream.info/testnet/api";

/// Default RPC endpoint for Bitcoin signet.
pub const SIGNET_RPC: &str = "https://mempool.space/signet/api";

/// Supported Bitcoin networks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BtcNetwork {
    Mainnet,
    Testnet,
    Signet,
}

impl BtcNetwork {
    /// Convert to the `bitcoin` crate's `Network` type.
    pub fn to_bitcoin_network(self) -> Network {
        match self {
            BtcNetwork::Mainnet => Network::Bitcoin,
            BtcNetwork::Testnet => Network::Testnet,
            BtcNetwork::Signet => Network::Signet,
        }
    }

    /// Return the default RPC endpoint for this network.
    pub fn default_rpc_url(self) -> &'static str {
        match self {
            BtcNetwork::Mainnet => MAINNET_RPC,
            BtcNetwork::Testnet => TESTNET_RPC,
            BtcNetwork::Signet => SIGNET_RPC,
        }
    }
}

impl std::fmt::Display for BtcNetwork {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BtcNetwork::Mainnet => write!(f, "mainnet"),
            BtcNetwork::Testnet => write!(f, "testnet"),
            BtcNetwork::Signet => write!(f, "signet"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mainnet_converts_to_bitcoin_network() {
        assert_eq!(BtcNetwork::Mainnet.to_bitcoin_network(), Network::Bitcoin);
    }

    #[test]
    fn testnet_converts_to_bitcoin_network() {
        assert_eq!(BtcNetwork::Testnet.to_bitcoin_network(), Network::Testnet);
    }

    #[test]
    fn signet_converts_to_bitcoin_network() {
        assert_eq!(BtcNetwork::Signet.to_bitcoin_network(), Network::Signet);
    }

    #[test]
    fn rpc_urls_are_nonempty() {
        assert!(!BtcNetwork::Mainnet.default_rpc_url().is_empty());
        assert!(!BtcNetwork::Testnet.default_rpc_url().is_empty());
        assert!(!BtcNetwork::Signet.default_rpc_url().is_empty());
    }

    #[test]
    fn display_names() {
        assert_eq!(BtcNetwork::Mainnet.to_string(), "mainnet");
        assert_eq!(BtcNetwork::Testnet.to_string(), "testnet");
        assert_eq!(BtcNetwork::Signet.to_string(), "signet");
    }

    #[test]
    fn clone_and_copy() {
        let net = BtcNetwork::Mainnet;
        let net2 = net;
        assert_eq!(net, net2);
    }
}
