pub mod address;
pub mod error;
pub mod hd_derivation;
pub mod mnemonic;
pub mod seed_encryption;
pub mod types;

use error::WalletError;
use types::{Chain, DerivedAddress, EncryptedSeed};
use zeroize::Zeroize;

// Include the UniFFI scaffolding
uniffi::include_scaffolding!("wallet_core");

// ─── UniFFI-exported types ───────────────────────────────────────────

/// Encrypted seed data passed across FFI
pub struct EncryptedSeedData {
    pub ciphertext: Vec<u8>,
    pub salt: Vec<u8>,
}

/// UTXO data passed from Swift for Bitcoin transaction signing
pub struct UtxoData {
    pub txid: String,
    pub vout: u32,
    pub amount_sat: u64,
    pub script_pubkey: Vec<u8>,
}

// ─── UniFFI-exported functions ───────────────────────────────────────
// Note: UniFFI passes owned String/Vec<u8> across FFI, so all functions
// accept owned types (not references).

/// Generate a new 24-word BIP-39 mnemonic
pub fn generate_mnemonic() -> Result<String, WalletError> {
    mnemonic::generate_mnemonic()
}

/// Validate a mnemonic phrase
pub fn validate_mnemonic(phrase: String) -> Result<bool, WalletError> {
    mnemonic::validate_mnemonic(&phrase)
}

/// Check if a single word is in the BIP-39 word list
pub fn is_valid_bip39_word(word: String) -> bool {
    mnemonic::is_valid_word(&word)
}

/// Derive an address for a specific chain from mnemonic
pub fn derive_address_from_mnemonic(
    mnemonic_phrase: String,
    passphrase: String,
    chain: Chain,
    account: u32,
    index: u32,
) -> Result<DerivedAddress, WalletError> {
    let mut seed = mnemonic::mnemonic_to_seed(&mnemonic_phrase, &passphrase)?;
    let result = address::derive_address(&seed, chain, account, index);
    seed.zeroize();
    result
}

/// Derive addresses for BTC, ETH, SOL from a mnemonic
pub fn derive_all_addresses_from_mnemonic(
    mnemonic_phrase: String,
    passphrase: String,
    account: u32,
) -> Result<Vec<DerivedAddress>, WalletError> {
    let mut seed = mnemonic::mnemonic_to_seed(&mnemonic_phrase, &passphrase)?;
    let result = address::derive_all_addresses(&seed, account);
    seed.zeroize();
    result
}

/// Encrypt seed with password (Argon2id + AES-256-GCM)
pub fn encrypt_seed_with_password(
    mut seed: Vec<u8>,
    password: String,
) -> Result<EncryptedSeedData, WalletError> {
    let encrypted = seed_encryption::encrypt_seed(&seed, password.as_bytes())?;
    seed.zeroize();
    Ok(EncryptedSeedData {
        ciphertext: encrypted.ciphertext,
        salt: encrypted.salt,
    })
}

/// Decrypt seed with password
pub fn decrypt_seed_with_password(
    ciphertext: Vec<u8>,
    salt: Vec<u8>,
    password: String,
) -> Result<Vec<u8>, WalletError> {
    let encrypted = EncryptedSeed {
        ciphertext,
        salt,
        se_ciphertext: None,
    };
    seed_encryption::decrypt_seed(&encrypted, password.as_bytes())
}

/// Derive seed bytes from mnemonic + passphrase
pub fn mnemonic_to_seed(mnemonic_phrase: String, passphrase: String) -> Result<Vec<u8>, WalletError> {
    mnemonic::mnemonic_to_seed(&mnemonic_phrase, &passphrase)
}

/// Validate an address for a given chain
pub fn validate_address(addr: String, chain: Chain) -> Result<bool, WalletError> {
    address::validate_address(&addr, chain)
}

/// Sign an arbitrary message with EIP-191 personal_sign.
/// Returns 65-byte signature (r + s + v).
pub fn sign_eth_message(
    mut seed: Vec<u8>,
    account: u32,
    index: u32,
    message: Vec<u8>,
) -> Result<Vec<u8>, WalletError> {
    let key = hd_derivation::derive_secp256k1_key(&seed, Chain::Ethereum, account, index)?;
    let sig = chain_eth::transaction::sign_message(&message, &key.private_key)
        .map_err(|e| WalletError::TransactionFailed(e.to_string()))?;
    seed.zeroize();
    Ok(sig)
}

/// Sign an Ethereum EIP-1559 transaction
pub fn sign_eth_transaction(
    mut seed: Vec<u8>,
    _passphrase: String,
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
    let key = hd_derivation::derive_secp256k1_key(&seed, Chain::Ethereum, account, index)?;

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
    seed.zeroize();
    Ok(signed.raw_tx)
}

/// Sign a Solana SOL transfer
pub fn sign_sol_transfer(
    mut seed: Vec<u8>,
    account: u32,
    to_address: String,
    lamports: u64,
    recent_blockhash: Vec<u8>,
) -> Result<Vec<u8>, WalletError> {
    let key = hd_derivation::derive_ed25519_key(&seed, Chain::Solana, account)?;

    let to_bytes = chain_sol::address::address_to_bytes(&to_address)?;
    let blockhash: [u8; 32] = recent_blockhash
        .as_slice()
        .try_into()
        .map_err(|_| WalletError::TransactionFailed("Invalid blockhash length".into()))?;

    let tx = chain_sol::transaction::build_sol_transfer(
        &key.public_key,
        &to_bytes,
        lamports,
        &blockhash,
    )?;

    let signed = chain_sol::transaction::sign_transaction(&tx, &key.private_key)?;
    seed.zeroize();
    Ok(signed)
}

/// Compute Keccak-256 hash (used by WalletConnect CryptoProvider on Swift side)
pub fn keccak256(data: Vec<u8>) -> Vec<u8> {
    use sha3::{Digest, Keccak256};
    Keccak256::digest(&data).to_vec()
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
    mut seed: Vec<u8>,
    account: u32,
    index: u32,
    hash: Vec<u8>,
) -> Result<Vec<u8>, WalletError> {
    if hash.len() != 32 {
        return Err(WalletError::SigningFailed(
            "Hash must be exactly 32 bytes".into(),
        ));
    }
    let key = hd_derivation::derive_secp256k1_key(&seed, Chain::Ethereum, account, index)?;
    let hash_arr: [u8; 32] = hash.as_slice().try_into().unwrap();
    let sig = chain_eth::transaction::sign_raw_hash(&hash_arr, &key.private_key)
        .map_err(|e| WalletError::SigningFailed(e.to_string()))?;
    seed.zeroize();
    Ok(sig)
}

/// Sign an ERC-20 token transfer on any EVM chain
pub fn sign_erc20_transfer(
    mut seed: Vec<u8>,
    _passphrase: String,
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
    let key = hd_derivation::derive_secp256k1_key(&seed, Chain::Ethereum, account, index)?;

    // Parse amount as big-endian [u8; 32] uint256
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
    seed.zeroize();
    Ok(signed.raw_tx)
}

/// Sign an SPL token transfer on Solana
pub fn sign_spl_transfer(
    mut seed: Vec<u8>,
    account: u32,
    to_address: String,
    mint_address: String,
    amount: u64,
    decimals: u8,
    recent_blockhash: Vec<u8>,
) -> Result<Vec<u8>, WalletError> {
    let key = hd_derivation::derive_ed25519_key(&seed, Chain::Solana, account)?;

    let to_bytes = chain_sol::address::address_to_bytes(&to_address)?;
    let mint_bytes = chain_sol::address::address_to_bytes(&mint_address)?;
    let blockhash: [u8; 32] = recent_blockhash
        .as_slice()
        .try_into()
        .map_err(|_| WalletError::TransactionFailed("Invalid blockhash length".into()))?;

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

    let signed = chain_sol::transaction::sign_transaction(&tx, &key.private_key)?;
    seed.zeroize();
    Ok(signed)
}

/// Sign an arbitrary message with the Solana Ed25519 key.
/// Used by WalletConnect `solana_signMessage` — signs raw bytes, returns 64-byte Ed25519 signature.
pub fn sign_sol_message(
    mut seed: Vec<u8>,
    account: u32,
    message: Vec<u8>,
) -> Result<Vec<u8>, WalletError> {
    use ed25519_dalek::Signer;

    let key = hd_derivation::derive_ed25519_key(&seed, Chain::Solana, account)?;

    let mut private_key = key.private_key;
    let signing_key = ed25519_dalek::SigningKey::from_bytes(&private_key);
    private_key.zeroize();

    let signature = signing_key.sign(&message);
    seed.zeroize();
    Ok(signature.to_bytes().to_vec())
}

/// Sign a pre-built Solana transaction (e.g. from Jupiter or WalletConnect).
/// Takes raw transaction bytes and signs with the wallet's Ed25519 key.
/// Returns the signed transaction bytes ready for submission.
pub fn sign_sol_raw_transaction(
    mut seed: Vec<u8>,
    account: u32,
    raw_tx: Vec<u8>,
) -> Result<Vec<u8>, WalletError> {
    let key = hd_derivation::derive_ed25519_key(&seed, Chain::Solana, account)?;

    let signed = chain_sol::transaction::sign_sol_raw_transaction(&key.private_key, &raw_tx)?;
    seed.zeroize();
    Ok(signed)
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

/// Zcash UTXO data passed from Swift for transaction signing
pub struct ZecUtxoData {
    pub txid: String,
    pub vout: u32,
    pub amount_zatoshi: u64,
    pub script_pubkey: Vec<u8>,
}

/// Sign a Zcash transparent P2PKH transaction (v5 format with ZIP-244 sighash)
pub fn sign_zec_transaction(
    mut seed: Vec<u8>,
    account: u32,
    index: u32,
    utxos: Vec<ZecUtxoData>,
    recipient_address: String,
    amount_zatoshi: u64,
    change_address: String,
    fee_rate_zat_byte: u64,
    expiry_height: u32,
    is_testnet: bool,
) -> Result<Vec<u8>, WalletError> {
    let chain = if is_testnet { Chain::ZcashTestnet } else { Chain::Zcash };
    let network = if is_testnet {
        chain_zec::address::ZecNetwork::Testnet
    } else {
        chain_zec::address::ZecNetwork::Mainnet
    };

    let key = hd_derivation::derive_secp256k1_key(&seed, chain, account, index)?;

    let zec_utxos: Vec<chain_zec::transaction::ZecUtxo> = utxos
        .into_iter()
        .map(|u| chain_zec::transaction::ZecUtxo {
            txid: u.txid,
            vout: u.vout,
            amount_zatoshi: u.amount_zatoshi,
            script_pubkey: u.script_pubkey,
        })
        .collect();

    let unsigned_tx = chain_zec::transaction::build_transparent_transaction(
        &zec_utxos,
        &recipient_address,
        amount_zatoshi,
        &change_address,
        fee_rate_zat_byte,
        network,
        expiry_height,
    )?;

    let signed_bytes = chain_zec::transaction::sign_transaction(
        &unsigned_tx,
        &key.private_key,
    )?;

    seed.zeroize();
    Ok(signed_bytes)
}

/// Sign a Bitcoin P2WPKH transaction
pub fn sign_btc_transaction(
    mut seed: Vec<u8>,
    account: u32,
    index: u32,
    utxos: Vec<UtxoData>,
    recipient_address: String,
    amount_sat: u64,
    change_address: String,
    fee_rate_sat_vbyte: u64,
    is_testnet: bool,
) -> Result<Vec<u8>, WalletError> {
    let chain = if is_testnet { Chain::BitcoinTestnet } else { Chain::Bitcoin };
    let network = if is_testnet {
        chain_btc::network::BtcNetwork::Testnet
    } else {
        chain_btc::network::BtcNetwork::Mainnet
    };

    let key = hd_derivation::derive_secp256k1_key(&seed, chain, account, index)?;

    // Convert FFI UtxoData to chain_btc Utxo
    let btc_utxos: Vec<chain_btc::utxo::Utxo> = utxos
        .into_iter()
        .map(|u| chain_btc::utxo::Utxo {
            txid: u.txid,
            vout: u.vout,
            amount_sat: u.amount_sat,
            script_pubkey: u.script_pubkey,
        })
        .collect();

    let unsigned_tx = chain_btc::transaction::build_p2wpkh_transaction(
        &btc_utxos,
        &recipient_address,
        amount_sat,
        &change_address,
        fee_rate_sat_vbyte,
        network,
    )?;

    let signed_bytes = chain_btc::transaction::sign_transaction(
        &unsigned_tx,
        &key.private_key,
        network,
    )?;

    seed.zeroize();
    Ok(signed_bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

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
            String::new(),
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
            test_seed(), String::new(), 0, 0, 1, 0,
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48".into(),
            "0x000000000000000000000000000000000000dEaD".into(),
            "0x64".into(), "0x3b9aca00".into(), "0xba43b7400".into(), 65_000,
        ).unwrap();
        let result2 = sign_erc20_transfer(
            test_seed(), String::new(), 0, 0, 1, 0,
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48".into(),
            "0x000000000000000000000000000000000000dEaD".into(),
            "0x64".into(), "0x3b9aca00".into(), "0xba43b7400".into(), 65_000,
        ).unwrap();
        assert_eq!(result1, result2);
    }

    #[test]
    fn sign_erc20_transfer_invalid_contract() {
        let result = sign_erc20_transfer(
            test_seed(), String::new(), 0, 0, 1, 0,
            "not-an-address".into(),
            "0x000000000000000000000000000000000000dEaD".into(),
            "0x64".into(), "0x0".into(), "0x0".into(), 65_000,
        );
        assert!(result.is_err());
    }

    #[test]
    fn sign_erc20_transfer_invalid_recipient() {
        let result = sign_erc20_transfer(
            test_seed(), String::new(), 0, 0, 1, 0,
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48".into(),
            "bad-address".into(),
            "0x64".into(), "0x0".into(), "0x0".into(), 65_000,
        );
        assert!(result.is_err());
    }

    #[test]
    fn sign_erc20_transfer_invalid_amount_hex() {
        let result = sign_erc20_transfer(
            test_seed(), String::new(), 0, 0, 1, 0,
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48".into(),
            "0x000000000000000000000000000000000000dEaD".into(),
            "not-hex".into(), "0x0".into(), "0x0".into(), 65_000,
        );
        assert!(result.is_err());
    }

    #[test]
    fn sign_erc20_transfer_different_chains_differ() {
        let result1 = sign_erc20_transfer(
            test_seed(), String::new(), 0, 0, 1, 0, // Ethereum
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48".into(),
            "0x000000000000000000000000000000000000dEaD".into(),
            "0x64".into(), "0x0".into(), "0x0".into(), 65_000,
        ).unwrap();
        let result2 = sign_erc20_transfer(
            test_seed(), String::new(), 0, 0, 137, 0, // Polygon
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48".into(),
            "0x000000000000000000000000000000000000dEaD".into(),
            "0x64".into(), "0x0".into(), "0x0".into(), 65_000,
        ).unwrap();
        assert_ne!(result1, result2);
    }

    // ─── sign_spl_transfer ──────────────────────────────────────────

    #[test]
    fn sign_spl_transfer_produces_valid_tx() {
        let seed = test_seed();
        // Derive key to get a valid recipient address
        let key = hd_derivation::derive_ed25519_key(&seed, Chain::Solana, 0).unwrap();
        let _sender_addr = chain_sol::address::bytes_to_address(&key.public_key);

        // Use a different "recipient" — just use a fixed pubkey
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
