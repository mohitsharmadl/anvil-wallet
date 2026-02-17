use bip39::{Language, Mnemonic};
use rand::RngCore;
use zeroize::Zeroize;

use crate::error::WalletError;

/// Generate a new 24-word BIP-39 mnemonic (256 bits of entropy)
pub fn generate_mnemonic() -> Result<String, WalletError> {
    // 24 words = 256 bits of entropy
    let mut entropy = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut entropy);
    let mnemonic = Mnemonic::from_entropy_in(Language::English, &entropy)
        .map_err(|e| WalletError::InvalidMnemonic(e.to_string()))?;
    entropy.zeroize();
    Ok(mnemonic.to_string())
}

/// Validate a mnemonic phrase
pub fn validate_mnemonic(phrase: &str) -> Result<bool, WalletError> {
    match Mnemonic::parse_in_normalized(Language::English, phrase) {
        Ok(_) => Ok(true),
        Err(_) => Ok(false),
    }
}

/// Derive seed bytes from mnemonic + optional passphrase
/// Returns 64-byte seed. Caller MUST zeroize the returned seed when done.
pub fn mnemonic_to_seed(phrase: &str, passphrase: &str) -> Result<Vec<u8>, WalletError> {
    let mnemonic = Mnemonic::parse_in_normalized(Language::English, phrase)
        .map_err(|e| WalletError::InvalidMnemonic(e.to_string()))?;

    let seed = mnemonic.to_seed(passphrase);
    Ok(seed.to_vec())
}

/// Get the word list for autocomplete
pub fn word_list() -> &'static [&'static str] {
    Language::English.word_list()
}

/// Validate a single word against the BIP-39 word list
pub fn is_valid_word(word: &str) -> bool {
    Language::English.find_word(word).is_some()
}

/// Zeroizable mnemonic wrapper
pub struct ZeroizingMnemonic {
    phrase: String,
}

impl ZeroizingMnemonic {
    pub fn new(phrase: String) -> Result<Self, WalletError> {
        if !validate_mnemonic(&phrase)? {
            return Err(WalletError::InvalidMnemonic("Invalid mnemonic phrase".into()));
        }
        Ok(Self { phrase })
    }

    pub fn as_str(&self) -> &str {
        &self.phrase
    }

    pub fn to_seed(&self, passphrase: &str) -> Result<Vec<u8>, WalletError> {
        mnemonic_to_seed(&self.phrase, passphrase)
    }

    pub fn words(&self) -> Vec<&str> {
        self.phrase.split_whitespace().collect()
    }
}

impl Drop for ZeroizingMnemonic {
    fn drop(&mut self) {
        self.phrase.zeroize();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_mnemonic_24_words() {
        let mnemonic = generate_mnemonic().unwrap();
        let words: Vec<&str> = mnemonic.split_whitespace().collect();
        assert_eq!(words.len(), 24);
    }

    #[test]
    fn test_validate_valid_mnemonic() {
        let mnemonic = generate_mnemonic().unwrap();
        assert!(validate_mnemonic(&mnemonic).unwrap());
    }

    #[test]
    fn test_validate_invalid_mnemonic() {
        assert!(!validate_mnemonic("invalid mnemonic phrase here").unwrap());
    }

    #[test]
    fn test_mnemonic_to_seed_deterministic() {
        // BIP-39 test vector
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let seed1 = mnemonic_to_seed(phrase, "").unwrap();
        let seed2 = mnemonic_to_seed(phrase, "").unwrap();
        assert_eq!(seed1, seed2);
        assert_eq!(seed1.len(), 64);
    }

    #[test]
    fn test_passphrase_changes_seed() {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let seed_no_pass = mnemonic_to_seed(phrase, "").unwrap();
        let seed_with_pass = mnemonic_to_seed(phrase, "mypassphrase").unwrap();
        assert_ne!(seed_no_pass, seed_with_pass);
    }

    #[test]
    fn test_bip39_test_vector() {
        // Official BIP-39 test vector (12 words, no passphrase)
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let seed = mnemonic_to_seed(phrase, "").unwrap();
        let seed_hex = hex::encode(&seed);
        // Known seed for this mnemonic with empty passphrase
        assert_eq!(
            seed_hex,
            "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc1\
             9a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4"
        );
    }

    #[test]
    fn test_is_valid_word() {
        assert!(is_valid_word("abandon"));
        assert!(is_valid_word("zoo"));
        assert!(!is_valid_word("notaword"));
        assert!(!is_valid_word(""));
    }

    #[test]
    fn test_zeroizing_mnemonic() {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let zm = ZeroizingMnemonic::new(phrase.to_string()).unwrap();
        assert_eq!(zm.words().len(), 12);
        let seed = zm.to_seed("").unwrap();
        assert_eq!(seed.len(), 64);
    }
}
