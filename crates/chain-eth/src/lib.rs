//! Ethereum/EVM chain support for the crypto-wallet.
//!
//! This crate provides:
//! - Ethereum address derivation from secp256k1 public keys (with EIP-55 checksums)
//! - EIP-1559 transaction building and signing
//! - ERC-20 token interaction encoding (transfer, approve, balanceOf)
//! - Multi-chain EVM network definitions
//! - Minimal ABI encoding utilities

pub mod abi;
pub mod address;
pub mod chains;
pub mod erc20;
pub mod error;
pub mod transaction;
