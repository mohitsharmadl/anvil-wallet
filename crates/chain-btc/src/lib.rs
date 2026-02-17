//! Bitcoin chain support for the crypto-wallet.
//!
//! Provides P2WPKH address derivation, UTXO coin selection, transaction
//! building, and signing using native SegWit (bech32) conventions.

pub mod address;
pub mod error;
pub mod network;
pub mod transaction;
pub mod utxo;
