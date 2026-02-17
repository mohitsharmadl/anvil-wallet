use thiserror::Error;

#[derive(Debug, Error)]
pub enum WalletError {
    #[error("Invalid mnemonic: {0}")]
    InvalidMnemonic(String),

    #[error("Key derivation failed: {0}")]
    DerivationFailed(String),

    #[error("Encryption failed: {0}")]
    EncryptionFailed(String),

    #[error("Decryption failed: {0}")]
    DecryptionFailed(String),

    #[error("Invalid seed: {0}")]
    InvalidSeed(String),

    #[error("Invalid private key: {0}")]
    InvalidPrivateKey(String),

    #[error("Invalid address: {0}")]
    InvalidAddress(String),

    #[error("Unsupported chain: {0}")]
    UnsupportedChain(String),

    #[error("Signing failed: {0}")]
    SigningFailed(String),

    #[error("Transaction build failed: {0}")]
    TransactionFailed(String),

    #[error("Internal error: {0}")]
    Internal(String),
}

impl From<crypto_utils::error::CryptoError> for WalletError {
    fn from(e: crypto_utils::error::CryptoError) -> Self {
        WalletError::EncryptionFailed(e.to_string())
    }
}

impl From<chain_btc::error::BtcError> for WalletError {
    fn from(e: chain_btc::error::BtcError) -> Self {
        WalletError::TransactionFailed(format!("BTC: {e}"))
    }
}

impl From<chain_eth::error::EthError> for WalletError {
    fn from(e: chain_eth::error::EthError) -> Self {
        WalletError::TransactionFailed(format!("ETH: {e}"))
    }
}

impl From<chain_sol::error::SolError> for WalletError {
    fn from(e: chain_sol::error::SolError) -> Self {
        WalletError::TransactionFailed(format!("SOL: {e}"))
    }
}
