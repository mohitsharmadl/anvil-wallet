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
