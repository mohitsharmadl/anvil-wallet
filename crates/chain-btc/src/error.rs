use thiserror::Error;

/// Bitcoin chain operation errors.
#[derive(Debug, Error)]
pub enum BtcError {
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

    #[error("invalid network: {0}")]
    InvalidNetwork(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_invalid_private_key() {
        let err = BtcError::InvalidPrivateKey("key too short".into());
        assert_eq!(err.to_string(), "invalid private key: key too short");
    }

    #[test]
    fn display_invalid_public_key() {
        let err = BtcError::InvalidPublicKey("not on curve".into());
        assert_eq!(err.to_string(), "invalid public key: not on curve");
    }

    #[test]
    fn display_invalid_address() {
        let err = BtcError::InvalidAddress("bad checksum".into());
        assert_eq!(err.to_string(), "invalid address: bad checksum");
    }

    #[test]
    fn display_transaction_build_error() {
        let err = BtcError::TransactionBuildError("insufficient funds".into());
        assert_eq!(
            err.to_string(),
            "transaction build error: insufficient funds"
        );
    }

    #[test]
    fn display_signing_error() {
        let err = BtcError::SigningError("sighash failed".into());
        assert_eq!(err.to_string(), "signing error: sighash failed");
    }

    #[test]
    fn display_invalid_network() {
        let err = BtcError::InvalidNetwork("regtest not supported".into());
        assert_eq!(err.to_string(), "invalid network: regtest not supported");
    }

    #[test]
    fn error_trait_is_implemented() {
        let err: Box<dyn std::error::Error> =
            Box::new(BtcError::InvalidPrivateKey("test".into()));
        assert!(err.to_string().contains("test"));
    }

    #[test]
    fn debug_format_works() {
        let err = BtcError::SigningError("fail".into());
        let debug = format!("{:?}", err);
        assert!(debug.contains("SigningError"));
    }
}
