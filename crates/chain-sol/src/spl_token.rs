//! SPL Token operations for Solana.
//!
//! Implements SPL Token transfer instructions and associated token account
//! (ATA) address derivation without pulling in the `solana-sdk` or the
//! `spl-token` crates.

use sha2::{Digest, Sha256};

use crate::error::SolError;
use crate::transaction::SolAccountMeta;
use crate::transaction::SolInstruction;

// ---------------------------------------------------------------------------
// Well-known program IDs
// ---------------------------------------------------------------------------

/// SPL Token Program ID: `TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA`
pub const TOKEN_PROGRAM_ID: [u8; 32] = {
    // Pre-computed bytes for TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA
    // Decoded from Base58 at compile time is not possible, so we use a const array.
    [
        0x06, 0xdd, 0xf6, 0xe1, 0xd7, 0x65, 0xa1, 0x93, 0xd9, 0xcb, 0xe1, 0x46, 0xce, 0xeb,
        0x79, 0xac, 0x1c, 0xb4, 0x85, 0xed, 0x5f, 0x5b, 0x37, 0x91, 0x3a, 0x8c, 0xf5, 0x85,
        0x7e, 0xff, 0x00, 0xa9,
    ]
};

/// Associated Token Account Program ID: `ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL`
pub const ASSOCIATED_TOKEN_PROGRAM_ID: [u8; 32] = {
    [
        0x8c, 0x97, 0x25, 0x8f, 0x4e, 0x24, 0x89, 0xf1, 0xbb, 0x3d, 0x10, 0x29, 0x14, 0x8e,
        0x0d, 0x83, 0x0b, 0x5a, 0x13, 0x99, 0xda, 0xff, 0x10, 0x84, 0x04, 0x8e, 0x7b, 0xd8,
        0xdb, 0xe9, 0xf8, 0x59,
    ]
};

/// The string appended to PDA derivation: "ProgramDerivedAddress".
const PDA_MARKER: &[u8] = b"ProgramDerivedAddress";

// ---------------------------------------------------------------------------
// SPL Token Transfer
// ---------------------------------------------------------------------------

/// Build an SPL Token `Transfer` instruction.
///
/// This transfers `amount` of the smallest token unit (e.g. for a token with
/// 6 decimals, `amount = 1_000_000` transfers 1 whole token).
///
/// # Arguments
///
/// * `from_token_account` - Sender's associated token account (writable).
/// * `to_token_account` - Recipient's associated token account (writable).
/// * `owner` - The wallet that owns `from_token_account` (signer).
/// * `amount` - Number of token base units to transfer.
/// * `_decimals` - Token decimals (unused for Transfer, included for API parity
///   with TransferChecked).
///
/// # Wire format
///
/// SPL Token `Transfer` instruction index = 3, followed by u64 LE amount.
/// Total data: 9 bytes.
pub fn build_spl_transfer(
    from_token_account: &[u8; 32],
    to_token_account: &[u8; 32],
    owner: &[u8; 32],
    amount: u64,
    _decimals: u8,
) -> Result<SolInstruction, SolError> {
    if amount == 0 {
        return Err(SolError::TransactionBuildError(
            "SPL transfer amount must be > 0".into(),
        ));
    }

    // Instruction data: [3] (Transfer) + u64 LE amount = 9 bytes.
    let mut data = Vec::with_capacity(9);
    data.push(3u8); // Transfer instruction index
    data.extend_from_slice(&amount.to_le_bytes());

    Ok(SolInstruction {
        program_id: TOKEN_PROGRAM_ID,
        accounts: vec![
            SolAccountMeta {
                pubkey: *from_token_account,
                is_signer: false,
                is_writable: true,
            },
            SolAccountMeta {
                pubkey: *to_token_account,
                is_signer: false,
                is_writable: true,
            },
            SolAccountMeta {
                pubkey: *owner,
                is_signer: true,
                is_writable: false,
            },
        ],
        data,
    })
}

// ---------------------------------------------------------------------------
// Associated Token Account (PDA) derivation
// ---------------------------------------------------------------------------

/// Derive the associated token account address for a wallet + mint pair.
///
/// The ATA is a Program Derived Address (PDA) with seeds:
///   `[wallet_address, token_program_id, mint_address]`
/// derived from the Associated Token Account program.
///
/// The derivation searches for a bump seed (255 down to 0) such that the
/// resulting point is NOT on the Ed25519 curve.
pub fn derive_associated_token_address(
    wallet: &[u8; 32],
    mint: &[u8; 32],
) -> Result<[u8; 32], SolError> {
    find_program_address(
        &[wallet.as_ref(), &TOKEN_PROGRAM_ID, mint.as_ref()],
        &ASSOCIATED_TOKEN_PROGRAM_ID,
    )
    .map(|(address, _bump)| address)
}

/// Find a valid Program Derived Address (PDA) for the given seeds and program.
///
/// Iterates bump seeds from 255 down to 0, computing
/// `SHA-256(seed_0 || seed_1 || ... || bump || program_id || "ProgramDerivedAddress")`
/// and returning the first result that is NOT a valid Ed25519 point.
fn find_program_address(
    seeds: &[&[u8]],
    program_id: &[u8; 32],
) -> Result<([u8; 32], u8), SolError> {
    for bump in (0u8..=255).rev() {
        if let Some(address) = try_create_program_address(seeds, &[bump], program_id) {
            return Ok((address, bump));
        }
    }

    Err(SolError::InvalidAddress(
        "could not find valid PDA bump seed".into(),
    ))
}

/// Attempt to create a PDA from seeds + bump + program_id.
///
/// Returns `Some(address)` if the derived point is OFF the Ed25519 curve,
/// `None` if it falls on the curve (invalid PDA — try next bump).
fn try_create_program_address(
    seeds: &[&[u8]],
    bump_seed: &[u8],
    program_id: &[u8; 32],
) -> Option<[u8; 32]> {
    let mut hasher = Sha256::new();

    for seed in seeds {
        hasher.update(seed);
    }
    hasher.update(bump_seed);
    hasher.update(program_id);
    hasher.update(PDA_MARKER);

    let hash: [u8; 32] = hasher.finalize().into();

    // A valid PDA must NOT be on the Ed25519 curve.
    if is_on_curve(&hash) {
        return None;
    }

    Some(hash)
}

/// Check if 32 bytes represent a valid Ed25519 curve point.
///
/// Uses `curve25519-dalek` to attempt decompression. If it succeeds, the
/// point is on the curve.
fn is_on_curve(bytes: &[u8; 32]) -> bool {
    curve25519_dalek::edwards::CompressedEdwardsY(*bytes)
        .decompress()
        .is_some()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::address;

    // -- Constant verification ----------------------------------------------

    #[test]
    fn token_program_id_roundtrip() {
        let addr = address::bytes_to_address(&TOKEN_PROGRAM_ID);
        assert_eq!(addr, "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
    }

    #[test]
    fn associated_token_program_id_roundtrip() {
        let addr = address::bytes_to_address(&ASSOCIATED_TOKEN_PROGRAM_ID);
        assert_eq!(addr, "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL");
    }

    // -- SPL Transfer instruction -------------------------------------------

    #[test]
    fn spl_transfer_data_is_9_bytes() {
        let from = [1u8; 32];
        let to = [2u8; 32];
        let owner = [3u8; 32];

        let ix = build_spl_transfer(&from, &to, &owner, 1_000_000, 6).unwrap();
        assert_eq!(ix.data.len(), 9);
    }

    #[test]
    fn spl_transfer_data_encoding() {
        let from = [1u8; 32];
        let to = [2u8; 32];
        let owner = [3u8; 32];
        let amount: u64 = 500_000;

        let ix = build_spl_transfer(&from, &to, &owner, amount, 6).unwrap();

        // First byte: instruction type = 3 (Transfer).
        assert_eq!(ix.data[0], 3);

        // Next 8 bytes: amount as u64 LE.
        let encoded_amount = u64::from_le_bytes(ix.data[1..9].try_into().unwrap());
        assert_eq!(encoded_amount, amount);
    }

    #[test]
    fn spl_transfer_account_roles() {
        let from = [1u8; 32];
        let to = [2u8; 32];
        let owner = [3u8; 32];

        let ix = build_spl_transfer(&from, &to, &owner, 100, 9).unwrap();

        assert_eq!(ix.accounts.len(), 3);

        // Source: writable, not signer.
        assert!(ix.accounts[0].is_writable);
        assert!(!ix.accounts[0].is_signer);

        // Destination: writable, not signer.
        assert!(ix.accounts[1].is_writable);
        assert!(!ix.accounts[1].is_signer);

        // Owner: signer, not writable.
        assert!(ix.accounts[2].is_signer);
        assert!(!ix.accounts[2].is_writable);
    }

    #[test]
    fn spl_transfer_uses_token_program() {
        let from = [1u8; 32];
        let to = [2u8; 32];
        let owner = [3u8; 32];

        let ix = build_spl_transfer(&from, &to, &owner, 100, 6).unwrap();
        assert_eq!(ix.program_id, TOKEN_PROGRAM_ID);
    }

    #[test]
    fn spl_transfer_zero_amount_fails() {
        let from = [1u8; 32];
        let to = [2u8; 32];
        let owner = [3u8; 32];

        let result = build_spl_transfer(&from, &to, &owner, 0, 6);
        assert!(result.is_err());
    }

    // -- PDA derivation -----------------------------------------------------

    #[test]
    fn pda_is_not_on_curve() {
        let wallet = [0xAAu8; 32];
        let mint = [0xBBu8; 32];

        let ata = derive_associated_token_address(&wallet, &mint).unwrap();
        assert!(!is_on_curve(&ata), "PDA must NOT be on the Ed25519 curve");
    }

    #[test]
    fn pda_derivation_is_deterministic() {
        let wallet = [0x11u8; 32];
        let mint = [0x22u8; 32];

        let ata1 = derive_associated_token_address(&wallet, &mint).unwrap();
        let ata2 = derive_associated_token_address(&wallet, &mint).unwrap();
        assert_eq!(ata1, ata2);
    }

    #[test]
    fn pda_different_wallets_give_different_atas() {
        let wallet_a = [0x01u8; 32];
        let wallet_b = [0x02u8; 32];
        let mint = [0xFFu8; 32];

        let ata_a = derive_associated_token_address(&wallet_a, &mint).unwrap();
        let ata_b = derive_associated_token_address(&wallet_b, &mint).unwrap();
        assert_ne!(ata_a, ata_b);
    }

    #[test]
    fn pda_different_mints_give_different_atas() {
        let wallet = [0xAAu8; 32];
        let mint_a = [0x01u8; 32];
        let mint_b = [0x02u8; 32];

        let ata_a = derive_associated_token_address(&wallet, &mint_a).unwrap();
        let ata_b = derive_associated_token_address(&wallet, &mint_b).unwrap();
        assert_ne!(ata_a, ata_b);
    }

    #[test]
    fn pda_result_is_32_bytes() {
        let wallet = [0xCCu8; 32];
        let mint = [0xDDu8; 32];

        let ata = derive_associated_token_address(&wallet, &mint).unwrap();
        assert_eq!(ata.len(), 32);
    }

    #[test]
    fn is_on_curve_rejects_known_point() {
        // The Ed25519 basepoint (compressed form).
        let basepoint: [u8; 32] = [
            0x58, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
            0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
            0x66, 0x66, 0x66, 0x66,
        ];
        assert!(is_on_curve(&basepoint));
    }

    #[test]
    fn is_on_curve_rejects_off_curve_bytes() {
        // A compressed Edwards Y coordinate is valid only if y < p and
        // the recovered x exists. We pick a value where the most significant
        // bit (sign bit) is stripped to get a y value, and the Legendre symbol
        // check fails during decompression.
        //
        // 0x02 repeated 32 times: y = 0x020202...02. This does not correspond
        // to a valid curve point.
        let not_a_point: [u8; 32] = [0x02; 32];
        assert!(
            !is_on_curve(&not_a_point),
            "0x02 * 32 should not be a valid curve point"
        );
    }

    // -- Known ATA derivation (integration-style) ---------------------------

    #[test]
    fn derive_ata_for_known_wallet_and_usdc_mint() {
        // USDC mint on Solana mainnet:
        // EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v
        let usdc_mint = address::address_to_bytes(
            "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
        )
        .unwrap();

        // Use a fixed "wallet" for reproducibility.
        let wallet = [0x42u8; 32];

        let ata = derive_associated_token_address(&wallet, &usdc_mint).unwrap();

        // The result should be a valid 32-byte address that is NOT on the curve.
        assert!(!is_on_curve(&ata));

        // It should produce a valid Base58 address.
        let ata_addr = address::bytes_to_address(&ata);
        assert!(address::validate_address(&ata_addr).is_ok());
    }
}
