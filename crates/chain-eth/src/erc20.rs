use crate::abi::{encode_function_call, AbiParam};
use crate::error::EthError;

/// Function selector for `transfer(address,uint256)`: `0xa9059cbb`.
const TRANSFER_SELECTOR: [u8; 4] = [0xa9, 0x05, 0x9c, 0xbb];

/// Function selector for `balanceOf(address)`: `0x70a08231`.
const BALANCE_OF_SELECTOR: [u8; 4] = [0x70, 0xa0, 0x82, 0x31];

/// Function selector for `approve(address,uint256)`: `0x095ea7b3`.
const APPROVE_SELECTOR: [u8; 4] = [0x09, 0x5e, 0xa7, 0xb3];

/// Parses a 0x-prefixed hex address string into a 20-byte array.
fn parse_address(address: &str) -> Result<[u8; 20], EthError> {
    let hex_str = address.strip_prefix("0x").or_else(|| address.strip_prefix("0X")).ok_or_else(
        || EthError::InvalidAddress("address must start with 0x".into()),
    )?;

    if hex_str.len() != 40 {
        return Err(EthError::InvalidAddress(format!(
            "expected 40 hex characters, got {}",
            hex_str.len()
        )));
    }

    let bytes = hex::decode(hex_str)
        .map_err(|e| EthError::InvalidAddress(format!("invalid hex: {e}")))?;

    let mut addr = [0u8; 20];
    addr.copy_from_slice(&bytes);
    Ok(addr)
}

/// Encodes an ERC-20 `transfer(address,uint256)` call.
///
/// # Parameters
///
/// - `to`: The recipient address (0x-prefixed hex string).
/// - `amount`: The transfer amount as a big-endian 32-byte uint256.
///
/// # Returns
///
/// The complete calldata (4-byte selector + 64 bytes of ABI-encoded params).
pub fn encode_transfer(to: &str, amount: [u8; 32]) -> Result<Vec<u8>, EthError> {
    let addr = parse_address(to)?;
    let params = [AbiParam::Address(addr), AbiParam::Uint256(amount)];
    Ok(encode_function_call(TRANSFER_SELECTOR, &params))
}

/// Encodes an ERC-20 `balanceOf(address)` call.
///
/// # Parameters
///
/// - `owner`: The address to query (0x-prefixed hex string).
///
/// # Returns
///
/// The complete calldata (4-byte selector + 32 bytes of ABI-encoded address).
pub fn encode_balance_of(owner: &str) -> Result<Vec<u8>, EthError> {
    let addr = parse_address(owner)?;
    let params = [AbiParam::Address(addr)];
    Ok(encode_function_call(BALANCE_OF_SELECTOR, &params))
}

/// Encodes an ERC-20 `approve(address,uint256)` call.
///
/// # Parameters
///
/// - `spender`: The spender address (0x-prefixed hex string).
/// - `amount`: The approval amount as a big-endian 32-byte uint256.
///
/// # Returns
///
/// The complete calldata (4-byte selector + 64 bytes of ABI-encoded params).
pub fn encode_approve(spender: &str, amount: [u8; 32]) -> Result<Vec<u8>, EthError> {
    let addr = parse_address(spender)?;
    let params = [AbiParam::Address(addr), AbiParam::Uint256(amount)];
    Ok(encode_function_call(APPROVE_SELECTOR, &params))
}

/// Decodes a single uint256 return value from ABI-encoded data.
///
/// Useful for decoding the return value of `balanceOf` and similar view
/// functions that return a single uint256.
pub fn decode_uint256(data: &[u8]) -> Result<[u8; 32], EthError> {
    if data.len() < 32 {
        return Err(EthError::EncodingError(format!(
            "expected at least 32 bytes for uint256, got {}",
            data.len()
        )));
    }

    let mut result = [0u8; 32];
    result.copy_from_slice(&data[..32]);
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_transfer_correct_selector() {
        let to = "0x000000000000000000000000000000000000dEaD";
        let amount = [0u8; 32];

        let data = encode_transfer(to, amount).unwrap();

        // First 4 bytes should be the transfer selector.
        assert_eq!(&data[..4], &TRANSFER_SELECTOR);
    }

    #[test]
    fn encode_transfer_correct_length() {
        let to = "0x000000000000000000000000000000000000dEaD";
        let amount = [0u8; 32];

        let data = encode_transfer(to, amount).unwrap();

        // 4 (selector) + 32 (address) + 32 (amount) = 68 bytes.
        assert_eq!(data.len(), 68);
    }

    #[test]
    fn encode_transfer_encodes_address() {
        let to = "0x000000000000000000000000000000000000dEaD";
        let amount = [0u8; 32];

        let data = encode_transfer(to, amount).unwrap();

        // Address is left-padded to 32 bytes starting at offset 4.
        assert_eq!(&data[4..16], &[0u8; 12]); // 12 zero-pad bytes
        assert_eq!(data[34], 0xdE);
        assert_eq!(data[35], 0xaD);
    }

    #[test]
    fn encode_transfer_encodes_amount() {
        let to = "0x000000000000000000000000000000000000dEaD";
        let mut amount = [0u8; 32];
        amount[31] = 0x64; // 100

        let data = encode_transfer(to, amount).unwrap();

        // Amount is at bytes 36..68.
        assert_eq!(data[67], 0x64);
        assert_eq!(&data[36..67], &[0u8; 31]); // leading zeros
    }

    #[test]
    fn encode_transfer_invalid_address() {
        let result = encode_transfer("not-an-address", [0u8; 32]);
        assert!(result.is_err());
    }

    #[test]
    fn encode_balance_of_correct_selector() {
        let owner = "0x000000000000000000000000000000000000dEaD";
        let data = encode_balance_of(owner).unwrap();

        assert_eq!(&data[..4], &BALANCE_OF_SELECTOR);
    }

    #[test]
    fn encode_balance_of_correct_length() {
        let owner = "0x000000000000000000000000000000000000dEaD";
        let data = encode_balance_of(owner).unwrap();

        // 4 (selector) + 32 (address) = 36 bytes.
        assert_eq!(data.len(), 36);
    }

    #[test]
    fn encode_approve_correct_selector() {
        let spender = "0x000000000000000000000000000000000000dEaD";
        let amount = [0u8; 32];

        let data = encode_approve(spender, amount).unwrap();

        assert_eq!(&data[..4], &APPROVE_SELECTOR);
    }

    #[test]
    fn encode_approve_correct_length() {
        let spender = "0x000000000000000000000000000000000000dEaD";
        let amount = [0u8; 32];

        let data = encode_approve(spender, amount).unwrap();

        // 4 (selector) + 32 (address) + 32 (amount) = 68 bytes.
        assert_eq!(data.len(), 68);
    }

    #[test]
    fn decode_uint256_valid() {
        let mut data = [0u8; 32];
        data[31] = 42;

        let result = decode_uint256(&data).unwrap();
        assert_eq!(result[31], 42);
    }

    #[test]
    fn decode_uint256_ignores_extra_bytes() {
        let mut data = vec![0u8; 64];
        data[31] = 42;
        data[63] = 99; // Should be ignored.

        let result = decode_uint256(&data).unwrap();
        assert_eq!(result[31], 42);
    }

    #[test]
    fn decode_uint256_too_short() {
        let data = [0u8; 16];
        assert!(decode_uint256(&data).is_err());
    }

    #[test]
    fn encode_transfer_full_calldata_matches_expected() {
        // Known test vector: transfer 1 token (1e18 wei) to a specific address.
        let to = "0xdead000000000000000000000000000000000000";
        let mut amount = [0u8; 32];
        // 1e18 = 0x0de0b6b3a7640000
        amount[24] = 0x0d;
        amount[25] = 0xe0;
        amount[26] = 0xb6;
        amount[27] = 0xb3;
        amount[28] = 0xa7;
        amount[29] = 0x64;
        amount[30] = 0x00;
        amount[31] = 0x00;

        let data = encode_transfer(to, amount).unwrap();

        // Selector: a9059cbb
        assert_eq!(hex::encode(&data[..4]), "a9059cbb");

        // Address padded: 000000000000000000000000dead...
        let addr_hex = hex::encode(&data[4..36]);
        assert!(addr_hex.starts_with("000000000000000000000000dead"));

        // Amount: ...0de0b6b3a7640000
        let amount_hex = hex::encode(&data[36..68]);
        assert!(amount_hex.ends_with("0de0b6b3a7640000"));
    }

    #[test]
    fn parse_address_short_errors() {
        let result = parse_address("0xdead");
        assert!(result.is_err());
    }

    #[test]
    fn parse_address_no_prefix_errors() {
        let result = parse_address("dead000000000000000000000000000000000000");
        assert!(result.is_err());
    }
}
