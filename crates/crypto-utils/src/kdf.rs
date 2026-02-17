use argon2::{Algorithm, Argon2, Params, Version};

use crate::error::CryptoError;
use crate::random::random_bytes_fixed;

/// Derives a 32-byte key from `password` and `salt` using Argon2id.
///
/// Parameters:
/// - Memory: 65536 KiB (64 MB)
/// - Iterations: 3
/// - Parallelism: 4
/// - Output length: 32 bytes (suitable for AES-256)
pub fn derive_key(password: &[u8], salt: &[u8; 16]) -> Result<[u8; 32], CryptoError> {
    let params = Params::new(65536, 3, 4, Some(32))
        .map_err(|e| CryptoError::KdfFailed(format!("invalid argon2 params: {e}")))?;

    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);

    let mut output = [0u8; 32];
    argon2
        .hash_password_into(password, salt, &mut output)
        .map_err(|e| CryptoError::KdfFailed(format!("argon2 hash failed: {e}")))?;

    Ok(output)
}

/// Generates a cryptographically secure random 16-byte salt.
pub fn generate_salt() -> [u8; 16] {
    random_bytes_fixed::<16>()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derive_key_produces_32_bytes() {
        let salt = generate_salt();
        let key = derive_key(b"password123", &salt).expect("kdf should succeed");
        assert_eq!(key.len(), 32);
    }

    #[test]
    fn derive_key_deterministic() {
        let salt = [0xABu8; 16];
        let password = b"my-strong-password";

        let key1 = derive_key(password, &salt).expect("kdf should succeed");
        let key2 = derive_key(password, &salt).expect("kdf should succeed");

        assert_eq!(key1, key2, "same password + salt must produce same key");
    }

    #[test]
    fn derive_key_different_passwords_differ() {
        let salt = [0x01u8; 16];

        let key1 = derive_key(b"password-a", &salt).expect("kdf should succeed");
        let key2 = derive_key(b"password-b", &salt).expect("kdf should succeed");

        assert_ne!(key1, key2);
    }

    #[test]
    fn derive_key_different_salts_differ() {
        let password = b"same-password";

        let salt1 = [0x01u8; 16];
        let salt2 = [0x02u8; 16];

        let key1 = derive_key(password, &salt1).expect("kdf should succeed");
        let key2 = derive_key(password, &salt2).expect("kdf should succeed");

        assert_ne!(key1, key2);
    }

    #[test]
    fn derive_key_empty_password() {
        let salt = [0xCCu8; 16];
        let key = derive_key(b"", &salt).expect("kdf should succeed with empty password");
        assert_eq!(key.len(), 32);
    }

    #[test]
    fn generate_salt_is_16_bytes() {
        let salt = generate_salt();
        assert_eq!(salt.len(), 16);
    }

    #[test]
    fn generate_salt_is_random() {
        let salt1 = generate_salt();
        let salt2 = generate_salt();
        assert_ne!(salt1, salt2, "two random salts should differ");
    }

    #[test]
    fn derive_key_unicode_password() {
        let salt = generate_salt();
        let password = "p@$$w0rd-with-unicode".as_bytes();
        let key = derive_key(password, &salt).expect("kdf should succeed");
        assert_eq!(key.len(), 32);
    }

    #[test]
    fn derive_key_long_password() {
        let salt = generate_salt();
        let password = vec![b'A'; 1024];
        let key = derive_key(&password, &salt).expect("kdf should succeed");
        assert_eq!(key.len(), 32);
    }

    #[test]
    fn full_roundtrip_kdf_then_encrypt_decrypt() {
        use crate::encryption;

        let salt = generate_salt();
        let key = derive_key(b"wallet-password", &salt).expect("kdf should succeed");

        let plaintext = b"private key material";
        let encrypted =
            encryption::encrypt(plaintext, &key).expect("encryption should succeed");
        let decrypted =
            encryption::decrypt(&encrypted, &key).expect("decryption should succeed");

        assert_eq!(decrypted, plaintext);
    }
}
