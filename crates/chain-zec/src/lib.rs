//! Zcash chain support for the crypto-wallet.
//!
//! Provides transparent (t-address) P2PKH address derivation, UTXO transaction
//! building, and signing using Zcash v5 format (ZIP-225) with ZIP-244 sighash.

pub mod address;
pub mod error;
pub mod transaction;
