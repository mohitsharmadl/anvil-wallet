use crypto_utils::encryption;
use crypto_utils::kdf;
use zeroize::Zeroize;

use crate::error::WalletError;
use crate::types::EncryptedSeed;

/// Encrypt a seed with password using Argon2id + AES-256-GCM.
///
/// This is the Rust-side encryption layer. On iOS, the result is
/// further encrypted by the Secure Enclave (ECIES P-256) before
/// being stored in the Keychain.
///
/// Returns EncryptedSeed with ciphertext and salt.
pub fn encrypt_seed(seed: &[u8], password: &[u8]) -> Result<EncryptedSeed, WalletError> {
    // Generate random salt for Argon2id
    let salt = kdf::generate_salt();

    // Derive encryption key from password
    let mut key = kdf::derive_key(password, &salt)?;

    // Encrypt seed with AES-256-GCM
    let ciphertext = encryption::encrypt(seed, &key)?;

    // Zeroize the derived key immediately
    key.zeroize();

    Ok(EncryptedSeed {
        ciphertext,
        salt: salt.to_vec(),
        se_ciphertext: None, // Set by Swift after SE encryption
    })
}

/// Decrypt a seed with password using Argon2id + AES-256-GCM.
///
/// The caller must zeroize the returned seed bytes when done.
pub fn decrypt_seed(encrypted: &EncryptedSeed, password: &[u8]) -> Result<Vec<u8>, WalletError> {
    let salt: [u8; 16] = encrypted
        .salt
        .as_slice()
        .try_into()
        .map_err(|_| WalletError::DecryptionFailed("Invalid salt length".into()))?;

    // Derive the same key from password + salt
    let mut key = kdf::derive_key(password, &salt)?;

    // Decrypt
    let seed = encryption::decrypt(&encrypted.ciphertext, &key)
        .map_err(|e| WalletError::DecryptionFailed(e.to_string()))?;

    // Zeroize the derived key
    key.zeroize();

    Ok(seed)
}

/// Serialize EncryptedSeed to JSON for storage
pub fn serialize_encrypted_seed(encrypted: &EncryptedSeed) -> Result<String, WalletError> {
    serde_json::to_string(encrypted)
        .map_err(|e| WalletError::Internal(format!("Serialization failed: {e}")))
}

/// Deserialize EncryptedSeed from JSON
pub fn deserialize_encrypted_seed(json: &str) -> Result<EncryptedSeed, WalletError> {
    serde_json::from_str(json)
        .map_err(|e| WalletError::Internal(format!("Deserialization failed: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let seed = [0xDE, 0xAD, 0xBE, 0xEF].repeat(16); // 64 bytes
        let password = b"strong-password-123!";

        let encrypted = encrypt_seed(&seed, password).unwrap();
        assert!(!encrypted.ciphertext.is_empty());
        assert_eq!(encrypted.salt.len(), 16);
        assert!(encrypted.se_ciphertext.is_none());

        let decrypted = decrypt_seed(&encrypted, password).unwrap();
        assert_eq!(decrypted, seed);
    }

    #[test]
    fn test_wrong_password_fails() {
        let seed = vec![0xCA; 32];
        let password = b"correct-password";
        let wrong_password = b"wrong-password";

        let encrypted = encrypt_seed(&seed, password).unwrap();
        let result = decrypt_seed(&encrypted, wrong_password);
        assert!(result.is_err());
    }

    #[test]
    fn test_different_salts_different_ciphertext() {
        let seed = vec![0x42; 64];
        let password = b"same-password";

        let enc1 = encrypt_seed(&seed, password).unwrap();
        let enc2 = encrypt_seed(&seed, password).unwrap();

        // Different random salt + nonce = different ciphertext
        assert_ne!(enc1.ciphertext, enc2.ciphertext);

        // But both decrypt to the same seed
        let dec1 = decrypt_seed(&enc1, password).unwrap();
        let dec2 = decrypt_seed(&enc2, password).unwrap();
        assert_eq!(dec1, dec2);
        assert_eq!(dec1, seed);
    }

    #[test]
    fn test_serialize_deserialize() {
        let seed = vec![0xAB; 32];
        let password = b"test";

        let encrypted = encrypt_seed(&seed, password).unwrap();
        let json = serialize_encrypted_seed(&encrypted).unwrap();
        let deserialized = deserialize_encrypted_seed(&json).unwrap();

        assert_eq!(encrypted.ciphertext, deserialized.ciphertext);
        assert_eq!(encrypted.salt, deserialized.salt);

        // Verify we can still decrypt after round-trip
        let decrypted = decrypt_seed(&deserialized, password).unwrap();
        assert_eq!(decrypted, seed);
    }
}
