pub mod address;
pub mod error;
pub mod hd_derivation;
pub mod mnemonic;
pub mod seed_encryption;
pub mod types;

mod ffi_common;
mod ffi_eth;
mod ffi_btc;
mod ffi_sol;
mod ffi_zec;

// Re-export all FFI types and functions so UniFFI sees them at crate root
pub use ffi_common::{EncryptedSeedData, keccak256, validate_address};
pub use ffi_eth::{
    sign_eth_message, sign_eth_transaction, sign_erc20_transfer,
    sign_eth_raw_hash, recover_eth_pubkey,
};
pub use ffi_btc::{UtxoData, sign_btc_transaction};
pub use ffi_sol::{
    sign_sol_transfer, sign_spl_transfer, sign_sol_message,
    sign_sol_raw_transaction, derive_sol_token_address,
};
pub use ffi_zec::{ZecUtxoData, sign_zec_transaction};

use error::WalletError;
use types::{Chain, DerivedAddress, EncryptedSeed};
use zeroize::Zeroize;

// Include the UniFFI scaffolding
uniffi::include_scaffolding!("wallet_core");

// ─── UniFFI-exported functions (mnemonic & encryption) ──────────────

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
    seed: Vec<u8>,
    password: String,
) -> Result<EncryptedSeedData, WalletError> {
    let mut seed = seed;
    let encrypted = seed_encryption::encrypt_seed(&seed, password.as_bytes());
    seed.zeroize();
    let encrypted = encrypted?;
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
