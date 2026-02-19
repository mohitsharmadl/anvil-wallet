use bip32::{DerivationPath, XPrv};
use k256::ecdsa::SigningKey;
use zeroize::Zeroize;

use crate::error::WalletError;
use crate::types::Chain;

/// BIP-44 derivation path: m/purpose'/coin_type'/account'/change/address_index
///
/// - BTC:  m/84'/0'/0'/0/0  (BIP-84 for native SegWit P2WPKH)
/// - ETH:  m/44'/60'/0'/0/0 (BIP-44 standard)
/// - SOL:  m/44'/501'/0'/0' (Solana uses hardened at all levels)
fn derivation_path_for_chain(chain: Chain, account: u32, index: u32) -> Result<String, WalletError> {
    match chain {
        // BIP-84 for native SegWit
        Chain::Bitcoin => Ok(format!("m/84'/0'/{}'/0/{}", account, index)),
        Chain::BitcoinTestnet => Ok(format!("m/84'/1'/{}'/0/{}", account, index)),

        // BIP-44 for all EVM chains (same derivation, different chain_id at TX level)
        Chain::Ethereum
        | Chain::Polygon
        | Chain::Arbitrum
        | Chain::Base
        | Chain::Optimism
        | Chain::Bsc
        | Chain::Avalanche
        | Chain::Sepolia
        | Chain::PolygonAmoy => Ok(format!("m/44'/60'/{}'/0/{}", account, index)),

        // Solana: all hardened
        Chain::Solana | Chain::SolanaDevnet => Ok(format!("m/44'/501'/{}'/0'", account)),

        // Zcash: BIP-44 coin type 133
        Chain::Zcash => Ok(format!("m/44'/133'/{}'/0/{}", account, index)),
        Chain::ZcashTestnet => Ok(format!("m/44'/1'/{}'/0/{}", account, index)),
    }
}

/// Derive a secp256k1 private key from seed using BIP-32
pub fn derive_secp256k1_key(
    seed: &[u8],
    chain: Chain,
    account: u32,
    index: u32,
) -> Result<DerivedKey, WalletError> {
    let path_str = derivation_path_for_chain(chain, account, index)?;

    let path: DerivationPath = path_str
        .parse()
        .map_err(|e: bip32::Error| WalletError::DerivationFailed(e.to_string()))?;

    let xprv = XPrv::derive_from_path(seed, &path)
        .map_err(|e| WalletError::DerivationFailed(e.to_string()))?;

    let private_key_bytes: [u8; 32] = xprv.to_bytes().into();
    let signing_key = SigningKey::from_bytes(&private_key_bytes.into())
        .map_err(|e| WalletError::DerivationFailed(e.to_string()))?;

    let verifying_key = signing_key.verifying_key();
    let public_key_compressed: [u8; 33] = verifying_key.to_sec1_bytes()
        .as_ref()
        .try_into()
        .map_err(|_| WalletError::DerivationFailed("Invalid public key length".into()))?;

    let public_key_uncompressed: [u8; 65] = verifying_key
        .to_encoded_point(false)
        .as_bytes()
        .try_into()
        .map_err(|_| WalletError::DerivationFailed("Invalid uncompressed public key".into()))?;

    Ok(DerivedKey {
        private_key: private_key_bytes,
        public_key_compressed,
        public_key_uncompressed,
        derivation_path: path_str,
    })
}

/// Derive an Ed25519 private key from seed (for Solana)
/// Uses SLIP-0010 derivation for Ed25519
pub fn derive_ed25519_key(
    seed: &[u8],
    chain: Chain,
    account: u32,
) -> Result<DerivedEd25519Key, WalletError> {
    let path_str = derivation_path_for_chain(chain, account, 0)?;

    // SLIP-0010 Ed25519 derivation
    // Master key: HMAC-SHA512(key="ed25519 seed", data=seed)
    use hmac::{Hmac, Mac};
    use sha2::Sha512;

    type HmacSha512 = Hmac<Sha512>;

    let mut mac = HmacSha512::new_from_slice(b"ed25519 seed")
        .map_err(|e| WalletError::DerivationFailed(e.to_string()))?;
    mac.update(seed);
    let result = mac.finalize().into_bytes();

    let mut key = [0u8; 32];
    let mut chain_code = [0u8; 32];
    key.copy_from_slice(&result[..32]);
    chain_code.copy_from_slice(&result[32..]);

    // Parse derivation path and derive child keys
    // For Solana: m/44'/501'/account'/0'
    // All components are hardened for Ed25519
    let components = parse_derivation_path(&path_str)?;

    for child_index in components {
        let mut mac = HmacSha512::new_from_slice(&chain_code)
            .map_err(|e| WalletError::DerivationFailed(e.to_string()))?;
        // Hardened child: 0x00 || key || index (with hardened bit set)
        mac.update(&[0x00]);
        mac.update(&key);
        mac.update(&(child_index | 0x80000000).to_be_bytes());
        let result = mac.finalize().into_bytes();

        key.copy_from_slice(&result[..32]);
        chain_code.copy_from_slice(&result[32..]);
    }

    // Create Ed25519 signing key
    let signing_key = ed25519_dalek::SigningKey::from_bytes(&key);
    let verifying_key = signing_key.verifying_key();
    let public_key: [u8; 32] = verifying_key.to_bytes();

    let derived = DerivedEd25519Key {
        private_key: key,
        public_key,
        derivation_path: path_str,
    };

    // Zeroize intermediates
    key.zeroize();
    chain_code.zeroize();

    Ok(derived)
}

/// Parse "m/44'/501'/0'/0'" into [44, 501, 0, 0]
fn parse_derivation_path(path: &str) -> Result<Vec<u32>, WalletError> {
    let path = path.strip_prefix("m/").ok_or_else(|| {
        WalletError::DerivationFailed("Path must start with m/".into())
    })?;

    path.split('/')
        .map(|component| {
            let (num_str, _is_hardened) = if component.ends_with('\'') || component.ends_with('h')
            {
                (&component[..component.len() - 1], true)
            } else {
                (component, false)
            };
            num_str
                .parse::<u32>()
                .map_err(|e| WalletError::DerivationFailed(format!("Invalid path component: {e}")))
        })
        .collect()
}

/// Derived secp256k1 key (for BTC and ETH)
pub struct DerivedKey {
    pub private_key: [u8; 32],
    pub public_key_compressed: [u8; 33],
    pub public_key_uncompressed: [u8; 65],
    pub derivation_path: String,
}

impl Drop for DerivedKey {
    fn drop(&mut self) {
        self.private_key.zeroize();
    }
}

/// Derived Ed25519 key (for Solana)
pub struct DerivedEd25519Key {
    pub private_key: [u8; 32],
    pub public_key: [u8; 32],
    pub derivation_path: String,
}

impl Drop for DerivedEd25519Key {
    fn drop(&mut self) {
        self.private_key.zeroize();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // BIP-39 test vector: "abandon" x11 + "about"
    const TEST_MNEMONIC: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    fn test_seed() -> Vec<u8> {
        use crate::mnemonic::mnemonic_to_seed;
        mnemonic_to_seed(TEST_MNEMONIC, "").unwrap()
    }

    #[test]
    fn test_derive_eth_key() {
        let seed = test_seed();
        let key = derive_secp256k1_key(&seed, Chain::Ethereum, 0, 0).unwrap();
        assert_eq!(key.derivation_path, "m/44'/60'/0'/0/0");
        assert_eq!(key.private_key.len(), 32);
        assert_eq!(key.public_key_compressed.len(), 33);
        assert_eq!(key.public_key_uncompressed.len(), 65);
        // Compressed key should start with 02 or 03
        assert!(key.public_key_compressed[0] == 0x02 || key.public_key_compressed[0] == 0x03);
        // Uncompressed key should start with 04
        assert_eq!(key.public_key_uncompressed[0], 0x04);
    }

    #[test]
    fn test_derive_btc_key() {
        let seed = test_seed();
        let key = derive_secp256k1_key(&seed, Chain::Bitcoin, 0, 0).unwrap();
        assert_eq!(key.derivation_path, "m/84'/0'/0'/0/0");
    }

    #[test]
    fn test_derive_sol_key() {
        let seed = test_seed();
        let key = derive_ed25519_key(&seed, Chain::Solana, 0).unwrap();
        assert_eq!(key.derivation_path, "m/44'/501'/0'/0'");
        assert_eq!(key.private_key.len(), 32);
        assert_eq!(key.public_key.len(), 32);
    }

    #[test]
    fn test_derivation_deterministic() {
        let seed = test_seed();
        let key1 = derive_secp256k1_key(&seed, Chain::Ethereum, 0, 0).unwrap();
        let key2 = derive_secp256k1_key(&seed, Chain::Ethereum, 0, 0).unwrap();
        assert_eq!(key1.private_key, key2.private_key);
        assert_eq!(key1.public_key_compressed, key2.public_key_compressed);
    }

    #[test]
    fn test_different_accounts_different_keys() {
        let seed = test_seed();
        let key0 = derive_secp256k1_key(&seed, Chain::Ethereum, 0, 0).unwrap();
        let key1 = derive_secp256k1_key(&seed, Chain::Ethereum, 1, 0).unwrap();
        assert_ne!(key0.private_key, key1.private_key);
    }

    #[test]
    fn test_different_chains_different_keys() {
        let seed = test_seed();
        let btc_key = derive_secp256k1_key(&seed, Chain::Bitcoin, 0, 0).unwrap();
        let eth_key = derive_secp256k1_key(&seed, Chain::Ethereum, 0, 0).unwrap();
        assert_ne!(btc_key.private_key, eth_key.private_key);
    }

    #[test]
    fn test_evm_chains_same_key() {
        // All EVM chains should derive the same key (differentiated by chain_id)
        let seed = test_seed();
        let eth_key = derive_secp256k1_key(&seed, Chain::Ethereum, 0, 0).unwrap();
        let poly_key = derive_secp256k1_key(&seed, Chain::Polygon, 0, 0).unwrap();
        let arb_key = derive_secp256k1_key(&seed, Chain::Arbitrum, 0, 0).unwrap();
        assert_eq!(eth_key.private_key, poly_key.private_key);
        assert_eq!(eth_key.private_key, arb_key.private_key);
    }

    #[test]
    fn test_parse_derivation_path() {
        let components = parse_derivation_path("m/44'/60'/0'/0/0").unwrap();
        assert_eq!(components, vec![44, 60, 0, 0, 0]);
    }
}
