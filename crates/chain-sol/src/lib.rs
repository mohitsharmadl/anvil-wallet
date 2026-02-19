//! Solana chain support for the crypto-wallet.
//!
//! This crate handles Solana address derivation, manual transaction wire
//! format serialization, and SPL token transfers — all without pulling in
//! `solana-sdk` (which drags in tokio and 200+ transitive dependencies).
//!
//! Instead we implement Solana's compact binary wire format by hand, using
//! `ed25519-dalek` for Ed25519 signing and `bs58` for Base58 encoding.

pub mod address;
pub mod error;
pub mod spl_token;
pub mod transaction;

// Re-export key public types for ergonomic imports.
pub use address::{address_to_bytes, bytes_to_address, keypair_to_address, validate_address};
pub use error::SolError;
pub use spl_token::{
    build_spl_transfer, derive_associated_token_address, ASSOCIATED_TOKEN_PROGRAM_ID,
    TOKEN_PROGRAM_ID,
};
pub use transaction::{
    build_sol_transfer, compile_transaction, decode_compact_u16, encode_compact_u16,
    serialize_message, sign_sol_raw_transaction, sign_transaction, CompiledInstruction,
    SolAccountMeta, SolInstruction, SolTransaction, SYSTEM_PROGRAM_ID,
};
