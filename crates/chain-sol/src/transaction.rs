//! Manual Solana transaction wire format and signing.
//!
//! We build Solana transactions entirely by hand — no `solana-sdk` dependency.
//! The wire format is a compact binary layout documented here:
//!
//! ```text
//! Transaction:
//!   num_signatures          compact-u16
//!   signatures              64 bytes * num_signatures
//!   message:
//!     num_required_sigs     u8
//!     num_readonly_signed   u8
//!     num_readonly_unsigned u8
//!     num_accounts          compact-u16
//!     account_keys          32 bytes * num_accounts
//!     recent_blockhash      32 bytes
//!     num_instructions      compact-u16
//!     instructions[]        (see below)
//!
//! Instruction:
//!   program_id_index        u8
//!   num_accounts            compact-u16
//!   account_indices         u8 * num_accounts
//!   data_len                compact-u16
//!   data                    u8 * data_len
//! ```

use ed25519_dalek::Signer;
use zeroize::Zeroize;

use crate::error::SolError;

// ---------------------------------------------------------------------------
// Solana System Program
// ---------------------------------------------------------------------------

/// The Solana System Program public key: 32 zero bytes.
/// Base58: `11111111111111111111111111111111`
pub const SYSTEM_PROGRAM_ID: [u8; 32] = [0u8; 32];

/// System Program `Transfer` instruction index (little-endian u32).
const SYSTEM_TRANSFER_IX_INDEX: u32 = 2;

// ---------------------------------------------------------------------------
// Compact-u16 encoding
// ---------------------------------------------------------------------------

/// Encode a `u16` value in Solana's compact-u16 format.
///
/// - Values 0..0x7f       -> 1 byte
/// - Values 0x80..0x3fff  -> 2 bytes
/// - Values 0x4000..      -> 3 bytes (max 0x1_ffff, but u16 caps at 0xffff)
pub fn encode_compact_u16(value: u16) -> Vec<u8> {
    let mut val = value as u32;
    let mut out = Vec::with_capacity(3);

    loop {
        let mut byte = (val & 0x7f) as u8;
        val >>= 7;
        if val > 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if val == 0 {
            break;
        }
    }

    out
}

// ---------------------------------------------------------------------------
// Data structures
// ---------------------------------------------------------------------------

/// A single account reference in a Solana instruction.
#[derive(Debug, Clone)]
pub struct SolAccountMeta {
    pub pubkey: [u8; 32],
    pub is_signer: bool,
    pub is_writable: bool,
}

/// A Solana instruction (before it is compiled into a transaction).
#[derive(Debug, Clone)]
pub struct SolInstruction {
    pub program_id: [u8; 32],
    pub accounts: Vec<SolAccountMeta>,
    pub data: Vec<u8>,
}

/// A complete Solana transaction (unsigned or partially signed).
#[derive(Debug, Clone)]
pub struct SolTransaction {
    /// All account keys referenced by this transaction, in canonical order:
    ///   1. writable signers
    ///   2. read-only signers
    ///   3. writable non-signers
    ///   4. read-only non-signers
    pub account_keys: Vec<[u8; 32]>,

    /// Number of required signatures (first N accounts are signers).
    pub num_required_signatures: u8,
    /// How many of the signing accounts are read-only.
    pub num_readonly_signed: u8,
    /// How many of the non-signing accounts are read-only.
    pub num_readonly_unsigned: u8,

    /// Recent blockhash (32 bytes).
    pub recent_blockhash: [u8; 32],

    /// Compiled instructions (account references replaced with indices).
    pub compiled_instructions: Vec<CompiledInstruction>,
}

/// A compiled instruction where account references are replaced by u8 indices
/// into the transaction's `account_keys` array.
#[derive(Debug, Clone)]
pub struct CompiledInstruction {
    /// Index into `account_keys` for the program to invoke.
    pub program_id_index: u8,
    /// Indices into `account_keys` for each account the instruction reads/writes.
    pub account_indices: Vec<u8>,
    /// Opaque instruction data.
    pub data: Vec<u8>,
}

// ---------------------------------------------------------------------------
// Transaction building
// ---------------------------------------------------------------------------

/// Build a native SOL transfer transaction.
///
/// Creates a System Program `Transfer` instruction that moves `lamports`
/// from `from_pubkey` to `to_pubkey`.
///
/// The caller must supply a recent blockhash (obtained from the RPC).
pub fn build_sol_transfer(
    from_pubkey: &[u8; 32],
    to_pubkey: &[u8; 32],
    lamports: u64,
    recent_blockhash: &[u8; 32],
) -> Result<SolTransaction, SolError> {
    if lamports == 0 {
        return Err(SolError::TransactionBuildError(
            "lamports must be > 0".into(),
        ));
    }

    let instruction = build_system_transfer_instruction(from_pubkey, to_pubkey, lamports);
    compile_transaction(&[instruction], from_pubkey, recent_blockhash)
}

/// Build a transaction from a set of instructions with a single fee payer.
///
/// The fee payer is always the first signer and is placed at index 0 in the
/// account keys.
pub fn compile_transaction(
    instructions: &[SolInstruction],
    fee_payer: &[u8; 32],
    recent_blockhash: &[u8; 32],
) -> Result<SolTransaction, SolError> {
    // Collect unique account keys with their permission bits.
    // Using a simple Vec instead of HashMap to avoid bringing in extra deps
    // and because instruction account lists are tiny.
    struct AccountEntry {
        pubkey: [u8; 32],
        is_signer: bool,
        is_writable: bool,
    }

    let mut entries: Vec<AccountEntry> = Vec::new();

    // Helper: upsert an account entry.
    let mut upsert = |pubkey: [u8; 32], signer: bool, writable: bool| {
        if let Some(entry) = entries.iter_mut().find(|e| e.pubkey == pubkey) {
            entry.is_signer |= signer;
            entry.is_writable |= writable;
        } else {
            entries.push(AccountEntry {
                pubkey,
                is_signer: signer,
                is_writable: writable,
            });
        }
    };

    // Fee payer is always signer + writable.
    upsert(*fee_payer, true, true);

    // Walk instructions.
    for ix in instructions {
        for meta in &ix.accounts {
            upsert(meta.pubkey, meta.is_signer, meta.is_writable);
        }
        // Program IDs are non-signer, read-only accounts.
        upsert(ix.program_id, false, false);
    }

    // Sort into canonical order:
    //   1. writable signers  (fee payer first)
    //   2. read-only signers
    //   3. writable non-signers
    //   4. read-only non-signers
    entries.sort_by(|a, b| {
        fn rank(e: &AccountEntry) -> u8 {
            match (e.is_signer, e.is_writable) {
                (true, true) => 0,
                (true, false) => 1,
                (false, true) => 2,
                (false, false) => 3,
            }
        }
        let ra = rank(a);
        let rb = rank(b);
        if ra != rb {
            return ra.cmp(&rb);
        }
        // Within the same category keep insertion order (fee payer first).
        std::cmp::Ordering::Equal
    });

    // Make sure fee payer is at index 0.
    if entries[0].pubkey != *fee_payer {
        let pos = entries.iter().position(|e| e.pubkey == *fee_payer).unwrap();
        entries.swap(0, pos);
    }

    let num_signers = entries.iter().filter(|e| e.is_signer).count() as u8;
    let num_readonly_signed = entries
        .iter()
        .filter(|e| e.is_signer && !e.is_writable)
        .count() as u8;
    let num_readonly_unsigned = entries
        .iter()
        .filter(|e| !e.is_signer && !e.is_writable)
        .count() as u8;

    let account_keys: Vec<[u8; 32]> = entries.iter().map(|e| e.pubkey).collect();

    // Compile instructions: replace pubkeys with indices.
    let mut compiled = Vec::with_capacity(instructions.len());
    for ix in instructions {
        let program_id_index = account_keys
            .iter()
            .position(|k| *k == ix.program_id)
            .ok_or_else(|| {
                SolError::TransactionBuildError("program_id not in account keys".into())
            })? as u8;

        let mut account_indices = Vec::with_capacity(ix.accounts.len());
        for meta in &ix.accounts {
            let idx = account_keys
                .iter()
                .position(|k| *k == meta.pubkey)
                .ok_or_else(|| {
                    SolError::TransactionBuildError("account not in account keys".into())
                })? as u8;
            account_indices.push(idx);
        }

        compiled.push(CompiledInstruction {
            program_id_index,
            account_indices,
            data: ix.data.clone(),
        });
    }

    Ok(SolTransaction {
        account_keys,
        num_required_signatures: num_signers,
        num_readonly_signed,
        num_readonly_unsigned,
        recent_blockhash: *recent_blockhash,
        compiled_instructions: compiled,
    })
}

/// Serialize the transaction message (the bytes that get signed).
pub fn serialize_message(tx: &SolTransaction) -> Result<Vec<u8>, SolError> {
    let mut buf = Vec::with_capacity(256);

    // Header: 3 bytes.
    buf.push(tx.num_required_signatures);
    buf.push(tx.num_readonly_signed);
    buf.push(tx.num_readonly_unsigned);

    // Account keys.
    buf.extend_from_slice(&encode_compact_u16(tx.account_keys.len() as u16));
    for key in &tx.account_keys {
        buf.extend_from_slice(key);
    }

    // Recent blockhash.
    buf.extend_from_slice(&tx.recent_blockhash);

    // Instructions.
    buf.extend_from_slice(&encode_compact_u16(
        tx.compiled_instructions.len() as u16
    ));
    for ix in &tx.compiled_instructions {
        buf.push(ix.program_id_index);

        buf.extend_from_slice(&encode_compact_u16(ix.account_indices.len() as u16));
        buf.extend_from_slice(&ix.account_indices);

        buf.extend_from_slice(&encode_compact_u16(ix.data.len() as u16));
        buf.extend_from_slice(&ix.data);
    }

    Ok(buf)
}

/// Sign and serialize a transaction into its wire format.
///
/// The private key is the 32-byte Ed25519 seed. The resulting byte vector
/// is ready to be submitted via `sendTransaction` RPC.
pub fn sign_transaction(
    tx: &SolTransaction,
    private_key: &[u8; 32],
) -> Result<Vec<u8>, SolError> {
    let message_bytes = serialize_message(tx)?;

    // Build the signing key (zeroize-on-drop via ed25519-dalek).
    let mut seed = *private_key;
    let signing_key = ed25519_dalek::SigningKey::from_bytes(&seed);
    seed.zeroize();

    let signature = signing_key.sign(&message_bytes);

    // Assemble wire format.
    let mut wire = Vec::with_capacity(1 + 64 + message_bytes.len());

    // Number of signatures (compact-u16, always 1 for single-signer).
    wire.extend_from_slice(&encode_compact_u16(1));

    // Signature (64 bytes).
    wire.extend_from_slice(&signature.to_bytes());

    // Message.
    wire.extend_from_slice(&message_bytes);

    Ok(wire)
}

// ---------------------------------------------------------------------------
// Raw transaction signing (for pre-built transactions from dApps / Jupiter)
// ---------------------------------------------------------------------------

/// Decode a compact-u16 value from a byte slice.
///
/// Returns `(value, bytes_consumed)` or an error if the data is truncated.
pub fn decode_compact_u16(data: &[u8]) -> Result<(u16, usize), SolError> {
    if data.is_empty() {
        return Err(SolError::SerializationError(
            "unexpected end of data while decoding compact-u16".into(),
        ));
    }

    let mut value: u32 = 0;
    let mut shift = 0u32;
    let mut consumed = 0usize;

    loop {
        if consumed >= data.len() {
            return Err(SolError::SerializationError(
                "unexpected end of data while decoding compact-u16".into(),
            ));
        }
        let byte = data[consumed];
        consumed += 1;

        value |= ((byte & 0x7f) as u32) << shift;
        shift += 7;

        if byte & 0x80 == 0 {
            break;
        }
        if consumed >= 3 {
            break;
        }
    }

    if value > u16::MAX as u32 {
        return Err(SolError::SerializationError(
            "compact-u16 value overflow".into(),
        ));
    }

    Ok((value as u16, consumed))
}

/// Sign a pre-built Solana transaction with the given Ed25519 private key.
///
/// The `raw_tx` must be a valid Solana wire-format transaction (as produced by
/// `sign_transaction` or by a dApp/Jupiter). The function:
///
/// 1. Parses the wire format to locate the signature slots and the message.
/// 2. Finds which signature slot corresponds to our public key (derived from
///    `private_key`).
/// 3. Signs the message bytes and writes the signature into the correct slot.
/// 4. Returns the fully-signed transaction bytes.
///
/// This supports both single-signer and multi-signer transactions. If our
/// pubkey is not in the transaction's signer list, an error is returned.
pub fn sign_sol_raw_transaction(
    private_key: &[u8; 32],
    raw_tx: &[u8],
) -> Result<Vec<u8>, SolError> {
    // Derive the public key from the private key.
    let mut seed = *private_key;
    let signing_key = ed25519_dalek::SigningKey::from_bytes(&seed);
    seed.zeroize();
    let our_pubkey = signing_key.verifying_key().to_bytes();

    // Parse the wire format.
    // Layout: compact-u16(num_signatures) | 64-byte signatures * N | message
    let (num_sigs, compact_len) = decode_compact_u16(raw_tx)?;

    if num_sigs == 0 {
        return Err(SolError::TransactionBuildError(
            "transaction has zero signatures".into(),
        ));
    }

    let sigs_start = compact_len;
    let sigs_end = sigs_start + (num_sigs as usize) * 64;

    if sigs_end > raw_tx.len() {
        return Err(SolError::SerializationError(
            "transaction too short: signature slots exceed length".into(),
        ));
    }

    // The message starts right after the signature slots.
    let message_bytes = &raw_tx[sigs_end..];

    if message_bytes.len() < 4 {
        return Err(SolError::SerializationError(
            "transaction message too short".into(),
        ));
    }

    // Parse the message header to find account keys.
    // Message header: num_required_signatures(u8) | num_readonly_signed(u8) | num_readonly_unsigned(u8)
    let num_required_sigs = message_bytes[0] as u16;
    // bytes [1] and [2] are readonly counts, skip them

    // Decode the number of account keys.
    let (num_accounts, accounts_compact_len) = decode_compact_u16(&message_bytes[3..])?;

    let accounts_start = 3 + accounts_compact_len;
    let accounts_end = accounts_start + (num_accounts as usize) * 32;

    if accounts_end > message_bytes.len() {
        return Err(SolError::SerializationError(
            "transaction message too short for account keys".into(),
        ));
    }

    // The first `num_required_sigs` accounts are the signers.
    // Find which signer slot matches our pubkey.
    let mut signer_index: Option<usize> = None;
    for i in 0..(num_required_sigs as usize).min(num_accounts as usize) {
        let key_start = accounts_start + i * 32;
        let key_end = key_start + 32;
        if message_bytes[key_start..key_end] == our_pubkey {
            signer_index = Some(i);
            break;
        }
    }

    let signer_idx = signer_index.ok_or_else(|| {
        SolError::SigningError(
            "wallet pubkey not found in transaction signers".into(),
        )
    })?;

    // Sign the message.
    let signature = signing_key.sign(message_bytes);

    // Build the output: copy the raw tx and overwrite our signature slot.
    let mut signed_tx = raw_tx.to_vec();
    let sig_offset = sigs_start + signer_idx * 64;
    signed_tx[sig_offset..sig_offset + 64].copy_from_slice(&signature.to_bytes());

    Ok(signed_tx)
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Build a System Program `Transfer` instruction.
fn build_system_transfer_instruction(
    from: &[u8; 32],
    to: &[u8; 32],
    lamports: u64,
) -> SolInstruction {
    // Instruction data: u32 LE instruction index (2 = Transfer) + u64 LE lamports.
    let mut data = Vec::with_capacity(12);
    data.extend_from_slice(&SYSTEM_TRANSFER_IX_INDEX.to_le_bytes());
    data.extend_from_slice(&lamports.to_le_bytes());

    SolInstruction {
        program_id: SYSTEM_PROGRAM_ID,
        accounts: vec![
            SolAccountMeta {
                pubkey: *from,
                is_signer: true,
                is_writable: true,
            },
            SolAccountMeta {
                pubkey: *to,
                is_signer: false,
                is_writable: true,
            },
        ],
        data,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // -- compact-u16 encoding -----------------------------------------------

    #[test]
    fn compact_u16_zero() {
        assert_eq!(encode_compact_u16(0), vec![0x00]);
    }

    #[test]
    fn compact_u16_one_byte_max() {
        // 127 = 0x7f, fits in one byte.
        assert_eq!(encode_compact_u16(0x7f), vec![0x7f]);
    }

    #[test]
    fn compact_u16_boundary_128() {
        // 128 = 0x80 -> two bytes: (0x00 | 0x80), 0x01
        let encoded = encode_compact_u16(128);
        assert_eq!(encoded, vec![0x80, 0x01]);
    }

    #[test]
    fn compact_u16_two_byte_max() {
        // 16383 = 0x3fff -> two bytes: (0x7f | 0x80), 0x7f
        let encoded = encode_compact_u16(16383);
        assert_eq!(encoded, vec![0xff, 0x7f]);
    }

    #[test]
    fn compact_u16_boundary_16384() {
        // 16384 = 0x4000 -> three bytes: 0x80, 0x80, 0x01
        let encoded = encode_compact_u16(16384);
        assert_eq!(encoded, vec![0x80, 0x80, 0x01]);
    }

    #[test]
    fn compact_u16_max_value() {
        // 65535 = 0xffff -> three bytes
        let encoded = encode_compact_u16(u16::MAX);
        assert_eq!(encoded.len(), 3);
        // Decode back: ((0x7f) | (0x7f << 7) | (0x03 << 14)) = 127 + 16256 + 49152 = 65535
        assert_eq!(encoded, vec![0xff, 0xff, 0x03]);
    }

    // -- SOL transfer structure ---------------------------------------------

    #[test]
    fn sol_transfer_instruction_data_is_12_bytes() {
        let from = [1u8; 32];
        let to = [2u8; 32];
        let ix = build_system_transfer_instruction(&from, &to, 1_000_000);
        // 4 bytes instruction index + 8 bytes lamports = 12.
        assert_eq!(ix.data.len(), 12);
        // First 4 bytes: u32 LE = 2 (Transfer).
        assert_eq!(&ix.data[..4], &[2, 0, 0, 0]);
        // Next 8 bytes: 1_000_000 as u64 LE.
        assert_eq!(
            &ix.data[4..],
            &1_000_000u64.to_le_bytes()
        );
    }

    #[test]
    fn sol_transfer_has_correct_accounts() {
        let from = [0xAAu8; 32];
        let to = [0xBBu8; 32];
        let ix = build_system_transfer_instruction(&from, &to, 500);

        assert_eq!(ix.accounts.len(), 2);
        assert_eq!(ix.accounts[0].pubkey, from);
        assert!(ix.accounts[0].is_signer);
        assert!(ix.accounts[0].is_writable);
        assert_eq!(ix.accounts[1].pubkey, to);
        assert!(!ix.accounts[1].is_signer);
        assert!(ix.accounts[1].is_writable);
    }

    #[test]
    fn sol_transfer_uses_system_program() {
        let from = [1u8; 32];
        let to = [2u8; 32];
        let ix = build_system_transfer_instruction(&from, &to, 1);
        assert_eq!(ix.program_id, SYSTEM_PROGRAM_ID);
    }

    #[test]
    fn build_sol_transfer_zero_lamports_fails() {
        let from = [1u8; 32];
        let to = [2u8; 32];
        let blockhash = [0u8; 32];
        let result = build_sol_transfer(&from, &to, 0, &blockhash);
        assert!(result.is_err());
    }

    // -- Transaction compilation -------------------------------------------

    #[test]
    fn compiled_transaction_account_order() {
        let from = [1u8; 32];
        let to = [2u8; 32];
        let blockhash = [0xAA; 32];
        let tx = build_sol_transfer(&from, &to, 1000, &blockhash).unwrap();

        // Accounts: from (signer+writable), to (writable), system program (read-only)
        assert_eq!(tx.account_keys.len(), 3);
        assert_eq!(tx.account_keys[0], from); // fee payer first
        assert_eq!(tx.num_required_signatures, 1);
        assert_eq!(tx.num_readonly_signed, 0);
        assert_eq!(tx.num_readonly_unsigned, 1); // system program
    }

    #[test]
    fn compiled_transaction_blockhash() {
        let from = [1u8; 32];
        let to = [2u8; 32];
        let blockhash = [0xBBu8; 32];
        let tx = build_sol_transfer(&from, &to, 42, &blockhash).unwrap();
        assert_eq!(tx.recent_blockhash, blockhash);
    }

    #[test]
    fn compiled_instruction_indices() {
        let from = [1u8; 32];
        let to = [2u8; 32];
        let blockhash = [0u8; 32];
        let tx = build_sol_transfer(&from, &to, 100, &blockhash).unwrap();

        assert_eq!(tx.compiled_instructions.len(), 1);
        let cix = &tx.compiled_instructions[0];

        // System program should be at some index.
        let sys_idx = tx
            .account_keys
            .iter()
            .position(|k| *k == SYSTEM_PROGRAM_ID)
            .unwrap();
        assert_eq!(cix.program_id_index, sys_idx as u8);

        // Account indices: [from_idx, to_idx]
        let from_idx = tx.account_keys.iter().position(|k| *k == from).unwrap();
        let to_idx = tx.account_keys.iter().position(|k| *k == to).unwrap();
        assert_eq!(cix.account_indices, vec![from_idx as u8, to_idx as u8]);
    }

    // -- Message serialization ---------------------------------------------

    #[test]
    fn serialize_message_starts_with_header() {
        let from = [1u8; 32];
        let to = [2u8; 32];
        let blockhash = [0u8; 32];
        let tx = build_sol_transfer(&from, &to, 100, &blockhash).unwrap();
        let msg = serialize_message(&tx).unwrap();

        assert_eq!(msg[0], tx.num_required_signatures);
        assert_eq!(msg[1], tx.num_readonly_signed);
        assert_eq!(msg[2], tx.num_readonly_unsigned);
    }

    #[test]
    fn serialize_message_contains_blockhash() {
        let from = [1u8; 32];
        let to = [2u8; 32];
        let blockhash = [0xCCu8; 32];
        let tx = build_sol_transfer(&from, &to, 500, &blockhash).unwrap();
        let msg = serialize_message(&tx).unwrap();

        // Blockhash sits after: header(3) + compact-u16(num_accounts) + 32*num_accounts
        let num_accounts = tx.account_keys.len();
        let compact_len = encode_compact_u16(num_accounts as u16).len();
        let offset = 3 + compact_len + 32 * num_accounts;
        assert_eq!(&msg[offset..offset + 32], &blockhash);
    }

    // -- Signing ------------------------------------------------------------

    #[test]
    fn sign_transaction_produces_valid_wire_bytes() {
        use ed25519_dalek::{Signature, VerifyingKey};

        let private_key = [0x42u8; 32];
        let signing_key = ed25519_dalek::SigningKey::from_bytes(&private_key);
        let verifying_key = signing_key.verifying_key();
        let from_pubkey: [u8; 32] = verifying_key.to_bytes();

        let to = [0xBBu8; 32];
        let blockhash = [0xCC; 32];

        let tx = build_sol_transfer(&from_pubkey, &to, 1_000_000, &blockhash).unwrap();
        let wire = sign_transaction(&tx, &private_key).unwrap();

        // Wire starts with compact-u16 num_signatures = 1 (one byte: 0x01).
        assert_eq!(wire[0], 0x01);

        // Next 64 bytes are the Ed25519 signature.
        let sig_bytes: [u8; 64] = wire[1..65].try_into().unwrap();
        let signature = Signature::from_bytes(&sig_bytes);

        // Remaining bytes are the message.
        let message_bytes = &wire[65..];

        // Verify the signature.
        let vk = VerifyingKey::from_bytes(&from_pubkey).unwrap();
        assert!(vk.verify_strict(message_bytes, &signature).is_ok());
    }

    #[test]
    fn sign_transaction_deterministic() {
        // Ed25519 signatures are deterministic for the same key + message.
        let private_key = [0x55u8; 32];
        let signing_key = ed25519_dalek::SigningKey::from_bytes(&private_key);
        let from_pubkey = signing_key.verifying_key().to_bytes();

        let to = [0x77u8; 32];
        let blockhash = [0x99; 32];

        let tx = build_sol_transfer(&from_pubkey, &to, 42, &blockhash).unwrap();
        let wire1 = sign_transaction(&tx, &private_key).unwrap();
        let wire2 = sign_transaction(&tx, &private_key).unwrap();
        assert_eq!(wire1, wire2);
    }

    // -- Self-transfer (from == to) ----------------------------------------

    #[test]
    fn self_transfer_deduplicates_accounts() {
        let key = [0xAAu8; 32];
        let blockhash = [0u8; 32];
        let tx = build_sol_transfer(&key, &key, 100, &blockhash).unwrap();

        // from and to are the same pubkey, so they should be deduplicated.
        // Accounts: key (signer+writable), system_program (read-only).
        assert_eq!(tx.account_keys.len(), 2);
        assert_eq!(tx.num_required_signatures, 1);
    }

    // -- compact-u16 decoding -----------------------------------------------

    #[test]
    fn decode_compact_u16_zero() {
        let (val, len) = decode_compact_u16(&[0x00]).unwrap();
        assert_eq!(val, 0);
        assert_eq!(len, 1);
    }

    #[test]
    fn decode_compact_u16_one_byte_max() {
        let (val, len) = decode_compact_u16(&[0x7f]).unwrap();
        assert_eq!(val, 127);
        assert_eq!(len, 1);
    }

    #[test]
    fn decode_compact_u16_two_bytes() {
        let (val, len) = decode_compact_u16(&[0x80, 0x01]).unwrap();
        assert_eq!(val, 128);
        assert_eq!(len, 2);
    }

    #[test]
    fn decode_compact_u16_three_bytes() {
        let (val, len) = decode_compact_u16(&[0x80, 0x80, 0x01]).unwrap();
        assert_eq!(val, 16384);
        assert_eq!(len, 3);
    }

    #[test]
    fn decode_compact_u16_roundtrip() {
        for value in [0u16, 1, 127, 128, 255, 256, 16383, 16384, 65535] {
            let encoded = encode_compact_u16(value);
            let (decoded, len) = decode_compact_u16(&encoded).unwrap();
            assert_eq!(decoded, value, "roundtrip failed for {value}");
            assert_eq!(len, encoded.len());
        }
    }

    #[test]
    fn decode_compact_u16_empty_input_fails() {
        assert!(decode_compact_u16(&[]).is_err());
    }

    // -- sign_sol_raw_transaction -------------------------------------------

    #[test]
    fn sign_raw_transaction_roundtrip() {
        // Build a transaction using the normal path, then re-sign it using
        // sign_sol_raw_transaction and verify the output matches.
        use ed25519_dalek::{Signature as DalekSig, VerifyingKey};

        let private_key = [0x42u8; 32];
        let signing_key = ed25519_dalek::SigningKey::from_bytes(&private_key);
        let from_pubkey = signing_key.verifying_key().to_bytes();

        let to = [0xBBu8; 32];
        let blockhash = [0xCC; 32];

        // Build and sign normally.
        let tx = build_sol_transfer(&from_pubkey, &to, 1_000_000, &blockhash).unwrap();
        let wire_normal = sign_transaction(&tx, &private_key).unwrap();

        // Now create the same wire format but with a zeroed signature slot
        // (simulating what a dApp would provide).
        let mut raw_unsigned = wire_normal.clone();
        // Zero out the signature (bytes 1..65 for a single-signer tx).
        for b in &mut raw_unsigned[1..65] {
            *b = 0;
        }

        // Re-sign using the raw transaction signer.
        let wire_raw = sign_sol_raw_transaction(&private_key, &raw_unsigned).unwrap();

        // The results should be identical.
        assert_eq!(wire_normal, wire_raw);

        // Verify the signature is valid.
        let sig_bytes: [u8; 64] = wire_raw[1..65].try_into().unwrap();
        let signature = DalekSig::from_bytes(&sig_bytes);
        let message_bytes = &wire_raw[65..];
        let vk = VerifyingKey::from_bytes(&from_pubkey).unwrap();
        assert!(vk.verify_strict(message_bytes, &signature).is_ok());
    }

    #[test]
    fn sign_raw_transaction_deterministic() {
        let private_key = [0x55u8; 32];
        let signing_key = ed25519_dalek::SigningKey::from_bytes(&private_key);
        let from_pubkey = signing_key.verifying_key().to_bytes();

        let to = [0x77u8; 32];
        let blockhash = [0x99; 32];

        let tx = build_sol_transfer(&from_pubkey, &to, 42, &blockhash).unwrap();
        let wire = sign_transaction(&tx, &private_key).unwrap();

        // Zero the signature to simulate an unsigned raw tx.
        let mut raw = wire.clone();
        for b in &mut raw[1..65] {
            *b = 0;
        }

        let signed1 = sign_sol_raw_transaction(&private_key, &raw).unwrap();
        let signed2 = sign_sol_raw_transaction(&private_key, &raw).unwrap();
        assert_eq!(signed1, signed2);
    }

    #[test]
    fn sign_raw_transaction_wrong_key_fails() {
        // Build a transaction for one keypair, try to sign with a different one.
        let private_key_a = [0x11u8; 32];
        let signing_key_a = ed25519_dalek::SigningKey::from_bytes(&private_key_a);
        let pubkey_a = signing_key_a.verifying_key().to_bytes();

        let private_key_b = [0x22u8; 32];

        let to = [0xBBu8; 32];
        let blockhash = [0xCC; 32];

        let tx = build_sol_transfer(&pubkey_a, &to, 1000, &blockhash).unwrap();
        let wire = sign_transaction(&tx, &private_key_a).unwrap();

        // Try to sign with key B -- should fail because pubkey B is not a signer.
        let result = sign_sol_raw_transaction(&private_key_b, &wire);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("not found"));
    }

    #[test]
    fn sign_raw_transaction_truncated_input_fails() {
        // A truncated transaction should fail gracefully.
        let result = sign_sol_raw_transaction(&[0x42u8; 32], &[0x01]);
        assert!(result.is_err());
    }

    #[test]
    fn sign_raw_transaction_empty_input_fails() {
        let result = sign_sol_raw_transaction(&[0x42u8; 32], &[]);
        assert!(result.is_err());
    }

    #[test]
    fn sign_raw_transaction_zero_signatures_fails() {
        // compact-u16(0) = 0x00, then some message bytes.
        let result = sign_sol_raw_transaction(&[0x42u8; 32], &[0x00, 0x01, 0x00, 0x00]);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("zero signatures"));
    }

    #[test]
    fn sign_raw_transaction_preserves_message() {
        // Verify that signing does not alter the message portion.
        let private_key = [0x42u8; 32];
        let signing_key = ed25519_dalek::SigningKey::from_bytes(&private_key);
        let from_pubkey = signing_key.verifying_key().to_bytes();

        let to = [0xBBu8; 32];
        let blockhash = [0xDD; 32];

        let tx = build_sol_transfer(&from_pubkey, &to, 500_000, &blockhash).unwrap();
        let wire = sign_transaction(&tx, &private_key).unwrap();

        // Zero signature to get "unsigned" tx.
        let mut raw = wire.clone();
        for b in &mut raw[1..65] {
            *b = 0;
        }

        let signed = sign_sol_raw_transaction(&private_key, &raw).unwrap();

        // Message portion (after compact-u16(1) + 64-byte sig) must be identical.
        assert_eq!(&signed[65..], &raw[65..]);
        assert_eq!(&signed[65..], &wire[65..]);
    }
}
