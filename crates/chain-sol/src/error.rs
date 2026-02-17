use thiserror::Error;

/// Solana chain operation errors.
#[derive(Debug, Error)]
pub enum SolError {
    #[error("invalid private key: {0}")]
    InvalidPrivateKey(String),

    #[error("invalid public key: {0}")]
    InvalidPublicKey(String),

    #[error("invalid address: {0}")]
    InvalidAddress(String),

    #[error("transaction build error: {0}")]
    TransactionBuildError(String),

    #[error("signing error: {0}")]
    SigningError(String),

    #[error("serialization error: {0}")]
    SerializationError(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_invalid_private_key() {
        let err = SolError::InvalidPrivateKey("key too short".into());
        assert_eq!(err.to_string(), "invalid private key: key too short");
    }

    #[test]
    fn display_invalid_public_key() {
        let err = SolError::InvalidPublicKey("not on curve".into());
        assert_eq!(err.to_string(), "invalid public key: not on curve");
    }

    #[test]
    fn display_invalid_address() {
        let err = SolError::InvalidAddress("bad decode".into());
        assert_eq!(err.to_string(), "invalid address: bad decode");
    }

    #[test]
    fn display_transaction_build_error() {
        let err = SolError::TransactionBuildError("insufficient lamports".into());
        assert_eq!(
            err.to_string(),
            "transaction build error: insufficient lamports"
        );
    }

    #[test]
    fn display_signing_error() {
        let err = SolError::SigningError("ed25519 failed".into());
        assert_eq!(err.to_string(), "signing error: ed25519 failed");
    }

    #[test]
    fn display_serialization_error() {
        let err = SolError::SerializationError("compact-u16 overflow".into());
        assert_eq!(
            err.to_string(),
            "serialization error: compact-u16 overflow"
        );
    }

    #[test]
    fn error_trait_is_implemented() {
        let err: Box<dyn std::error::Error> =
            Box::new(SolError::InvalidPrivateKey("test".into()));
        assert!(err.to_string().contains("test"));
    }

    #[test]
    fn debug_format_works() {
        let err = SolError::SigningError("fail".into());
        let debug = format!("{:?}", err);
        assert!(debug.contains("SigningError"));
    }
}
