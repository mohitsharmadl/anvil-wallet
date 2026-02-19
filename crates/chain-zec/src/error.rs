use thiserror::Error;

/// Zcash chain operation errors.
#[derive(Debug, Error)]
pub enum ZecError {
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

    #[error("insufficient funds: need {needed} zatoshi, have {available}")]
    InsufficientFunds { needed: u64, available: u64 },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_invalid_private_key() {
        let err = ZecError::InvalidPrivateKey("key too short".into());
        assert_eq!(err.to_string(), "invalid private key: key too short");
    }

    #[test]
    fn display_insufficient_funds() {
        let err = ZecError::InsufficientFunds {
            needed: 100_000,
            available: 50_000,
        };
        assert!(err.to_string().contains("100000"));
        assert!(err.to_string().contains("50000"));
    }

    #[test]
    fn error_trait_is_implemented() {
        let err: Box<dyn std::error::Error> =
            Box::new(ZecError::InvalidAddress("bad".into()));
        assert!(err.to_string().contains("bad"));
    }
}
