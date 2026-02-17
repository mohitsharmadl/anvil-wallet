use crate::error::WalletError;
use crate::hd_derivation;
use crate::types::{Chain, DerivedAddress};

/// Derive an address for a given chain from seed bytes
pub fn derive_address(
    seed: &[u8],
    chain: Chain,
    account: u32,
    index: u32,
) -> Result<DerivedAddress, WalletError> {
    match chain {
        Chain::Bitcoin | Chain::BitcoinTestnet => derive_btc_address(seed, chain, account, index),

        Chain::Ethereum
        | Chain::Polygon
        | Chain::Arbitrum
        | Chain::Base
        | Chain::Optimism
        | Chain::Bsc
        | Chain::Avalanche
        | Chain::Sepolia
        | Chain::PolygonAmoy => derive_eth_address(seed, chain, account, index),

        Chain::Solana | Chain::SolanaDevnet => derive_sol_address(seed, chain, account),
    }
}

/// Derive addresses for all supported chains from a single seed
pub fn derive_all_addresses(
    seed: &[u8],
    account: u32,
) -> Result<Vec<DerivedAddress>, WalletError> {
    let chains = vec![
        Chain::Bitcoin,
        Chain::Ethereum,
        Chain::Solana,
    ];

    let mut addresses = Vec::new();
    for chain in chains {
        addresses.push(derive_address(seed, chain, account, 0)?);
    }
    Ok(addresses)
}

fn derive_btc_address(
    seed: &[u8],
    chain: Chain,
    account: u32,
    index: u32,
) -> Result<DerivedAddress, WalletError> {
    let key = hd_derivation::derive_secp256k1_key(seed, chain, account, index)?;

    let network = match chain {
        Chain::BitcoinTestnet => chain_btc::network::BtcNetwork::Testnet,
        _ => chain_btc::network::BtcNetwork::Mainnet,
    };

    let address =
        chain_btc::address::pubkey_to_p2wpkh_address(&key.public_key_compressed, network)?;

    Ok(DerivedAddress {
        chain,
        address,
        derivation_path: key.derivation_path.clone(),
    })
}

fn derive_eth_address(
    seed: &[u8],
    chain: Chain,
    account: u32,
    index: u32,
) -> Result<DerivedAddress, WalletError> {
    let key = hd_derivation::derive_secp256k1_key(seed, chain, account, index)?;

    let address =
        chain_eth::address::pubkey_bytes_to_eth_address(&key.public_key_compressed)?;

    Ok(DerivedAddress {
        chain,
        address,
        derivation_path: key.derivation_path.clone(),
    })
}

fn derive_sol_address(
    seed: &[u8],
    chain: Chain,
    account: u32,
) -> Result<DerivedAddress, WalletError> {
    let key = hd_derivation::derive_ed25519_key(seed, chain, account)?;

    let address = chain_sol::address::keypair_to_address(&key.public_key);

    Ok(DerivedAddress {
        chain,
        address,
        derivation_path: key.derivation_path.clone(),
    })
}

/// Validate an address for a given chain
pub fn validate_address(address: &str, chain: Chain) -> Result<bool, WalletError> {
    match chain {
        Chain::Bitcoin => {
            chain_btc::address::validate_address(address, chain_btc::network::BtcNetwork::Mainnet)
                .map_err(|e| WalletError::InvalidAddress(e.to_string()))
        }
        Chain::BitcoinTestnet => {
            chain_btc::address::validate_address(address, chain_btc::network::BtcNetwork::Testnet)
                .map_err(|e| WalletError::InvalidAddress(e.to_string()))
        }
        Chain::Ethereum
        | Chain::Polygon
        | Chain::Arbitrum
        | Chain::Base
        | Chain::Optimism
        | Chain::Bsc
        | Chain::Avalanche
        | Chain::Sepolia
        | Chain::PolygonAmoy => chain_eth::address::validate_address(address)
            .map_err(|e| WalletError::InvalidAddress(e.to_string())),
        Chain::Solana | Chain::SolanaDevnet => chain_sol::address::validate_address(address)
            .map_err(|e| WalletError::InvalidAddress(e.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mnemonic::mnemonic_to_seed;

    const TEST_MNEMONIC: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    fn test_seed() -> Vec<u8> {
        mnemonic_to_seed(TEST_MNEMONIC, "").unwrap()
    }

    #[test]
    fn test_derive_btc_address() {
        let seed = test_seed();
        let addr = derive_address(&seed, Chain::Bitcoin, 0, 0).unwrap();
        assert!(addr.address.starts_with("bc1"), "BTC address should start with bc1, got: {}", addr.address);
        assert_eq!(addr.derivation_path, "m/84'/0'/0'/0/0");
    }

    #[test]
    fn test_derive_eth_address() {
        let seed = test_seed();
        let addr = derive_address(&seed, Chain::Ethereum, 0, 0).unwrap();
        assert!(addr.address.starts_with("0x"), "ETH address should start with 0x, got: {}", addr.address);
        assert_eq!(addr.address.len(), 42); // 0x + 40 hex chars
        assert_eq!(addr.derivation_path, "m/44'/60'/0'/0/0");
    }

    #[test]
    fn test_derive_sol_address() {
        let seed = test_seed();
        let addr = derive_address(&seed, Chain::Solana, 0, 0).unwrap();
        // Solana addresses are Base58-encoded 32-byte public keys
        assert!(addr.address.len() >= 32 && addr.address.len() <= 44);
        assert_eq!(addr.derivation_path, "m/44'/501'/0'/0'");
    }

    #[test]
    fn test_derive_all_addresses() {
        let seed = test_seed();
        let addresses = derive_all_addresses(&seed, 0).unwrap();
        assert_eq!(addresses.len(), 3); // BTC, ETH, SOL
    }

    #[test]
    fn test_evm_chains_same_address() {
        let seed = test_seed();
        let eth_addr = derive_address(&seed, Chain::Ethereum, 0, 0).unwrap();
        let poly_addr = derive_address(&seed, Chain::Polygon, 0, 0).unwrap();
        let arb_addr = derive_address(&seed, Chain::Arbitrum, 0, 0).unwrap();
        // All EVM chains derive same address from same seed
        assert_eq!(eth_addr.address, poly_addr.address);
        assert_eq!(eth_addr.address, arb_addr.address);
    }

    #[test]
    fn test_addresses_deterministic() {
        let seed = test_seed();
        let addr1 = derive_address(&seed, Chain::Ethereum, 0, 0).unwrap();
        let addr2 = derive_address(&seed, Chain::Ethereum, 0, 0).unwrap();
        assert_eq!(addr1.address, addr2.address);
    }
}
