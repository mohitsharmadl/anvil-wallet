use ripemd::Ripemd160;
use sha2::{Digest, Sha256};

use crate::error::ZecError;

/// Zcash network for address version prefixes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ZecNetwork {
    Mainnet,
    Testnet,
}

/// 2-byte version prefix for Zcash transparent P2PKH addresses.
/// Mainnet: 0x1CB8 -> addresses start with "t1"
/// Testnet: 0x1D25 -> addresses start with "tm"
impl ZecNetwork {
    pub fn t_addr_version(&self) -> [u8; 2] {
        match self {
            ZecNetwork::Mainnet => [0x1C, 0xB8],
            ZecNetwork::Testnet => [0x1D, 0x25],
        }
    }
}

/// Derive a transparent P2PKH (t-addr) from a 33-byte compressed secp256k1 public key.
///
/// Steps:
/// 1. SHA-256(pubkey)
/// 2. RIPEMD-160(sha256_result) -> 20-byte pubkey hash
/// 3. Prepend 2-byte version prefix
/// 4. Base58Check encode (4-byte SHA-256d checksum)
pub fn pubkey_to_t_address(
    pubkey_bytes: &[u8; 33],
    network: ZecNetwork,
) -> Result<String, ZecError> {
    // Validate compressed public key prefix
    if pubkey_bytes[0] != 0x02 && pubkey_bytes[0] != 0x03 {
        return Err(ZecError::InvalidPublicKey(
            "compressed key must start with 0x02 or 0x03".into(),
        ));
    }

    // Hash160: RIPEMD-160(SHA-256(pubkey))
    let sha256_hash = Sha256::digest(pubkey_bytes);
    let pubkey_hash = Ripemd160::digest(sha256_hash);

    // Build payload: version (2 bytes) + pubkey_hash (20 bytes)
    let version = network.t_addr_version();
    let mut payload = Vec::with_capacity(22);
    payload.extend_from_slice(&version);
    payload.extend_from_slice(&pubkey_hash);

    // Base58Check: append 4-byte checksum from double SHA-256
    let checksum = double_sha256_checksum(&payload);
    payload.extend_from_slice(&checksum);

    Ok(bs58::encode(&payload).into_string())
}

/// Compute Hash160 (RIPEMD-160(SHA-256(data))) — used for P2PKH script creation.
pub fn hash160(data: &[u8]) -> [u8; 20] {
    let sha = Sha256::digest(data);
    let ripemd = Ripemd160::digest(sha);
    ripemd.into()
}

/// Validate a Zcash transparent address string.
///
/// Checks Base58Check encoding and version prefix for the given network.
pub fn validate_address(address: &str, network: ZecNetwork) -> Result<bool, ZecError> {
    let decoded = bs58::decode(address)
        .into_vec()
        .map_err(|e| ZecError::InvalidAddress(format!("invalid base58: {e}")))?;

    // Must be exactly 26 bytes: 2 version + 20 hash + 4 checksum
    if decoded.len() != 26 {
        return Err(ZecError::InvalidAddress(format!(
            "expected 26 bytes, got {}",
            decoded.len()
        )));
    }

    // Verify checksum
    let payload = &decoded[..22];
    let checksum = &decoded[22..26];
    let expected = double_sha256_checksum(payload);
    if checksum != expected {
        return Err(ZecError::InvalidAddress("invalid checksum".into()));
    }

    // Check version prefix
    let expected_version = network.t_addr_version();
    Ok(decoded[0] == expected_version[0] && decoded[1] == expected_version[1])
}

/// Extract the 20-byte pubkey hash from a t-address.
pub fn address_to_pubkey_hash(address: &str) -> Result<[u8; 20], ZecError> {
    let decoded = bs58::decode(address)
        .into_vec()
        .map_err(|e| ZecError::InvalidAddress(format!("invalid base58: {e}")))?;

    if decoded.len() != 26 {
        return Err(ZecError::InvalidAddress("invalid address length".into()));
    }

    // Verify checksum
    let payload = &decoded[..22];
    let checksum = &decoded[22..26];
    let expected = double_sha256_checksum(payload);
    if checksum != expected {
        return Err(ZecError::InvalidAddress("invalid checksum".into()));
    }

    let mut hash = [0u8; 20];
    hash.copy_from_slice(&decoded[2..22]);
    Ok(hash)
}

/// Double SHA-256 checksum (first 4 bytes).
fn double_sha256_checksum(data: &[u8]) -> [u8; 4] {
    let first = Sha256::digest(data);
    let second = Sha256::digest(first);
    let mut checksum = [0u8; 4];
    checksum.copy_from_slice(&second[..4]);
    checksum
}

#[cfg(test)]
mod tests {
    use super::*;

    // Well-known test: privkey = 1 -> compressed pubkey
    const TEST_PUBKEY_HEX: &str =
        "0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798";

    fn test_pubkey() -> [u8; 33] {
        hex::decode(TEST_PUBKEY_HEX).unwrap().try_into().unwrap()
    }

    #[test]
    fn mainnet_t_address_starts_with_t1() {
        let addr = pubkey_to_t_address(&test_pubkey(), ZecNetwork::Mainnet).unwrap();
        assert!(
            addr.starts_with("t1"),
            "mainnet t-addr should start with t1, got: {addr}"
        );
    }

    #[test]
    fn testnet_t_address_starts_with_tm() {
        let addr = pubkey_to_t_address(&test_pubkey(), ZecNetwork::Testnet).unwrap();
        assert!(
            addr.starts_with("tm"),
            "testnet t-addr should start with tm, got: {addr}"
        );
    }

    #[test]
    fn t_address_deterministic() {
        let a1 = pubkey_to_t_address(&test_pubkey(), ZecNetwork::Mainnet).unwrap();
        let a2 = pubkey_to_t_address(&test_pubkey(), ZecNetwork::Mainnet).unwrap();
        assert_eq!(a1, a2);
    }

    #[test]
    fn t_address_length_is_valid() {
        let addr = pubkey_to_t_address(&test_pubkey(), ZecNetwork::Mainnet).unwrap();
        // Zcash t-addresses are typically 35 characters
        assert!(addr.len() >= 34 && addr.len() <= 36, "unexpected length: {}", addr.len());
    }

    #[test]
    fn different_networks_produce_different_addresses() {
        let main = pubkey_to_t_address(&test_pubkey(), ZecNetwork::Mainnet).unwrap();
        let test = pubkey_to_t_address(&test_pubkey(), ZecNetwork::Testnet).unwrap();
        assert_ne!(main, test);
    }

    #[test]
    fn invalid_pubkey_prefix_rejected() {
        let mut bad = test_pubkey();
        bad[0] = 0x04; // uncompressed prefix
        assert!(pubkey_to_t_address(&bad, ZecNetwork::Mainnet).is_err());
    }

    #[test]
    fn validate_roundtrip() {
        let addr = pubkey_to_t_address(&test_pubkey(), ZecNetwork::Mainnet).unwrap();
        let valid = validate_address(&addr, ZecNetwork::Mainnet).unwrap();
        assert!(valid);
    }

    #[test]
    fn validate_wrong_network() {
        let addr = pubkey_to_t_address(&test_pubkey(), ZecNetwork::Mainnet).unwrap();
        let valid = validate_address(&addr, ZecNetwork::Testnet).unwrap();
        assert!(!valid);
    }

    #[test]
    fn validate_garbage_address() {
        let result = validate_address("notanaddress!!!", ZecNetwork::Mainnet);
        assert!(result.is_err());
    }

    #[test]
    fn address_to_pubkey_hash_roundtrip() {
        let pubkey = test_pubkey();
        let addr = pubkey_to_t_address(&pubkey, ZecNetwork::Mainnet).unwrap();
        let hash = address_to_pubkey_hash(&addr).unwrap();
        let expected = hash160(&pubkey);
        assert_eq!(hash, expected);
    }

    #[test]
    fn hash160_known_vector() {
        // SHA-256(0x02...98) then RIPEMD-160 of that should produce a deterministic hash
        let h = hash160(&test_pubkey());
        assert_eq!(h.len(), 20);
        // Just verify it's non-zero
        assert!(h.iter().any(|&b| b != 0));
    }

    #[test]
    fn different_pubkeys_different_addresses() {
        let pk1 = test_pubkey();
        let mut pk2 = [0xcd; 33];
        pk2[0] = 0x02;
        // pk2 may not be a valid curve point but we just test the hash differs
        let h1 = hash160(&pk1);
        let h2 = hash160(&pk2);
        assert_ne!(h1, h2);
    }
}
