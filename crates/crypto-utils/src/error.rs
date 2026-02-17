use thiserror::Error;

/// Cryptographic operation errors.
#[derive(Debug, Error)]
pub enum CryptoError {
    #[error("encryption failed: {0}")]
    EncryptionFailed(String),

    #[error("decryption failed: {0}")]
    DecryptionFailed(String),

    #[error("key derivation failed: {0}")]
    KdfFailed(String),

    #[error("invalid key length")]
    InvalidKeyLength,

    #[error("invalid input: {0}")]
    InvalidInput(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_encryption_failed() {
        let err = CryptoError::EncryptionFailed("aead seal error".into());
        assert_eq!(err.to_string(), "encryption failed: aead seal error");
    }

    #[test]
    fn display_decryption_failed() {
        let err = CryptoError::DecryptionFailed("tag mismatch".into());
        assert_eq!(err.to_string(), "decryption failed: tag mismatch");
    }

    #[test]
    fn display_kdf_failed() {
        let err = CryptoError::KdfFailed("out of memory".into());
        assert_eq!(err.to_string(), "key derivation failed: out of memory");
    }

    #[test]
    fn display_invalid_key_length() {
        let err = CryptoError::InvalidKeyLength;
        assert_eq!(err.to_string(), "invalid key length");
    }

    #[test]
    fn display_invalid_input() {
        let err = CryptoError::InvalidInput("empty plaintext".into());
        assert_eq!(err.to_string(), "invalid input: empty plaintext");
    }

    #[test]
    fn error_trait_is_implemented() {
        let err: Box<dyn std::error::Error> =
            Box::new(CryptoError::EncryptionFailed("test".into()));
        assert!(err.to_string().contains("test"));
    }

    #[test]
    fn debug_format_works() {
        let err = CryptoError::InvalidKeyLength;
        let debug = format!("{:?}", err);
        assert!(debug.contains("InvalidKeyLength"));
    }
}
