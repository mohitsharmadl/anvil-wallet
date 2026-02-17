use thiserror::Error;

/// Ethereum chain operation errors.
#[derive(Debug, Error)]
pub enum EthError {
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

    #[error("encoding error: {0}")]
    EncodingError(String),

    #[error("unsupported chain: {0}")]
    UnsupportedChain(u64),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_invalid_private_key() {
        let err = EthError::InvalidPrivateKey("key too short".into());
        assert_eq!(err.to_string(), "invalid private key: key too short");
    }

    #[test]
    fn display_invalid_public_key() {
        let err = EthError::InvalidPublicKey("not on curve".into());
        assert_eq!(err.to_string(), "invalid public key: not on curve");
    }

    #[test]
    fn display_invalid_address() {
        let err = EthError::InvalidAddress("bad checksum".into());
        assert_eq!(err.to_string(), "invalid address: bad checksum");
    }

    #[test]
    fn display_transaction_build_error() {
        let err = EthError::TransactionBuildError("missing nonce".into());
        assert_eq!(err.to_string(), "transaction build error: missing nonce");
    }

    #[test]
    fn display_signing_error() {
        let err = EthError::SigningError("invalid signature".into());
        assert_eq!(err.to_string(), "signing error: invalid signature");
    }

    #[test]
    fn display_encoding_error() {
        let err = EthError::EncodingError("rlp overflow".into());
        assert_eq!(err.to_string(), "encoding error: rlp overflow");
    }

    #[test]
    fn display_unsupported_chain() {
        let err = EthError::UnsupportedChain(999);
        assert_eq!(err.to_string(), "unsupported chain: 999");
    }

    #[test]
    fn error_trait_is_implemented() {
        let err: Box<dyn std::error::Error> =
            Box::new(EthError::InvalidPrivateKey("test".into()));
        assert!(err.to_string().contains("test"));
    }

    #[test]
    fn debug_format_works() {
        let err = EthError::UnsupportedChain(42);
        let debug = format!("{:?}", err);
        assert!(debug.contains("UnsupportedChain"));
    }
}
