use crate::error::WalletError;
use crate::hd_derivation;
use crate::types::Chain;
use zeroize::Zeroize;

/// Execute a closure with the seed, guaranteeing zeroization on both success and error paths.
fn with_zeroized_seed<F, T>(mut seed: Vec<u8>, f: F) -> Result<T, WalletError>
where
    F: FnOnce(&[u8]) -> Result<T, WalletError>,
{
    let result = f(&seed);
    seed.zeroize();
    result
}

/// Sign an arbitrary message with EIP-191 personal_sign.
/// Returns 65-byte signature (r + s + v).
pub fn sign_eth_message(
    seed: Vec<u8>,
    account: u32,
    index: u32,
    message: Vec<u8>,
) -> Result<Vec<u8>, WalletError> {
    with_zeroized_seed(seed, |s| {
        let key = hd_derivation::derive_secp256k1_key(s, Chain::Ethereum, account, index)?;
        chain_eth::transaction::sign_message(&message, &key.private_key)
            .map_err(|e| WalletError::TransactionFailed(e.to_string()))
    })
}

/// Sign an Ethereum EIP-1559 transaction
pub fn sign_eth_transaction(
    seed: Vec<u8>,
    account: u32,
    index: u32,
    chain_id: u64,
    nonce: u64,
    to_address: String,
    value_wei_hex: String,
    data: Vec<u8>,
    max_priority_fee_hex: String,
    max_fee_hex: String,
    gas_limit: u64,
) -> Result<Vec<u8>, WalletError> {
    with_zeroized_seed(seed, |s| {
        let key = hd_derivation::derive_secp256k1_key(s, Chain::Ethereum, account, index)?;

        let value_wei = u128::from_str_radix(value_wei_hex.trim_start_matches("0x"), 16)
            .map_err(|e| WalletError::TransactionFailed(format!("Invalid value: {e}")))?;
        let max_priority_fee = u128::from_str_radix(max_priority_fee_hex.trim_start_matches("0x"), 16)
            .map_err(|e| WalletError::TransactionFailed(format!("Invalid priority fee: {e}")))?;
        let max_fee = u128::from_str_radix(max_fee_hex.trim_start_matches("0x"), 16)
            .map_err(|e| WalletError::TransactionFailed(format!("Invalid max fee: {e}")))?;

        let tx = if data.is_empty() {
            chain_eth::transaction::build_transfer(
                chain_id,
                nonce,
                &to_address,
                value_wei,
                max_priority_fee,
                max_fee,
                gas_limit,
            )?
        } else {
            let mut tx = chain_eth::transaction::build_transfer(
                chain_id,
                nonce,
                &to_address,
                value_wei,
                max_priority_fee,
                max_fee,
                gas_limit,
            )?;
            tx.data = data;
            tx
        };

        let signed = chain_eth::transaction::sign_transaction(&tx, &key.private_key)?;
        Ok(signed.raw_tx)
    })
}

/// Recover uncompressed secp256k1 public key from a 65-byte signature + 32-byte message hash.
/// Returns 65-byte uncompressed public key (0x04 || x || y).
pub fn recover_eth_pubkey(signature: Vec<u8>, message_hash: Vec<u8>) -> Result<Vec<u8>, WalletError> {
    use k256::ecdsa::{RecoveryId, Signature, VerifyingKey};

    if signature.len() != 65 {
        return Err(WalletError::SigningFailed("Signature must be 65 bytes".into()));
    }
    if message_hash.len() != 32 {
        return Err(WalletError::SigningFailed("Message hash must be 32 bytes".into()));
    }

    let r_s = &signature[..64];
    let v = signature[64];
    let recovery_id = if v >= 27 { v - 27 } else { v };

    let sig = Signature::from_slice(r_s)
        .map_err(|e| WalletError::SigningFailed(format!("Invalid signature: {e}")))?;
    let recid = RecoveryId::from_byte(recovery_id)
        .ok_or_else(|| WalletError::SigningFailed("Invalid recovery ID".into()))?;

    let recovered_key = VerifyingKey::recover_from_prehash(&message_hash, &sig, recid)
        .map_err(|e| WalletError::SigningFailed(format!("Recovery failed: {e}")))?;

    Ok(recovered_key.to_encoded_point(false).as_bytes().to_vec())
}

/// Sign a raw 32-byte hash with the Ethereum private key (no EIP-191 prefix).
/// Used for EIP-712 typed data signing where the caller computes the final hash.
pub fn sign_eth_raw_hash(
    seed: Vec<u8>,
    account: u32,
    index: u32,
    hash: Vec<u8>,
) -> Result<Vec<u8>, WalletError> {
    if hash.len() != 32 {
        return Err(WalletError::SigningFailed(
            "Hash must be exactly 32 bytes".into(),
        ));
    }
    with_zeroized_seed(seed, |s| {
        let key = hd_derivation::derive_secp256k1_key(s, Chain::Ethereum, account, index)?;
        let hash_arr: [u8; 32] = hash.as_slice().try_into().unwrap();
        chain_eth::transaction::sign_raw_hash(&hash_arr, &key.private_key)
            .map_err(|e| WalletError::SigningFailed(e.to_string()))
    })
}

/// Sign an ERC-20 token transfer on any EVM chain
pub fn sign_erc20_transfer(
    seed: Vec<u8>,
    account: u32,
    index: u32,
    chain_id: u64,
    nonce: u64,
    token_contract: String,
    to_address: String,
    amount_hex: String,
    max_priority_fee_hex: String,
    max_fee_hex: String,
    gas_limit: u64,
) -> Result<Vec<u8>, WalletError> {
    // Parse amount as big-endian [u8; 32] uint256 (before entering closure to avoid seed leak on parse error)
    let amount_str = amount_hex.trim_start_matches("0x");
    // Left-pad odd-length hex to even length (e.g. "f4240" -> "0f4240")
    let padded = if amount_str.len() % 2 != 0 {
        format!("0{amount_str}")
    } else {
        amount_str.to_string()
    };
    let amount_bytes = hex::decode(&padded)
        .map_err(|e| WalletError::TransactionFailed(format!("Invalid amount hex: {e}")))?;
    if amount_bytes.len() > 32 {
        return Err(WalletError::TransactionFailed("Amount exceeds uint256".into()));
    }
    let mut amount = [0u8; 32];
    amount[32 - amount_bytes.len()..].copy_from_slice(&amount_bytes);

    with_zeroized_seed(seed, |s| {
        let key = hd_derivation::derive_secp256k1_key(s, Chain::Ethereum, account, index)?;

        let max_priority_fee = u128::from_str_radix(max_priority_fee_hex.trim_start_matches("0x"), 16)
            .map_err(|e| WalletError::TransactionFailed(format!("Invalid priority fee: {e}")))?;
        let max_fee = u128::from_str_radix(max_fee_hex.trim_start_matches("0x"), 16)
            .map_err(|e| WalletError::TransactionFailed(format!("Invalid max fee: {e}")))?;

        let tx = chain_eth::transaction::build_erc20_transfer(
            chain_id,
            nonce,
            &token_contract,
            &to_address,
            amount,
            max_priority_fee,
            max_fee,
            gas_limit,
        )?;

        let signed = chain_eth::transaction::sign_transaction(&tx, &key.private_key)?;
        Ok(signed.raw_tx)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mnemonic;

    const TEST_MNEMONIC: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    fn test_seed() -> Vec<u8> {
        mnemonic::mnemonic_to_seed(TEST_MNEMONIC, "").unwrap()
    }

    // ─── sign_eth_raw_hash ───────────────────────────────────────────

    #[test]
    fn sign_eth_raw_hash_produces_65_byte_signature() {
        let seed = test_seed();
        let hash = vec![0xAA; 32];
        let sig = sign_eth_raw_hash(seed, 0, 0, hash).unwrap();
        assert_eq!(sig.len(), 65);
        // v should be 27 or 28
        assert!(sig[64] == 27 || sig[64] == 28);
    }

    #[test]
    fn sign_eth_raw_hash_deterministic() {
        let hash = vec![0xBB; 32];
        let sig1 = sign_eth_raw_hash(test_seed(), 0, 0, hash.clone()).unwrap();
        let sig2 = sign_eth_raw_hash(test_seed(), 0, 0, hash).unwrap();
        assert_eq!(sig1, sig2);
    }

    #[test]
    fn sign_eth_raw_hash_wrong_length_fails() {
        assert!(sign_eth_raw_hash(test_seed(), 0, 0, vec![0u8; 16]).is_err());
        assert!(sign_eth_raw_hash(test_seed(), 0, 0, vec![0u8; 64]).is_err());
    }

    #[test]
    fn sign_eth_raw_hash_differs_from_personal_sign() {
        // The same data should produce different signatures because personal_sign
        // adds the EIP-191 prefix before hashing, while raw_hash signs directly.
        let data = vec![0xCC; 32];
        let raw_sig = sign_eth_raw_hash(test_seed(), 0, 0, data.clone()).unwrap();
        let personal_sig = sign_eth_message(test_seed(), 0, 0, data).unwrap();
        assert_ne!(raw_sig, personal_sig);
    }

    // ─── sign_erc20_transfer ────────────────────────────────────────

    #[test]
    fn sign_erc20_transfer_produces_valid_tx() {
        let seed = test_seed();
        let result = sign_erc20_transfer(
            seed,
            0,
            0,
            1, // Ethereum mainnet
            0,
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48".into(), // USDC
            "0x000000000000000000000000000000000000dEaD".into(),
            "0x64".into(), // 100
            "0x3b9aca00".into(), // 1 gwei
            "0xba43b7400".into(), // 50 gwei
            65_000,
        );
        assert!(result.is_ok());
        let tx_bytes = result.unwrap();
        assert_eq!(tx_bytes[0], 0x02); // EIP-1559 type byte
        assert!(tx_bytes.len() > 10);
    }

    #[test]
    fn sign_erc20_transfer_deterministic() {
        let result1 = sign_erc20_transfer(
            test_seed(), 0, 0, 1, 0,
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48".into(),
            "0x000000000000000000000000000000000000dEaD".into(),
            "0x64".into(), "0x3b9aca00".into(), "0xba43b7400".into(), 65_000,
        ).unwrap();
        let result2 = sign_erc20_transfer(
            test_seed(), 0, 0, 1, 0,
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48".into(),
            "0x000000000000000000000000000000000000dEaD".into(),
            "0x64".into(), "0x3b9aca00".into(), "0xba43b7400".into(), 65_000,
        ).unwrap();
        assert_eq!(result1, result2);
    }

    #[test]
    fn sign_erc20_transfer_invalid_contract() {
        let result = sign_erc20_transfer(
            test_seed(), 0, 0, 1, 0,
            "not-an-address".into(),
            "0x000000000000000000000000000000000000dEaD".into(),
            "0x64".into(), "0x0".into(), "0x0".into(), 65_000,
        );
        assert!(result.is_err());
    }

    #[test]
    fn sign_erc20_transfer_invalid_recipient() {
        let result = sign_erc20_transfer(
            test_seed(), 0, 0, 1, 0,
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48".into(),
            "bad-address".into(),
            "0x64".into(), "0x0".into(), "0x0".into(), 65_000,
        );
        assert!(result.is_err());
    }

    #[test]
    fn sign_erc20_transfer_invalid_amount_hex() {
        let result = sign_erc20_transfer(
            test_seed(), 0, 0, 1, 0,
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48".into(),
            "0x000000000000000000000000000000000000dEaD".into(),
            "not-hex".into(), "0x0".into(), "0x0".into(), 65_000,
        );
        assert!(result.is_err());
    }

    #[test]
    fn sign_erc20_transfer_different_chains_differ() {
        let result1 = sign_erc20_transfer(
            test_seed(), 0, 0, 1, 0, // Ethereum
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48".into(),
            "0x000000000000000000000000000000000000dEaD".into(),
            "0x64".into(), "0x0".into(), "0x0".into(), 65_000,
        ).unwrap();
        let result2 = sign_erc20_transfer(
            test_seed(), 0, 0, 137, 0, // Polygon
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48".into(),
            "0x000000000000000000000000000000000000dEaD".into(),
            "0x64".into(), "0x0".into(), "0x0".into(), 65_000,
        ).unwrap();
        assert_ne!(result1, result2);
    }
}
