//! Solana address derivation and validation.
//!
//! Solana addresses are simply Base58-encoded 32-byte Ed25519 public keys.
//! There is no hashing step (unlike Bitcoin or Ethereum). The canonical
//! alphabet is the standard Bitcoin Base58 alphabet used by the `bs58` crate.

use crate::error::SolError;

/// Convert a 32-byte Ed25519 public key to a Solana address string.
///
/// The Solana address is the Base58 encoding of the raw 32-byte public key.
/// No hashing is applied — the public key bytes ARE the address bytes.
pub fn keypair_to_address(ed25519_pubkey: &[u8; 32]) -> String {
    bs58::encode(ed25519_pubkey).into_string()
}

/// Validate a Solana address string.
///
/// A valid Solana address is a Base58-encoded string that decodes to exactly
/// 32 bytes. Returns `Ok(true)` if valid, or an error if decoding fails or
/// the length is wrong.
pub fn validate_address(address: &str) -> Result<bool, SolError> {
    let bytes = bs58::decode(address)
        .into_vec()
        .map_err(|e| SolError::InvalidAddress(format!("base58 decode failed: {e}")))?;

    if bytes.len() != 32 {
        return Err(SolError::InvalidAddress(format!(
            "expected 32 bytes, got {}",
            bytes.len()
        )));
    }

    Ok(true)
}

/// Decode a Solana address string to its 32-byte representation.
///
/// Returns an error if the address is not valid Base58 or does not decode
/// to exactly 32 bytes.
pub fn address_to_bytes(address: &str) -> Result<[u8; 32], SolError> {
    let bytes = bs58::decode(address)
        .into_vec()
        .map_err(|e| SolError::InvalidAddress(format!("base58 decode failed: {e}")))?;

    let arr: [u8; 32] = bytes.try_into().map_err(|v: Vec<u8>| {
        SolError::InvalidAddress(format!("expected 32 bytes, got {}", v.len()))
    })?;

    Ok(arr)
}

/// Encode 32 bytes as a Solana address (Base58 string).
pub fn bytes_to_address(bytes: &[u8; 32]) -> String {
    bs58::encode(bytes).into_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The System Program address is 32 zero bytes, which encodes to
    /// "11111111111111111111111111111111" in Base58.
    #[test]
    fn system_program_address() {
        let zeros = [0u8; 32];
        let addr = keypair_to_address(&zeros);
        assert_eq!(addr, "11111111111111111111111111111111");
    }

    #[test]
    fn roundtrip_encode_decode() {
        // Known Solana address (the Token Program)
        let address = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
        let bytes = address_to_bytes(address).unwrap();
        let recovered = bytes_to_address(&bytes);
        assert_eq!(recovered, address);
    }

    #[test]
    fn keypair_to_address_and_back() {
        let pubkey: [u8; 32] = [
            0x0e, 0xf2, 0x35, 0x68, 0x3f, 0xbc, 0xb4, 0x92, 0xf1, 0x12, 0x66, 0x7c, 0xc6,
            0x22, 0xaf, 0x04, 0x0d, 0x13, 0x96, 0xab, 0x2b, 0x12, 0x3f, 0x8f, 0xc1, 0xa1,
            0xe1, 0x22, 0x64, 0xfe, 0xd6, 0xb7,
        ];
        let address = keypair_to_address(&pubkey);
        let recovered = address_to_bytes(&address).unwrap();
        assert_eq!(recovered, pubkey);
    }

    #[test]
    fn validate_valid_address() {
        let result = validate_address("11111111111111111111111111111111");
        assert!(result.is_ok());
        assert!(result.unwrap());
    }

    #[test]
    fn validate_token_program_address() {
        let result = validate_address("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
        assert!(result.is_ok());
        assert!(result.unwrap());
    }

    #[test]
    fn validate_garbage_returns_error() {
        let result = validate_address("not-a-valid-address!!!");
        assert!(result.is_err());
    }

    #[test]
    fn validate_too_short_returns_error() {
        // "1" decodes to a single zero byte, which is not 32 bytes.
        let result = validate_address("1");
        assert!(result.is_err());
    }

    #[test]
    fn address_to_bytes_invalid() {
        let result = address_to_bytes("###invalid###");
        assert!(result.is_err());
    }

    #[test]
    fn bytes_to_address_deterministic() {
        let bytes = [0xffu8; 32];
        let a = bytes_to_address(&bytes);
        let b = bytes_to_address(&bytes);
        assert_eq!(a, b);
    }

    #[test]
    fn well_known_address_decodes_to_32_bytes() {
        // Memo Program v2
        let address = "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr";
        let bytes = address_to_bytes(address).unwrap();
        assert_eq!(bytes.len(), 32);
    }
}
