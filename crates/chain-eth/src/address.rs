use k256::elliptic_curve::sec1::{FromEncodedPoint, ToEncodedPoint};
use k256::{EncodedPoint, PublicKey};
use sha3::{Digest, Keccak256};

use crate::error::EthError;

/// Derives an EIP-55 checksummed Ethereum address from an uncompressed secp256k1
/// public key (65 bytes, starting with 0x04).
///
/// The derivation takes the Keccak-256 hash of the 64-byte public key (without
/// the 0x04 prefix) and uses the last 20 bytes as the address.
pub fn pubkey_to_eth_address(uncompressed_pubkey: &[u8; 65]) -> Result<String, EthError> {
    if uncompressed_pubkey[0] != 0x04 {
        return Err(EthError::InvalidPublicKey(
            "uncompressed key must start with 0x04".into(),
        ));
    }

    // Keccak-256 of the 64-byte key (skip the 0x04 prefix).
    let hash = Keccak256::digest(&uncompressed_pubkey[1..]);

    // Last 20 bytes are the raw address.
    let mut addr_bytes = [0u8; 20];
    addr_bytes.copy_from_slice(&hash[12..]);

    let addr_hex = hex::encode(addr_bytes);
    checksum_address(&format!("0x{addr_hex}"))
}

/// Derives an EIP-55 checksummed Ethereum address from a compressed secp256k1
/// public key (33 bytes).
///
/// The compressed key is first decompressed via k256, then the standard
/// derivation path is followed.
pub fn pubkey_bytes_to_eth_address(pubkey_33_bytes: &[u8; 33]) -> Result<String, EthError> {
    let encoded = EncodedPoint::from_bytes(pubkey_33_bytes).map_err(|e| {
        EthError::InvalidPublicKey(format!("invalid compressed key encoding: {e}"))
    })?;

    let pubkey: Option<PublicKey> = PublicKey::from_encoded_point(&encoded).into();
    let pubkey = pubkey.ok_or_else(|| {
        EthError::InvalidPublicKey("point is not on the secp256k1 curve".into())
    })?;

    // Decompress to uncompressed form (65 bytes with 0x04 prefix).
    let uncompressed = pubkey.to_encoded_point(false);
    let uncompressed_bytes: &[u8] = uncompressed.as_bytes();

    let mut key_65 = [0u8; 65];
    key_65.copy_from_slice(uncompressed_bytes);

    pubkey_to_eth_address(&key_65)
}

/// Validates an Ethereum address string.
///
/// Checks that the address has the correct format (0x + 40 hex characters).
/// If the address contains mixed case, the EIP-55 checksum is verified.
pub fn validate_address(address: &str) -> Result<bool, EthError> {
    if !address.starts_with("0x") && !address.starts_with("0X") {
        return Err(EthError::InvalidAddress(
            "address must start with 0x".into(),
        ));
    }

    let hex_part = &address[2..];

    if hex_part.len() != 40 {
        return Err(EthError::InvalidAddress(format!(
            "expected 40 hex characters, got {}",
            hex_part.len()
        )));
    }

    // Check that all characters are valid hex digits.
    if !hex_part.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(EthError::InvalidAddress(
            "address contains non-hex characters".into(),
        ));
    }

    // If the address is all-lowercase or all-uppercase, it's valid (no checksum
    // to verify).
    let is_all_lower = hex_part.chars().all(|c| !c.is_ascii_uppercase());
    let is_all_upper = hex_part.chars().all(|c| !c.is_ascii_lowercase());

    if is_all_lower || is_all_upper {
        return Ok(true);
    }

    // Mixed case: verify EIP-55 checksum.
    let checksummed = checksum_address(&format!("0x{}", hex_part.to_lowercase()))?;
    Ok(checksummed == address)
}

/// Applies EIP-55 mixed-case checksum encoding to an Ethereum address.
///
/// The input should be a lowercase 0x-prefixed address. Returns the
/// checksummed version.
pub fn checksum_address(address: &str) -> Result<String, EthError> {
    if !address.starts_with("0x") && !address.starts_with("0X") {
        return Err(EthError::InvalidAddress(
            "address must start with 0x".into(),
        ));
    }

    let hex_part = address[2..].to_lowercase();

    if hex_part.len() != 40 {
        return Err(EthError::InvalidAddress(format!(
            "expected 40 hex characters, got {}",
            hex_part.len()
        )));
    }

    if !hex_part.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(EthError::InvalidAddress(
            "address contains non-hex characters".into(),
        ));
    }

    // EIP-55: hash the lowercase hex address (without 0x).
    let hash = Keccak256::digest(hex_part.as_bytes());
    let hash_hex = hex::encode(hash);

    let mut checksummed = String::with_capacity(42);
    checksummed.push_str("0x");

    for (i, c) in hex_part.chars().enumerate() {
        if c.is_ascii_digit() {
            checksummed.push(c);
        } else {
            // If the corresponding nibble in the hash is >= 8, uppercase it.
            let hash_nibble =
                u8::from_str_radix(&hash_hex[i..i + 1], 16).unwrap_or(0);
            if hash_nibble >= 8 {
                checksummed.push(c.to_ascii_uppercase());
            } else {
                checksummed.push(c);
            }
        }
    }

    Ok(checksummed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eip55_checksum_known_addresses() {
        // Test vectors from EIP-55.
        let cases = [
            "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
            "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
            "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
            "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb",
        ];

        for expected in &cases {
            let lower = format!("0x{}", expected[2..].to_lowercase());
            let result = checksum_address(&lower).unwrap();
            assert_eq!(
                &result, expected,
                "checksum mismatch for {}",
                expected
            );
        }
    }

    #[test]
    fn checksum_all_lowercase_input() {
        let input = "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed";
        let result = checksum_address(input).unwrap();
        assert_eq!(result, "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed");
    }

    #[test]
    fn validate_valid_checksummed_address() {
        let addr = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed";
        assert!(validate_address(addr).unwrap());
    }

    #[test]
    fn validate_all_lowercase_address() {
        let addr = "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed";
        assert!(validate_address(addr).unwrap());
    }

    #[test]
    fn validate_all_uppercase_address() {
        let addr = "0x5AAEB6053F3E94C9B9A09F33669435E7EF1BEAED";
        assert!(validate_address(addr).unwrap());
    }

    #[test]
    fn validate_bad_checksum_returns_false() {
        // Intentionally wrong case on a letter to break checksum.
        let addr = "0x5AAEB6053F3E94C9b9A09f33669435E7Ef1BeAed";
        assert!(!validate_address(addr).unwrap());
    }

    #[test]
    fn validate_short_address_errors() {
        let addr = "0x5aAeb6053F";
        assert!(validate_address(addr).is_err());
    }

    #[test]
    fn validate_no_prefix_errors() {
        let addr = "5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed";
        assert!(validate_address(addr).is_err());
    }

    #[test]
    fn validate_non_hex_chars_errors() {
        let addr = "0xGGGGb6053F3E94C9b9A09f33669435E7Ef1BeAed";
        assert!(validate_address(addr).is_err());
    }

    #[test]
    fn pubkey_to_address_known_vector() {
        // Well-known test: private key of all 1s.
        // Private key: 0x0000...0001
        // Expected address: 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf
        use k256::SecretKey;

        let mut privkey = [0u8; 32];
        privkey[31] = 1;

        let secret = SecretKey::from_bytes((&privkey).into())
            .expect("valid private key");
        let pubkey = secret.public_key();
        let uncompressed = pubkey.to_encoded_point(false);
        let uncompressed_bytes: &[u8] = uncompressed.as_bytes();

        let mut key_65 = [0u8; 65];
        key_65.copy_from_slice(uncompressed_bytes);

        let address = pubkey_to_eth_address(&key_65).unwrap();
        assert_eq!(address, "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf");
    }

    #[test]
    fn compressed_pubkey_to_address() {
        use k256::SecretKey;

        let mut privkey = [0u8; 32];
        privkey[31] = 1;

        let secret = SecretKey::from_bytes((&privkey).into())
            .expect("valid private key");
        let pubkey = secret.public_key();

        let compressed = pubkey.to_encoded_point(true);
        let compressed_bytes: &[u8] = compressed.as_bytes();

        let mut key_33 = [0u8; 33];
        key_33.copy_from_slice(compressed_bytes);

        let address = pubkey_bytes_to_eth_address(&key_33).unwrap();
        assert_eq!(address, "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf");
    }

    #[test]
    fn invalid_uncompressed_prefix_errors() {
        let mut key = [0u8; 65];
        key[0] = 0x03; // wrong prefix
        assert!(pubkey_to_eth_address(&key).is_err());
    }

    #[test]
    fn checksum_address_invalid_no_prefix() {
        let result = checksum_address("5aaeb6053f3e94c9b9a09f33669435e7ef1beaed");
        assert!(result.is_err());
    }

    #[test]
    fn checksum_address_invalid_length() {
        let result = checksum_address("0xdeadbeef");
        assert!(result.is_err());
    }
}
