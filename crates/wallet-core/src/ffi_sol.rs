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

/// Sign a Solana SOL transfer
pub fn sign_sol_transfer(
    seed: Vec<u8>,
    account: u32,
    to_address: String,
    lamports: u64,
    recent_blockhash: Vec<u8>,
) -> Result<Vec<u8>, WalletError> {
    let to_bytes = chain_sol::address::address_to_bytes(&to_address)?;
    let blockhash: [u8; 32] = recent_blockhash
        .as_slice()
        .try_into()
        .map_err(|_| WalletError::TransactionFailed("Invalid blockhash length".into()))?;

    with_zeroized_seed(seed, |s| {
        let key = hd_derivation::derive_ed25519_key(s, Chain::Solana, account)?;

        let tx = chain_sol::transaction::build_sol_transfer(
            &key.public_key,
            &to_bytes,
            lamports,
            &blockhash,
        )?;

        Ok(chain_sol::transaction::sign_transaction(&tx, &key.private_key)?)
    })
}

/// Sign an SPL token transfer on Solana
pub fn sign_spl_transfer(
    seed: Vec<u8>,
    account: u32,
    to_address: String,
    mint_address: String,
    amount: u64,
    decimals: u8,
    recent_blockhash: Vec<u8>,
) -> Result<Vec<u8>, WalletError> {
    let to_bytes = chain_sol::address::address_to_bytes(&to_address)?;
    let mint_bytes = chain_sol::address::address_to_bytes(&mint_address)?;
    let blockhash: [u8; 32] = recent_blockhash
        .as_slice()
        .try_into()
        .map_err(|_| WalletError::TransactionFailed("Invalid blockhash length".into()))?;

    with_zeroized_seed(seed, |s| {
        let key = hd_derivation::derive_ed25519_key(s, Chain::Solana, account)?;

        // Derive ATAs for sender and recipient
        let sender_ata = chain_sol::spl_token::derive_associated_token_address(
            &key.public_key,
            &mint_bytes,
        )?;
        let recipient_ata = chain_sol::spl_token::derive_associated_token_address(
            &to_bytes,
            &mint_bytes,
        )?;

        // Build SPL transfer instruction
        let spl_ix = chain_sol::spl_token::build_spl_transfer(
            &sender_ata,
            &recipient_ata,
            &key.public_key,
            amount,
            decimals,
        )?;

        // Compile into a transaction with the sender as fee payer
        let tx = chain_sol::transaction::compile_transaction(
            &[spl_ix],
            &key.public_key,
            &blockhash,
        )?;

        Ok(chain_sol::transaction::sign_transaction(&tx, &key.private_key)?)
    })
}

/// Sign an arbitrary message with the Solana Ed25519 key.
/// Used by WalletConnect `solana_signMessage` -- signs raw bytes, returns 64-byte Ed25519 signature.
pub fn sign_sol_message(
    seed: Vec<u8>,
    account: u32,
    message: Vec<u8>,
) -> Result<Vec<u8>, WalletError> {
    use ed25519_dalek::Signer;

    with_zeroized_seed(seed, |s| {
        let key = hd_derivation::derive_ed25519_key(s, Chain::Solana, account)?;

        let mut private_key = key.private_key;
        let signing_key = ed25519_dalek::SigningKey::from_bytes(&private_key);
        private_key.zeroize();

        let signature = signing_key.sign(&message);
        Ok(signature.to_bytes().to_vec())
    })
}

/// Sign a pre-built Solana transaction (e.g. from Jupiter or WalletConnect).
/// Takes raw transaction bytes and signs with the wallet's Ed25519 key.
/// Returns the signed transaction bytes ready for submission.
pub fn sign_sol_raw_transaction(
    seed: Vec<u8>,
    account: u32,
    raw_tx: Vec<u8>,
) -> Result<Vec<u8>, WalletError> {
    with_zeroized_seed(seed, |s| {
        let key = hd_derivation::derive_ed25519_key(s, Chain::Solana, account)?;
        Ok(chain_sol::transaction::sign_sol_raw_transaction(&key.private_key, &raw_tx)?)
    })
}

/// Derive the associated token account address for a wallet + mint pair
pub fn derive_sol_token_address(
    wallet_address: String,
    mint_address: String,
) -> Result<String, WalletError> {
    let wallet_bytes = chain_sol::address::address_to_bytes(&wallet_address)?;
    let mint_bytes = chain_sol::address::address_to_bytes(&mint_address)?;

    let ata = chain_sol::spl_token::derive_associated_token_address(
        &wallet_bytes,
        &mint_bytes,
    )?;

    Ok(chain_sol::address::bytes_to_address(&ata))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mnemonic;

    const TEST_MNEMONIC: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    fn test_seed() -> Vec<u8> {
        mnemonic::mnemonic_to_seed(TEST_MNEMONIC, "").unwrap()
    }

    // ─── sign_spl_transfer ──────────────────────────────────────────

    #[test]
    fn sign_spl_transfer_produces_valid_tx() {
        let seed = test_seed();
        // Derive key to get a valid recipient address
        let key = hd_derivation::derive_ed25519_key(&seed, Chain::Solana, 0).unwrap();
        let _sender_addr = chain_sol::address::bytes_to_address(&key.public_key);

        // Use a different "recipient" -- just use a fixed pubkey
        let recipient = "11111111111111111111111111111112"; // not system program, just 31 zeros + 1

        // USDC mint on Solana
        let usdc_mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";

        let blockhash = vec![0xAA; 32];

        let result = sign_spl_transfer(
            test_seed(),
            0,
            recipient.into(),
            usdc_mint.into(),
            1_000_000, // 1 USDC (6 decimals)
            6,
            blockhash,
        );
        assert!(result.is_ok());
        let tx_bytes = result.unwrap();
        // Wire format starts with compact-u16 num_signatures = 1
        assert_eq!(tx_bytes[0], 0x01);
        assert!(tx_bytes.len() > 65); // at least signature + message
    }

    #[test]
    fn sign_spl_transfer_deterministic() {
        let blockhash = vec![0xBB; 32];
        let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
        let recipient = "11111111111111111111111111111112";

        let result1 = sign_spl_transfer(
            test_seed(), 0, recipient.into(), mint.into(),
            500_000, 6, blockhash.clone(),
        ).unwrap();
        let result2 = sign_spl_transfer(
            test_seed(), 0, recipient.into(), mint.into(),
            500_000, 6, blockhash,
        ).unwrap();
        assert_eq!(result1, result2);
    }

    #[test]
    fn sign_spl_transfer_zero_amount_fails() {
        let result = sign_spl_transfer(
            test_seed(), 0,
            "11111111111111111111111111111112".into(),
            "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v".into(),
            0, 6, vec![0u8; 32],
        );
        assert!(result.is_err());
    }

    #[test]
    fn sign_spl_transfer_invalid_recipient() {
        let result = sign_spl_transfer(
            test_seed(), 0,
            "###invalid###".into(),
            "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v".into(),
            1_000_000, 6, vec![0u8; 32],
        );
        assert!(result.is_err());
    }

    #[test]
    fn sign_spl_transfer_invalid_mint() {
        let result = sign_spl_transfer(
            test_seed(), 0,
            "11111111111111111111111111111112".into(),
            "not-a-mint".into(),
            1_000_000, 6, vec![0u8; 32],
        );
        assert!(result.is_err());
    }

    #[test]
    fn sign_spl_transfer_invalid_blockhash_length() {
        let result = sign_spl_transfer(
            test_seed(), 0,
            "11111111111111111111111111111112".into(),
            "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v".into(),
            1_000_000, 6, vec![0u8; 16], // wrong length
        );
        assert!(result.is_err());
    }

    // ─── derive_sol_token_address ───────────────────────────────────

    #[test]
    fn derive_sol_token_address_returns_valid_address() {
        let seed = test_seed();
        let key = hd_derivation::derive_ed25519_key(&seed, Chain::Solana, 0).unwrap();
        let wallet = chain_sol::address::bytes_to_address(&key.public_key);
        let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";

        let ata = derive_sol_token_address(wallet, mint.into()).unwrap();

        // Should be a valid Solana address
        assert!(chain_sol::address::validate_address(&ata).is_ok());
    }

    #[test]
    fn derive_sol_token_address_deterministic() {
        let wallet = "11111111111111111111111111111112";
        let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";

        let ata1 = derive_sol_token_address(wallet.into(), mint.into()).unwrap();
        let ata2 = derive_sol_token_address(wallet.into(), mint.into()).unwrap();
        assert_eq!(ata1, ata2);
    }

    #[test]
    fn derive_sol_token_address_different_wallets_differ() {
        let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
        let ata1 = derive_sol_token_address(
            "11111111111111111111111111111112".into(), mint.into(),
        ).unwrap();
        let ata2 = derive_sol_token_address(
            "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA".into(), mint.into(),
        ).unwrap();
        assert_ne!(ata1, ata2);
    }

    #[test]
    fn derive_sol_token_address_different_mints_differ() {
        let wallet = "11111111111111111111111111111112";
        let ata1 = derive_sol_token_address(
            wallet.into(), "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v".into(),
        ).unwrap();
        let ata2 = derive_sol_token_address(
            wallet.into(), "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA".into(),
        ).unwrap();
        assert_ne!(ata1, ata2);
    }

    #[test]
    fn derive_sol_token_address_invalid_wallet() {
        let result = derive_sol_token_address(
            "###invalid###".into(),
            "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v".into(),
        );
        assert!(result.is_err());
    }

    #[test]
    fn derive_sol_token_address_invalid_mint() {
        let result = derive_sol_token_address(
            "11111111111111111111111111111112".into(),
            "not-a-mint".into(),
        );
        assert!(result.is_err());
    }

    // ─── sign_sol_message ───────────────────────────────────────────────

    #[test]
    fn sign_sol_message_returns_64_bytes() {
        let seed = test_seed();
        let msg = b"Hello, Solana!".to_vec();
        let sig = sign_sol_message(seed, 0, msg).unwrap();
        assert_eq!(sig.len(), 64);
    }

    #[test]
    fn sign_sol_message_deterministic() {
        let msg = b"test message".to_vec();
        let sig1 = sign_sol_message(test_seed(), 0, msg.clone()).unwrap();
        let sig2 = sign_sol_message(test_seed(), 0, msg).unwrap();
        assert_eq!(sig1, sig2);
    }

    #[test]
    fn sign_sol_message_verifies() {
        use ed25519_dalek::{Signature, VerifyingKey};

        let seed = test_seed();
        let key = hd_derivation::derive_ed25519_key(&seed, Chain::Solana, 0).unwrap();
        let msg = b"verify me".to_vec();
        let sig_bytes = sign_sol_message(test_seed(), 0, msg.clone()).unwrap();

        let sig = Signature::from_bytes(sig_bytes.as_slice().try_into().unwrap());
        let vk = VerifyingKey::from_bytes(&key.public_key).unwrap();
        assert!(vk.verify_strict(&msg, &sig).is_ok());
    }

    #[test]
    fn sign_sol_message_different_accounts_differ() {
        let msg = b"same message".to_vec();
        let sig0 = sign_sol_message(test_seed(), 0, msg.clone()).unwrap();
        let sig1 = sign_sol_message(test_seed(), 1, msg).unwrap();
        assert_ne!(sig0, sig1);
    }

    #[test]
    fn sign_sol_message_empty_message() {
        let sig = sign_sol_message(test_seed(), 0, vec![]).unwrap();
        assert_eq!(sig.len(), 64);
    }

    // ─── sign_sol_raw_transaction ──────────────────────────────────────

    #[test]
    fn sign_sol_raw_transaction_roundtrip() {
        let seed = test_seed();
        let key = hd_derivation::derive_ed25519_key(&seed, Chain::Solana, 0).unwrap();

        let to = [0xBBu8; 32];
        let blockhash = [0xCC; 32];

        // Build a normal SOL transfer and sign it.
        let tx = chain_sol::transaction::build_sol_transfer(
            &key.public_key, &to, 1_000_000, &blockhash,
        ).unwrap();
        let wire_normal = chain_sol::transaction::sign_transaction(&tx, &key.private_key).unwrap();

        // Zero out the signature to simulate an unsigned raw tx from a dApp.
        let mut raw_unsigned = wire_normal.clone();
        for b in &mut raw_unsigned[1..65] {
            *b = 0;
        }

        // Sign via the FFI function.
        let wire_raw = sign_sol_raw_transaction(test_seed(), 0, raw_unsigned).unwrap();

        // Should produce the exact same signed transaction.
        assert_eq!(wire_normal, wire_raw);
    }

    #[test]
    fn sign_sol_raw_transaction_deterministic() {
        let seed = test_seed();
        let key = hd_derivation::derive_ed25519_key(&seed, Chain::Solana, 0).unwrap();

        let to = [0xBBu8; 32];
        let blockhash = [0xAA; 32];

        let tx = chain_sol::transaction::build_sol_transfer(
            &key.public_key, &to, 500, &blockhash,
        ).unwrap();
        let wire = chain_sol::transaction::sign_transaction(&tx, &key.private_key).unwrap();

        let mut raw = wire;
        for b in &mut raw[1..65] {
            *b = 0;
        }

        let signed1 = sign_sol_raw_transaction(test_seed(), 0, raw.clone()).unwrap();
        let signed2 = sign_sol_raw_transaction(test_seed(), 0, raw).unwrap();
        assert_eq!(signed1, signed2);
    }

    #[test]
    fn sign_sol_raw_transaction_wrong_account_fails() {
        let seed = test_seed();
        let key = hd_derivation::derive_ed25519_key(&seed, Chain::Solana, 0).unwrap();

        let to = [0xBBu8; 32];
        let blockhash = [0xCC; 32];

        let tx = chain_sol::transaction::build_sol_transfer(
            &key.public_key, &to, 1000, &blockhash,
        ).unwrap();
        let wire = chain_sol::transaction::sign_transaction(&tx, &key.private_key).unwrap();

        // Use account=1 (different key) -- should fail.
        let result = sign_sol_raw_transaction(test_seed(), 1, wire);
        assert!(result.is_err());
    }

    #[test]
    fn sign_sol_raw_transaction_empty_tx_fails() {
        let result = sign_sol_raw_transaction(test_seed(), 0, vec![]);
        assert!(result.is_err());
    }

    #[test]
    fn sign_sol_raw_transaction_truncated_tx_fails() {
        let result = sign_sol_raw_transaction(test_seed(), 0, vec![0x01, 0x00]);
        assert!(result.is_err());
    }
}
