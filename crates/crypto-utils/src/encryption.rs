use aes_gcm::aead::{Aead, OsRng};
use aes_gcm::{AeadCore, Aes256Gcm, Key, KeyInit, Nonce};

use crate::error::CryptoError;

/// AES-256-GCM nonce size in bytes.
const NONCE_SIZE: usize = 12;

/// Encrypts `plaintext` using AES-256-GCM with the given 32-byte `key`.
///
/// A random 12-byte nonce is generated and prepended to the ciphertext. The
/// returned vector has the layout: `[nonce (12 bytes) | ciphertext + tag]`.
pub fn encrypt(plaintext: &[u8], key: &[u8; 32]) -> Result<Vec<u8>, CryptoError> {
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    let nonce = Aes256Gcm::generate_nonce(&mut OsRng);

    let ciphertext = cipher
        .encrypt(&nonce, plaintext)
        .map_err(|e| CryptoError::EncryptionFailed(e.to_string()))?;

    let mut output = Vec::with_capacity(NONCE_SIZE + ciphertext.len());
    output.extend_from_slice(&nonce);
    output.extend_from_slice(&ciphertext);

    Ok(output)
}

/// Decrypts data previously encrypted with [`encrypt`].
///
/// Expects `ciphertext_with_nonce` to begin with the 12-byte nonce followed by
/// the ciphertext and authentication tag.
pub fn decrypt(ciphertext_with_nonce: &[u8], key: &[u8; 32]) -> Result<Vec<u8>, CryptoError> {
    if ciphertext_with_nonce.len() < NONCE_SIZE {
        return Err(CryptoError::InvalidInput(format!(
            "ciphertext too short: expected at least {} bytes, got {}",
            NONCE_SIZE,
            ciphertext_with_nonce.len()
        )));
    }

    let (nonce_bytes, ciphertext) = ciphertext_with_nonce.split_at(NONCE_SIZE);
    let nonce = Nonce::from_slice(nonce_bytes);
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));

    cipher
        .decrypt(nonce, ciphertext)
        .map_err(|e| CryptoError::DecryptionFailed(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_key() -> [u8; 32] {
        let mut key = [0u8; 32];
        for (i, byte) in key.iter_mut().enumerate() {
            *byte = i as u8;
        }
        key
    }

    #[test]
    fn encrypt_decrypt_roundtrip() {
        let key = test_key();
        let plaintext = b"hello, crypto wallet!";

        let encrypted = encrypt(plaintext, &key).expect("encryption should succeed");
        let decrypted = decrypt(&encrypted, &key).expect("decryption should succeed");

        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn encrypt_decrypt_empty_plaintext() {
        let key = test_key();
        let plaintext = b"";

        let encrypted = encrypt(plaintext, &key).expect("encryption should succeed");
        let decrypted = decrypt(&encrypted, &key).expect("decryption should succeed");

        assert_eq!(decrypted, plaintext.to_vec());
    }

    #[test]
    fn encrypt_produces_different_ciphertexts() {
        let key = test_key();
        let plaintext = b"determinism check";

        let enc1 = encrypt(plaintext, &key).expect("encryption should succeed");
        let enc2 = encrypt(plaintext, &key).expect("encryption should succeed");

        // Different random nonces produce different outputs.
        assert_ne!(enc1, enc2);
    }

    #[test]
    fn ciphertext_has_nonce_prepended() {
        let key = test_key();
        let plaintext = b"test";

        let encrypted = encrypt(plaintext, &key).expect("encryption should succeed");

        // 12 bytes nonce + ciphertext (plaintext len) + 16 bytes GCM tag
        assert_eq!(encrypted.len(), NONCE_SIZE + plaintext.len() + 16);
    }

    #[test]
    fn decrypt_with_wrong_key_fails() {
        let key = test_key();
        let mut wrong_key = test_key();
        wrong_key[0] ^= 0xff;

        let encrypted = encrypt(b"secret data", &key).expect("encryption should succeed");
        let result = decrypt(&encrypted, &wrong_key);

        assert!(result.is_err());
        match result.unwrap_err() {
            CryptoError::DecryptionFailed(_) => {}
            other => panic!("expected DecryptionFailed, got {:?}", other),
        }
    }

    #[test]
    fn decrypt_with_tampered_ciphertext_fails() {
        let key = test_key();
        let mut encrypted = encrypt(b"tamper test", &key).expect("encryption should succeed");

        // Flip a byte in the ciphertext portion (after the nonce).
        let last = encrypted.len() - 1;
        encrypted[last] ^= 0xff;

        let result = decrypt(&encrypted, &key);
        assert!(result.is_err());
    }

    #[test]
    fn decrypt_too_short_input_fails() {
        let key = test_key();

        let result = decrypt(&[0u8; 5], &key);
        assert!(result.is_err());
        match result.unwrap_err() {
            CryptoError::InvalidInput(msg) => {
                assert!(msg.contains("too short"));
            }
            other => panic!("expected InvalidInput, got {:?}", other),
        }
    }

    #[test]
    fn decrypt_empty_input_fails() {
        let key = test_key();
        let result = decrypt(&[], &key);
        assert!(result.is_err());
    }

    #[test]
    fn encrypt_decrypt_large_payload() {
        let key = test_key();
        let plaintext = vec![0xABu8; 1024 * 64]; // 64 KB

        let encrypted = encrypt(&plaintext, &key).expect("encryption should succeed");
        let decrypted = decrypt(&encrypted, &key).expect("decryption should succeed");

        assert_eq!(decrypted, plaintext);
    }
}
