/// Minimal ABI encoding for EVM function calls.
///
/// This module provides just enough ABI encoding to build ERC-20 and similar
/// contract call data without pulling in a full ABI parser.

/// A single ABI-encoded parameter.
#[derive(Debug, Clone)]
pub enum AbiParam {
    /// A 20-byte Ethereum address, left-padded to 32 bytes.
    Address([u8; 20]),
    /// A 256-bit unsigned integer as a big-endian 32-byte array.
    Uint256([u8; 32]),
    /// Dynamic bytes (currently encoded inline as a 32-byte right-padded word
    /// for short values; callers must ensure data fits in 32 bytes for
    /// static-style encoding).
    Bytes(Vec<u8>),
}

/// Encodes a function call with the given 4-byte selector and ABI parameters.
///
/// The output is `selector || encode(params[0]) || encode(params[1]) || ...`
/// where each parameter is encoded as a 32-byte ABI word.
///
/// # Parameters
///
/// - `selector`: The 4-byte function selector (e.g., `0xa9059cbb` for ERC-20
///   `transfer`).
/// - `params`: Slice of [`AbiParam`] values to encode after the selector.
pub fn encode_function_call(selector: [u8; 4], params: &[AbiParam]) -> Vec<u8> {
    let mut data = Vec::with_capacity(4 + params.len() * 32);
    data.extend_from_slice(&selector);

    for param in params {
        data.extend_from_slice(&encode_param(param));
    }

    data
}

/// Encodes a single [`AbiParam`] as a 32-byte ABI word.
fn encode_param(param: &AbiParam) -> [u8; 32] {
    match param {
        AbiParam::Address(addr) => {
            // Left-pad: 12 zero bytes + 20 address bytes.
            let mut word = [0u8; 32];
            word[12..].copy_from_slice(addr);
            word
        }
        AbiParam::Uint256(value) => {
            // Already a 32-byte big-endian integer.
            *value
        }
        AbiParam::Bytes(bytes) => {
            // Right-pad: data + trailing zero bytes.
            let mut word = [0u8; 32];
            let len = bytes.len().min(32);
            word[..len].copy_from_slice(&bytes[..len]);
            word
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_address_param() {
        let mut addr = [0u8; 20];
        addr[0] = 0xde;
        addr[19] = 0xad;

        let word = encode_param(&AbiParam::Address(addr));

        // First 12 bytes should be zero (left padding).
        assert_eq!(&word[..12], &[0u8; 12]);
        // Last 20 bytes should be the address.
        assert_eq!(&word[12..], &addr);
    }

    #[test]
    fn encode_uint256_param() {
        let mut value = [0u8; 32];
        value[31] = 42;

        let word = encode_param(&AbiParam::Uint256(value));
        assert_eq!(word, value);
    }

    #[test]
    fn encode_bytes_param_short() {
        let data = vec![0xCA, 0xFE];

        let word = encode_param(&AbiParam::Bytes(data));

        assert_eq!(word[0], 0xCA);
        assert_eq!(word[1], 0xFE);
        // Remaining bytes should be zero (right padding).
        assert_eq!(&word[2..], &[0u8; 30]);
    }

    #[test]
    fn encode_function_call_with_selector_only() {
        let selector = [0xa9, 0x05, 0x9c, 0xbb];
        let data = encode_function_call(selector, &[]);

        assert_eq!(data.len(), 4);
        assert_eq!(data, selector.to_vec());
    }

    #[test]
    fn encode_function_call_with_params() {
        let selector = [0xa9, 0x05, 0x9c, 0xbb];
        let mut addr = [0u8; 20];
        addr[19] = 0x01;

        let mut amount = [0u8; 32];
        amount[31] = 100;

        let params = [AbiParam::Address(addr), AbiParam::Uint256(amount)];
        let data = encode_function_call(selector, &params);

        // 4-byte selector + 2 * 32-byte params = 68 bytes.
        assert_eq!(data.len(), 68);
        assert_eq!(&data[..4], &selector);

        // Address param: 12 zero bytes + address.
        assert_eq!(&data[4..16], &[0u8; 12]);
        assert_eq!(data[35], 0x01);

        // Uint256 param: the amount.
        assert_eq!(data[67], 100);
    }

    #[test]
    fn encode_bytes_param_truncates_at_32() {
        let data = vec![0xFF; 64]; // More than 32 bytes.

        let word = encode_param(&AbiParam::Bytes(data));

        // Should only take the first 32 bytes.
        assert_eq!(word, [0xFF; 32]);
    }

    #[test]
    fn encode_empty_bytes_param() {
        let data = vec![];

        let word = encode_param(&AbiParam::Bytes(data));
        assert_eq!(word, [0u8; 32]);
    }
}
