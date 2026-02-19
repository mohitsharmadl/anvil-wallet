//! Cross-crate integration tests exercising the full pipeline:
//! mnemonic -> derive key -> sign transaction -> verify output.
//!
//! These tests use the public API of wallet_core (the same FFI functions
//! exposed to Swift) to catch regressions at crate boundaries.

use wallet_core::*;
use wallet_core::types::Chain;

const TEST_MNEMONIC: &str =
    "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

fn test_seed() -> Vec<u8> {
    mnemonic_to_seed(TEST_MNEMONIC.into(), String::new()).unwrap()
}

// ─── ETH: mnemonic -> derive -> sign -> verify ─────────────────────

#[test]
fn eth_full_pipeline_native_transfer() {
    // 1. Generate and validate mnemonic
    let mnemonic = generate_mnemonic().unwrap();
    assert!(validate_mnemonic(mnemonic.clone()).unwrap());

    // 2. Derive addresses
    let addresses = derive_all_addresses_from_mnemonic(mnemonic.clone(), String::new(), 0).unwrap();
    let eth_addr = addresses.iter().find(|a| a.chain == Chain::Ethereum).unwrap();
    assert!(eth_addr.address.starts_with("0x"));
    assert_eq!(eth_addr.address.len(), 42);

    // 3. Validate derived address
    assert!(validate_address(eth_addr.address.clone(), Chain::Ethereum).unwrap());

    // 4. Sign a transaction
    let seed = mnemonic_to_seed(mnemonic, String::new()).unwrap();
    let signed_tx = sign_eth_transaction(
        seed,
        String::new(),
        0,
        0,
        1,      // Ethereum mainnet
        0,      // nonce
        "0x000000000000000000000000000000000000dEaD".into(),
        "0xde0b6b3a7640000".into(), // 1 ETH
        vec![], // no calldata
        "0x3b9aca00".into(),        // 1 gwei priority fee
        "0xba43b7400".into(),       // 50 gwei max fee
        21_000,
    )
    .unwrap();

    // 5. Verify output
    assert_eq!(signed_tx[0], 0x02); // EIP-1559 type byte
    assert!(signed_tx.len() > 100); // A real signed tx is 100+ bytes
}

#[test]
fn eth_full_pipeline_erc20_transfer() {
    let seed = test_seed();
    let usdc_contract = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    let recipient = "0x000000000000000000000000000000000000dEaD";

    // Sign ERC-20 transfer
    let signed_tx = sign_erc20_transfer(
        seed,
        String::new(),
        0,
        0,
        1,      // Ethereum
        5,      // nonce
        usdc_contract.into(),
        recipient.into(),
        "0xf4240".into(), // 1,000,000 (1 USDC with 6 decimals) — odd-length hex is valid
        "0x3b9aca00".into(),
        "0xba43b7400".into(),
        65_000,
    )
    .unwrap();

    assert_eq!(signed_tx[0], 0x02);
    assert!(signed_tx.len() > 100);
}

#[test]
fn eth_personal_sign_and_recover() {
    let seed = test_seed();
    let message = b"Hello from Anvil Wallet!";

    // Sign
    let signature = sign_eth_message(seed, 0, 0, message.to_vec()).unwrap();
    assert_eq!(signature.len(), 65);

    // Compute the EIP-191 hash manually to verify recovery
    let prefix = format!("\x19Ethereum Signed Message:\n{}", message.len());
    let mut hasher_data = prefix.as_bytes().to_vec();
    hasher_data.extend_from_slice(message);
    let msg_hash = keccak256(hasher_data);

    // Recover public key
    let recovered = recover_eth_pubkey(signature, msg_hash).unwrap();
    assert_eq!(recovered.len(), 65); // Uncompressed pubkey
    assert_eq!(recovered[0], 0x04); // Uncompressed prefix
}

#[test]
fn eth_raw_hash_sign_for_eip712() {
    let seed = test_seed();

    // Simulate EIP-712: keccak256("\x19\x01" || domainSeparator || structHash)
    let domain_separator = keccak256(b"test domain".to_vec());
    let struct_hash = keccak256(b"test struct".to_vec());

    let mut payload = vec![0x19, 0x01];
    payload.extend_from_slice(&domain_separator);
    payload.extend_from_slice(&struct_hash);
    let final_hash = keccak256(payload);

    // Sign the raw hash (no EIP-191 prefix)
    let signature = sign_eth_raw_hash(seed, 0, 0, final_hash.clone()).unwrap();
    assert_eq!(signature.len(), 65);

    // Should be recoverable
    let recovered = recover_eth_pubkey(signature, final_hash).unwrap();
    assert_eq!(recovered.len(), 65);
    assert_eq!(recovered[0], 0x04);
}

// ─── BTC: mnemonic -> derive -> sign ────────────────────────────────

#[test]
fn btc_full_pipeline() {
    let mnemonic = TEST_MNEMONIC.to_string();

    // 1. Derive BTC address
    let addr = derive_address_from_mnemonic(
        mnemonic.clone(),
        String::new(),
        Chain::Bitcoin,
        0,
        0,
    )
    .unwrap();
    assert!(addr.address.starts_with("bc1")); // Native SegWit
    assert!(validate_address(addr.address.clone(), Chain::Bitcoin).unwrap());

    // 2. Sign a transaction with a mock UTXO
    let seed = mnemonic_to_seed(mnemonic, String::new()).unwrap();
    let utxo = UtxoData {
        txid: "a".repeat(64), // 64 hex chars
        vout: 0,
        amount_sat: 100_000, // 0.001 BTC
        script_pubkey: vec![0x00, 0x14, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
                            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                            0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD],
    };

    let signed = sign_btc_transaction(
        seed,
        0,
        0,
        vec![utxo],
        addr.address.clone(), // send to self for simplicity
        50_000,               // 0.0005 BTC
        addr.address,         // change back to self
        10,                   // 10 sat/vByte
        false,                // mainnet
    )
    .unwrap();

    assert!(!signed.is_empty());
    // BTC wire format starts with version bytes
    assert!(signed.len() > 50);
}

// ─── SOL: mnemonic -> derive -> sign ────────────────────────────────

#[test]
fn sol_full_pipeline_native_transfer() {
    let mnemonic = TEST_MNEMONIC.to_string();

    // 1. Derive SOL address
    let addr = derive_address_from_mnemonic(
        mnemonic.clone(),
        String::new(),
        Chain::Solana,
        0,
        0,
    )
    .unwrap();
    assert!(validate_address(addr.address.clone(), Chain::Solana).unwrap());

    // 2. Sign a SOL transfer
    let seed = mnemonic_to_seed(mnemonic, String::new()).unwrap();
    let signed = sign_sol_transfer(
        seed,
        0,
        "11111111111111111111111111111112".into(), // recipient
        1_000_000_000, // 1 SOL
        vec![0xAA; 32], // mock blockhash
    )
    .unwrap();

    // Solana wire format: compact-u16(1) signature + message
    assert_eq!(signed[0], 0x01); // 1 signature
    assert!(signed.len() > 65); // at least signature + message
}

#[test]
fn sol_full_pipeline_spl_transfer() {
    let seed = test_seed();
    let usdc_mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
    let recipient = "11111111111111111111111111111112";

    // 1. Derive ATAs
    let addr = derive_address_from_mnemonic(
        TEST_MNEMONIC.into(),
        String::new(),
        Chain::Solana,
        0,
        0,
    )
    .unwrap();
    let sender_ata = derive_sol_token_address(addr.address, usdc_mint.into()).unwrap();
    let recipient_ata = derive_sol_token_address(recipient.into(), usdc_mint.into()).unwrap();
    assert_ne!(sender_ata, recipient_ata);

    // 2. Sign SPL transfer
    let signed = sign_spl_transfer(
        seed,
        0,
        recipient.into(),
        usdc_mint.into(),
        1_000_000, // 1 USDC
        6,
        vec![0xBB; 32],
    )
    .unwrap();

    assert_eq!(signed[0], 0x01);
    assert!(signed.len() > 65);
}

// ─── Cross-chain: same mnemonic, different addresses ────────────────

#[test]
fn same_mnemonic_produces_different_addresses_per_chain() {
    let addresses = derive_all_addresses_from_mnemonic(
        TEST_MNEMONIC.into(),
        String::new(),
        0,
    )
    .unwrap();

    let eth = addresses.iter().find(|a| a.chain == Chain::Ethereum).unwrap();
    let btc = addresses.iter().find(|a| a.chain == Chain::Bitcoin).unwrap();
    let sol = addresses.iter().find(|a| a.chain == Chain::Solana).unwrap();

    // All three should be different formats
    assert!(eth.address.starts_with("0x"));
    assert!(btc.address.starts_with("bc1"));
    assert!(!sol.address.starts_with("0x") && !sol.address.starts_with("bc1"));

    // None should be equal
    assert_ne!(eth.address, btc.address);
    assert_ne!(eth.address, sol.address);
    assert_ne!(btc.address, sol.address);
}

// ─── Seed encryption roundtrip ──────────────────────────────────────

#[test]
fn seed_encrypt_decrypt_roundtrip() {
    let seed = test_seed();
    let password = "correct horse battery staple";

    let encrypted = encrypt_seed_with_password(seed.clone(), password.into()).unwrap();
    assert!(!encrypted.ciphertext.is_empty());
    assert!(!encrypted.salt.is_empty());

    let decrypted = decrypt_seed_with_password(
        encrypted.ciphertext,
        encrypted.salt,
        password.into(),
    )
    .unwrap();

    assert_eq!(seed, decrypted);
}

#[test]
fn seed_decrypt_wrong_password_fails() {
    let seed = test_seed();
    let encrypted = encrypt_seed_with_password(seed, "right-password".into()).unwrap();

    let result = decrypt_seed_with_password(
        encrypted.ciphertext,
        encrypted.salt,
        "wrong-password".into(),
    );
    assert!(result.is_err());
}

// ─── EVM chains share the same address ──────────────────────────────

#[test]
fn evm_chains_share_address() {
    let eth_addr = derive_address_from_mnemonic(
        TEST_MNEMONIC.into(), String::new(), Chain::Ethereum, 0, 0,
    ).unwrap();
    let polygon_addr = derive_address_from_mnemonic(
        TEST_MNEMONIC.into(), String::new(), Chain::Polygon, 0, 0,
    ).unwrap();
    let arb_addr = derive_address_from_mnemonic(
        TEST_MNEMONIC.into(), String::new(), Chain::Arbitrum, 0, 0,
    ).unwrap();

    assert_eq!(eth_addr.address, polygon_addr.address);
    assert_eq!(eth_addr.address, arb_addr.address);
}
