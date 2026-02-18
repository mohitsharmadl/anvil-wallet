use alloy_rlp::{Encodable, RlpEncodable};
use k256::ecdsa::signature::hazmat::PrehashSigner;
use k256::ecdsa::{RecoveryId, Signature, SigningKey};
use sha3::{Digest, Keccak256};
use zeroize::Zeroize;

use crate::erc20;
use crate::error::EthError;

/// An unsigned EIP-1559 (type 2) Ethereum transaction.
#[derive(Debug, Clone)]
pub struct EthTransaction {
    pub chain_id: u64,
    pub nonce: u64,
    pub max_priority_fee_per_gas: u128,
    pub max_fee_per_gas: u128,
    pub gas_limit: u64,
    /// Recipient address as a 0x-prefixed hex string.
    pub to: String,
    /// Transfer value in wei.
    pub value: u128,
    /// Calldata (empty for simple ETH transfers).
    pub data: Vec<u8>,
}

/// A signed EIP-1559 Ethereum transaction ready for broadcast.
pub struct SignedEthTransaction {
    /// RLP-encoded signed transaction bytes (including 0x02 type prefix).
    pub raw_tx: Vec<u8>,
    /// Transaction hash as a 0x-prefixed hex string.
    pub tx_hash: String,
}

/// Builds an unsigned EIP-1559 ETH transfer transaction.
pub fn build_transfer(
    chain_id: u64,
    nonce: u64,
    to: &str,
    value_wei: u128,
    max_priority_fee: u128,
    max_fee: u128,
    gas_limit: u64,
) -> Result<EthTransaction, EthError> {
    validate_to_address(to)?;

    Ok(EthTransaction {
        chain_id,
        nonce,
        max_priority_fee_per_gas: max_priority_fee,
        max_fee_per_gas: max_fee,
        gas_limit,
        to: to.to_string(),
        value: value_wei,
        data: Vec::new(),
    })
}

/// Builds an unsigned EIP-1559 ERC-20 token transfer transaction.
///
/// The calldata is automatically encoded using `transfer(address,uint256)`.
pub fn build_erc20_transfer(
    chain_id: u64,
    nonce: u64,
    token_contract: &str,
    to: &str,
    amount: [u8; 32],
    max_priority_fee: u128,
    max_fee: u128,
    gas_limit: u64,
) -> Result<EthTransaction, EthError> {
    validate_to_address(token_contract)?;

    let calldata = erc20::encode_transfer(to, amount)?;

    Ok(EthTransaction {
        chain_id,
        nonce,
        max_priority_fee_per_gas: max_priority_fee,
        max_fee_per_gas: max_fee,
        gas_limit,
        to: token_contract.to_string(),
        value: 0,
        data: calldata,
    })
}

/// Signs an EIP-1559 transaction with the given secp256k1 private key.
///
/// The signing process:
/// 1. RLP-encode the unsigned transaction fields.
/// 2. Prepend the type byte (0x02) to get the signing payload.
/// 3. Keccak-256 hash the payload.
/// 4. Sign the hash with the private key using k256.
/// 5. Build the signed transaction with v (y_parity), r, s appended.
/// 6. Return the raw bytes and transaction hash.
pub fn sign_transaction(
    tx: &EthTransaction,
    private_key: &[u8; 32],
) -> Result<SignedEthTransaction, EthError> {
    // Build the unsigned payload: 0x02 || rlp(unsigned_fields).
    let unsigned_payload = encode_unsigned_tx(tx)?;

    // Keccak-256 of the unsigned payload for signing.
    let msg_hash = Keccak256::digest(&unsigned_payload);

    // Create the signing key (zeroized on drop).
    let mut key_bytes = *private_key;
    let signing_key = SigningKey::from_bytes((&key_bytes).into())
        .map_err(|e| EthError::InvalidPrivateKey(e.to_string()))?;
    key_bytes.zeroize();

    // Sign the hash using PrehashSigner (signs a raw 32-byte hash).
    let (signature, recovery_id): (Signature, RecoveryId) = signing_key
        .sign_prehash(msg_hash.as_slice())
        .map_err(|e| EthError::SigningError(e.to_string()))?;

    let y_parity = recovery_id.is_y_odd() as u8;

    let r_generic = signature.r().to_bytes();
    let s_generic = signature.s().to_bytes();
    let mut r_bytes = [0u8; 32];
    let mut s_bytes = [0u8; 32];
    r_bytes.copy_from_slice(&r_generic);
    s_bytes.copy_from_slice(&s_generic);

    // Build the signed transaction: 0x02 || rlp(signed_fields).
    let signed_fields = SignedTxFields {
        chain_id: tx.chain_id,
        nonce: tx.nonce,
        max_priority_fee_per_gas: tx.max_priority_fee_per_gas,
        max_fee_per_gas: tx.max_fee_per_gas,
        gas_limit: tx.gas_limit,
        to: parse_to_bytes(&tx.to)?,
        value: tx.value,
        data: tx.data.clone(),
        // Empty access list.
        access_list: Vec::new(),
        signature_y_parity: y_parity,
        signature_r: r_bytes.into(),
        signature_s: s_bytes.into(),
    };

    let mut rlp_buf = Vec::new();
    signed_fields.encode(&mut rlp_buf);

    let mut raw_tx = Vec::with_capacity(1 + rlp_buf.len());
    raw_tx.push(0x02); // EIP-1559 type prefix.
    raw_tx.extend_from_slice(&rlp_buf);

    // Transaction hash is the Keccak-256 of the signed raw bytes.
    let tx_hash = Keccak256::digest(&raw_tx);
    let tx_hash_hex = format!("0x{}", hex::encode(tx_hash));

    Ok(SignedEthTransaction {
        raw_tx,
        tx_hash: tx_hash_hex,
    })
}

/// Signs an arbitrary message using EIP-191 personal_sign.
///
/// The message is hashed as: keccak256("\x19Ethereum Signed Message:\n" + len(message) + message)
/// Returns the 65-byte signature (r[32] + s[32] + v[1]) where v is 27 or 28.
pub fn sign_message(
    message: &[u8],
    private_key: &[u8; 32],
) -> Result<Vec<u8>, EthError> {
    // EIP-191 prefix
    let prefix = format!("\x19Ethereum Signed Message:\n{}", message.len());
    let mut hasher = Keccak256::new();
    hasher.update(prefix.as_bytes());
    hasher.update(message);
    let msg_hash = hasher.finalize();

    let mut key_bytes = *private_key;
    let signing_key = SigningKey::from_bytes((&key_bytes).into())
        .map_err(|e| EthError::InvalidPrivateKey(e.to_string()))?;
    key_bytes.zeroize();

    let (signature, recovery_id): (Signature, RecoveryId) = signing_key
        .sign_prehash(msg_hash.as_slice())
        .map_err(|e| EthError::SigningError(e.to_string()))?;

    let mut sig = Vec::with_capacity(65);
    sig.extend_from_slice(&signature.r().to_bytes());
    sig.extend_from_slice(&signature.s().to_bytes());
    sig.push(recovery_id.is_y_odd() as u8 + 27); // v = 27 or 28
    Ok(sig)
}

/// Encodes the unsigned EIP-1559 transaction as `0x02 || rlp(fields)`.
///
/// The RLP-encoded fields are:
/// `[chain_id, nonce, max_priority_fee_per_gas, max_fee_per_gas, gas_limit, to,
///   value, data, access_list]`
pub fn encode_unsigned_tx(tx: &EthTransaction) -> Result<Vec<u8>, EthError> {
    let unsigned_fields = UnsignedTxFields {
        chain_id: tx.chain_id,
        nonce: tx.nonce,
        max_priority_fee_per_gas: tx.max_priority_fee_per_gas,
        max_fee_per_gas: tx.max_fee_per_gas,
        gas_limit: tx.gas_limit,
        to: parse_to_bytes(&tx.to)?,
        value: tx.value,
        data: tx.data.clone(),
        access_list: Vec::new(),
    };

    let mut rlp_buf = Vec::new();
    unsigned_fields.encode(&mut rlp_buf);

    let mut payload = Vec::with_capacity(1 + rlp_buf.len());
    payload.push(0x02); // EIP-1559 type byte.
    payload.extend_from_slice(&rlp_buf);

    Ok(payload)
}

// ---------------------------------------------------------------------------
// RLP-encodable structures
// ---------------------------------------------------------------------------

/// Unsigned EIP-1559 transaction fields for RLP encoding.
#[derive(RlpEncodable)]
struct UnsignedTxFields {
    chain_id: u64,
    nonce: u64,
    max_priority_fee_per_gas: u128,
    max_fee_per_gas: u128,
    gas_limit: u64,
    to: RlpAddress,
    value: u128,
    data: Vec<u8>,
    access_list: Vec<AccessListItem>,
}

/// Signed EIP-1559 transaction fields for RLP encoding.
#[derive(RlpEncodable)]
struct SignedTxFields {
    chain_id: u64,
    nonce: u64,
    max_priority_fee_per_gas: u128,
    max_fee_per_gas: u128,
    gas_limit: u64,
    to: RlpAddress,
    value: u128,
    data: Vec<u8>,
    access_list: Vec<AccessListItem>,
    signature_y_parity: u8,
    signature_r: RlpU256,
    signature_s: RlpU256,
}

/// An EIP-2930 access list entry (kept empty for now).
#[derive(Debug, Clone, RlpEncodable)]
struct AccessListItem {
    address: RlpAddress,
    storage_keys: Vec<RlpFixedBytes<32>>,
}

/// Wrapper for a 20-byte Ethereum address that implements `Encodable`.
#[derive(Debug, Clone)]
struct RlpAddress([u8; 20]);

impl Encodable for RlpAddress {
    fn encode(&self, out: &mut dyn alloy_rlp::BufMut) {
        // Encode as a 20-byte string.
        self.0.as_slice().encode(out);
    }

    fn length(&self) -> usize {
        self.0.as_slice().length()
    }
}

/// Wrapper for a 256-bit integer (32 bytes) that encodes as minimal big-endian
/// bytes with leading zeros stripped (standard RLP integer encoding).
#[derive(Debug, Clone)]
struct RlpU256([u8; 32]);

impl From<[u8; 32]> for RlpU256 {
    fn from(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }
}

impl Encodable for RlpU256 {
    fn encode(&self, out: &mut dyn alloy_rlp::BufMut) {
        // Strip leading zeros for minimal encoding.
        let start = self.0.iter().position(|&b| b != 0).unwrap_or(32);
        let trimmed = &self.0[start..];
        trimmed.encode(out);
    }

    fn length(&self) -> usize {
        let start = self.0.iter().position(|&b| b != 0).unwrap_or(32);
        let trimmed = &self.0[start..];
        trimmed.length()
    }
}

/// Wrapper for fixed-size byte arrays that implements `Encodable`.
#[derive(Debug, Clone)]
struct RlpFixedBytes<const N: usize>([u8; N]);

impl<const N: usize> Encodable for RlpFixedBytes<N> {
    fn encode(&self, out: &mut dyn alloy_rlp::BufMut) {
        self.0.as_slice().encode(out);
    }

    fn length(&self) -> usize {
        self.0.as_slice().length()
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Parses a 0x-prefixed hex address string into the RLP wrapper.
fn parse_to_bytes(address: &str) -> Result<RlpAddress, EthError> {
    let hex_str = address
        .strip_prefix("0x")
        .or_else(|| address.strip_prefix("0X"))
        .ok_or_else(|| {
            EthError::InvalidAddress("address must start with 0x".into())
        })?;

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
    Ok(RlpAddress(addr))
}

/// Validates that a "to" address is well-formed.
fn validate_to_address(address: &str) -> Result<(), EthError> {
    let _ = parse_to_bytes(address)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Well-known test private key (DO NOT use on mainnet).
    const TEST_PRIVKEY: [u8; 32] = {
        let mut key = [0u8; 32];
        key[31] = 1;
        key
    };

    const TEST_ADDRESS: &str = "0x000000000000000000000000000000000000dEaD";

    #[test]
    fn build_transfer_creates_valid_tx() {
        let tx = build_transfer(
            1,
            0,
            TEST_ADDRESS,
            1_000_000_000_000_000_000, // 1 ETH
            1_000_000_000,              // 1 gwei priority
            50_000_000_000,             // 50 gwei max
            21_000,
        )
        .unwrap();

        assert_eq!(tx.chain_id, 1);
        assert_eq!(tx.nonce, 0);
        assert_eq!(tx.gas_limit, 21_000);
        assert_eq!(tx.value, 1_000_000_000_000_000_000);
        assert!(tx.data.is_empty());
    }

    #[test]
    fn build_transfer_invalid_address() {
        let result = build_transfer(1, 0, "bad-address", 0, 0, 0, 21_000);
        assert!(result.is_err());
    }

    #[test]
    fn build_erc20_transfer_creates_valid_tx() {
        let token = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"; // USDC
        let mut amount = [0u8; 32];
        amount[31] = 100;

        let tx = build_erc20_transfer(
            1,
            5,
            token,
            TEST_ADDRESS,
            amount,
            1_000_000_000,
            50_000_000_000,
            65_000,
        )
        .unwrap();

        assert_eq!(tx.chain_id, 1);
        assert_eq!(tx.nonce, 5);
        assert_eq!(tx.value, 0);
        assert_eq!(tx.gas_limit, 65_000);
        // Calldata should be 68 bytes: 4 selector + 32 address + 32 amount.
        assert_eq!(tx.data.len(), 68);
        // First 4 bytes should be the transfer selector.
        assert_eq!(&tx.data[..4], &[0xa9, 0x05, 0x9c, 0xbb]);
    }

    #[test]
    fn encode_unsigned_tx_starts_with_type_byte() {
        let tx = build_transfer(1, 0, TEST_ADDRESS, 0, 0, 0, 21_000).unwrap();
        let encoded = encode_unsigned_tx(&tx).unwrap();

        assert_eq!(encoded[0], 0x02, "EIP-1559 type byte must be 0x02");
        assert!(encoded.len() > 1, "encoded tx must have RLP data after type byte");
    }

    #[test]
    fn encode_unsigned_tx_is_deterministic() {
        let tx = build_transfer(
            1,
            42,
            TEST_ADDRESS,
            1_000_000_000,
            100,
            200,
            21_000,
        )
        .unwrap();

        let enc1 = encode_unsigned_tx(&tx).unwrap();
        let enc2 = encode_unsigned_tx(&tx).unwrap();

        assert_eq!(enc1, enc2, "encoding must be deterministic");
    }

    #[test]
    fn sign_transaction_produces_valid_output() {
        let tx = build_transfer(
            1,     // Ethereum mainnet
            0,     // nonce
            TEST_ADDRESS,
            1_000_000_000_000_000_000, // 1 ETH
            1_000_000_000,              // 1 gwei
            50_000_000_000,             // 50 gwei
            21_000,
        )
        .unwrap();

        let signed = sign_transaction(&tx, &TEST_PRIVKEY).unwrap();

        // Raw tx should start with the EIP-1559 type byte.
        assert_eq!(signed.raw_tx[0], 0x02);

        // Tx hash should be a 0x-prefixed 64-char hex string.
        assert!(signed.tx_hash.starts_with("0x"));
        assert_eq!(signed.tx_hash.len(), 66);
    }

    #[test]
    fn sign_transaction_is_deterministic() {
        let tx = build_transfer(1, 0, TEST_ADDRESS, 0, 100, 200, 21_000).unwrap();

        let signed1 = sign_transaction(&tx, &TEST_PRIVKEY).unwrap();
        let signed2 = sign_transaction(&tx, &TEST_PRIVKEY).unwrap();

        assert_eq!(signed1.raw_tx, signed2.raw_tx);
        assert_eq!(signed1.tx_hash, signed2.tx_hash);
    }

    #[test]
    fn sign_transaction_different_nonces_differ() {
        let tx1 = build_transfer(1, 0, TEST_ADDRESS, 0, 100, 200, 21_000).unwrap();
        let tx2 = build_transfer(1, 1, TEST_ADDRESS, 0, 100, 200, 21_000).unwrap();

        let signed1 = sign_transaction(&tx1, &TEST_PRIVKEY).unwrap();
        let signed2 = sign_transaction(&tx2, &TEST_PRIVKEY).unwrap();

        assert_ne!(signed1.raw_tx, signed2.raw_tx);
        assert_ne!(signed1.tx_hash, signed2.tx_hash);
    }

    #[test]
    fn sign_transaction_different_chains_differ() {
        let tx1 = build_transfer(1, 0, TEST_ADDRESS, 0, 100, 200, 21_000).unwrap();
        let tx2 = build_transfer(137, 0, TEST_ADDRESS, 0, 100, 200, 21_000).unwrap();

        let signed1 = sign_transaction(&tx1, &TEST_PRIVKEY).unwrap();
        let signed2 = sign_transaction(&tx2, &TEST_PRIVKEY).unwrap();

        assert_ne!(signed1.raw_tx, signed2.raw_tx);
    }

    #[test]
    fn sign_transaction_invalid_private_key() {
        let tx = build_transfer(1, 0, TEST_ADDRESS, 0, 0, 0, 21_000).unwrap();
        let bad_key = [0u8; 32]; // All zeros is not a valid private key.

        let result = sign_transaction(&tx, &bad_key);
        assert!(result.is_err());
    }

    #[test]
    fn signed_tx_raw_bytes_are_nonempty() {
        let tx = build_transfer(1, 0, TEST_ADDRESS, 0, 0, 0, 21_000).unwrap();
        let signed = sign_transaction(&tx, &TEST_PRIVKEY).unwrap();

        // Should be at least type byte + some RLP + signature.
        assert!(signed.raw_tx.len() > 10);
    }

    #[test]
    fn build_erc20_transfer_invalid_contract() {
        let result = build_erc20_transfer(
            1,
            0,
            "not-an-address",
            TEST_ADDRESS,
            [0u8; 32],
            0,
            0,
            65_000,
        );
        assert!(result.is_err());
    }

    #[test]
    fn build_erc20_transfer_invalid_recipient() {
        let result = build_erc20_transfer(
            1,
            0,
            TEST_ADDRESS,
            "bad",
            [0u8; 32],
            0,
            0,
            65_000,
        );
        assert!(result.is_err());
    }

    #[test]
    fn rlp_u256_zero_encodes_as_empty() {
        let zero = RlpU256([0u8; 32]);
        let mut buf = Vec::new();
        zero.encode(&mut buf);

        // RLP encoding of empty bytes is 0x80.
        assert_eq!(buf, vec![0x80]);
    }

    #[test]
    fn rlp_u256_small_value_encodes_correctly() {
        let mut value = [0u8; 32];
        value[31] = 42;

        let rlp_val = RlpU256(value);
        let mut buf = Vec::new();
        rlp_val.encode(&mut buf);

        // 42 < 0x80, so RLP encodes it as a single byte.
        assert_eq!(buf, vec![42]);
    }

    #[test]
    fn rlp_address_encodes_20_bytes() {
        let addr = RlpAddress([0xdeu8; 20]);
        let mut buf = Vec::new();
        addr.encode(&mut buf);

        // RLP for a 20-byte string: 0x80 + 20 = 0x94 prefix, then the 20 bytes.
        assert_eq!(buf.len(), 21);
        assert_eq!(buf[0], 0x94);
        assert_eq!(&buf[1..], &[0xde; 20]);
    }
}
