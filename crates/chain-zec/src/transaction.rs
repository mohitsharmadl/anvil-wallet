use k256::ecdsa::{signature::hazmat::PrehashSigner, Signature, SigningKey};

use crate::address::{self, ZecNetwork};
use crate::error::ZecError;

/// Zcash v5 transaction constants (NU5 era).
const TX_VERSION: u32 = 0x80000005; // fOverwintered | v5
const VERSION_GROUP_ID: u32 = 0x26A7270A;
const CONSENSUS_BRANCH_ID_MAINNET: u32 = 0xC2D6D0B4; // NU5
const CONSENSUS_BRANCH_ID_TESTNET: u32 = 0xC2D6D0B4; // NU5 (same)

/// SIGHASH_ALL constant.
const SIGHASH_ALL: u8 = 0x01;

/// Dust threshold for Zcash (in zatoshi).
const DUST_THRESHOLD: u64 = 546;

/// Transaction overhead estimate in bytes.
const TX_OVERHEAD_BYTES: u64 = 46; // header(4) + vgid(4) + branch(4) + lock(4) + expiry(4) + counts(~6) + sapling(1) + orchard(1) + ~18 margin
/// Estimated bytes per transparent input.
const INPUT_BYTES: u64 = 148; // outpoint(36) + scriptSig(~107 for P2PKH) + sequence(4) + overhead
/// Estimated bytes per transparent output.
const OUTPUT_BYTES: u64 = 34;

/// A UTXO to spend in a Zcash transaction.
#[derive(Debug, Clone)]
pub struct ZecUtxo {
    pub txid: String,
    pub vout: u32,
    pub amount_zatoshi: u64,
    /// The scriptPubKey of the UTXO (typically 25 bytes for P2PKH).
    pub script_pubkey: Vec<u8>,
}

/// An unsigned Zcash v5 transparent transaction.
#[derive(Debug)]
pub struct UnsignedZecTx {
    pub version: u32,
    pub version_group_id: u32,
    pub consensus_branch_id: u32,
    pub lock_time: u32,
    pub expiry_height: u32,
    pub inputs: Vec<TxInput>,
    pub outputs: Vec<TxOutput>,
}

#[derive(Debug, Clone)]
pub struct TxInput {
    /// Previous transaction hash (32 bytes, internal byte order).
    pub prev_txid: [u8; 32],
    pub prev_vout: u32,
    /// Script code for signing (P2PKH scriptPubKey of the UTXO).
    pub script_pubkey: Vec<u8>,
    /// Amount of the UTXO being spent (needed for sighash).
    pub amount: u64,
    pub sequence: u32,
}

#[derive(Debug, Clone)]
pub struct TxOutput {
    pub amount: u64,
    pub script_pubkey: Vec<u8>,
}

/// Estimate the fee for a transparent Zcash transaction.
pub fn estimate_fee(num_inputs: usize, num_outputs: usize, fee_rate_zat_byte: u64) -> u64 {
    let size = TX_OVERHEAD_BYTES
        + (num_inputs as u64 * INPUT_BYTES)
        + (num_outputs as u64 * OUTPUT_BYTES);
    size * fee_rate_zat_byte
}

/// Build a P2PKH scriptPubKey: OP_DUP OP_HASH160 <20-byte hash> OP_EQUALVERIFY OP_CHECKSIG
fn p2pkh_script(pubkey_hash: &[u8; 20]) -> Vec<u8> {
    let mut script = Vec::with_capacity(25);
    script.push(0x76); // OP_DUP
    script.push(0xA9); // OP_HASH160
    script.push(0x14); // Push 20 bytes
    script.extend_from_slice(pubkey_hash);
    script.push(0x88); // OP_EQUALVERIFY
    script.push(0xAC); // OP_CHECKSIG
    script
}

/// Build an unsigned Zcash v5 transparent transaction.
///
/// Uses a simple greedy UTXO selection (largest first). Adds a change output
/// if change exceeds the dust threshold.
pub fn build_transparent_transaction(
    utxos: &[ZecUtxo],
    recipient: &str,
    amount_zat: u64,
    change_address: &str,
    fee_rate_zat_byte: u64,
    network: ZecNetwork,
    expiry_height: u32,
) -> Result<UnsignedZecTx, ZecError> {
    let recipient_hash = address::address_to_pubkey_hash(recipient)?;
    let change_hash = address::address_to_pubkey_hash(change_address)?;

    // Sort UTXOs by amount (largest first) for greedy selection.
    let mut sorted: Vec<&ZecUtxo> = utxos.iter().collect();
    sorted.sort_by(|a, b| b.amount_zatoshi.cmp(&a.amount_zatoshi));

    // Select UTXOs
    let mut selected = Vec::new();
    let mut total_in: u64 = 0;

    for utxo in &sorted {
        selected.push(*utxo);
        total_in += utxo.amount_zatoshi;

        let fee = estimate_fee(selected.len(), 2, fee_rate_zat_byte);
        if total_in >= amount_zat + fee {
            break;
        }
    }

    let fee_2out = estimate_fee(selected.len(), 2, fee_rate_zat_byte);
    let fee_1out = estimate_fee(selected.len(), 1, fee_rate_zat_byte);

    if total_in < amount_zat + fee_1out {
        return Err(ZecError::InsufficientFunds {
            needed: amount_zat + fee_1out,
            available: total_in,
        });
    }

    // Build inputs
    let mut inputs = Vec::with_capacity(selected.len());
    for utxo in &selected {
        let txid_bytes = parse_txid(&utxo.txid)?;
        inputs.push(TxInput {
            prev_txid: txid_bytes,
            prev_vout: utxo.vout,
            script_pubkey: utxo.script_pubkey.clone(),
            amount: utxo.amount_zatoshi,
            sequence: 0xFFFFFFFE, // Enable nLockTime but no RBF
        });
    }

    // Build outputs
    let change_zat = total_in.saturating_sub(amount_zat + fee_2out);
    let outputs = if change_zat > DUST_THRESHOLD {
        vec![
            TxOutput {
                amount: amount_zat,
                script_pubkey: p2pkh_script(&recipient_hash),
            },
            TxOutput {
                amount: change_zat,
                script_pubkey: p2pkh_script(&change_hash),
            },
        ]
    } else {
        vec![TxOutput {
            amount: amount_zat,
            script_pubkey: p2pkh_script(&recipient_hash),
        }]
    };

    let branch_id = match network {
        ZecNetwork::Mainnet => CONSENSUS_BRANCH_ID_MAINNET,
        ZecNetwork::Testnet => CONSENSUS_BRANCH_ID_TESTNET,
    };

    Ok(UnsignedZecTx {
        version: TX_VERSION,
        version_group_id: VERSION_GROUP_ID,
        consensus_branch_id: branch_id,
        lock_time: 0,
        expiry_height,
        inputs,
        outputs,
    })
}

/// Sign an unsigned Zcash v5 transaction with the given private key.
///
/// All transparent inputs are assumed to be controlled by the same key.
/// Returns the serialized signed transaction bytes ready for broadcast.
pub fn sign_transaction(
    unsigned_tx: &UnsignedZecTx,
    private_key: &[u8; 32],
) -> Result<Vec<u8>, ZecError> {
    let signing_key = SigningKey::from_bytes(private_key.into())
        .map_err(|e| ZecError::InvalidPrivateKey(format!("invalid secp256k1 key: {e}")))?;
    let verifying_key = signing_key.verifying_key();
    let pubkey_bytes: [u8; 33] = verifying_key
        .to_sec1_bytes()
        .as_ref()
        .try_into()
        .map_err(|_| ZecError::SigningError("invalid public key".into()))?;

    // Sign each input
    let mut script_sigs: Vec<Vec<u8>> = Vec::with_capacity(unsigned_tx.inputs.len());

    for input_index in 0..unsigned_tx.inputs.len() {
        let sighash = compute_sighash(unsigned_tx, input_index)?;

        let sig: Signature = signing_key
            .sign_prehash(&sighash)
            .map_err(|e| ZecError::SigningError(format!("ECDSA signing failed: {e}")))?;

        // DER-encode the signature + sighash type byte
        let der_sig = sig.to_der();
        let mut sig_with_hashtype = der_sig.as_bytes().to_vec();
        sig_with_hashtype.push(SIGHASH_ALL);

        // P2PKH scriptSig: <sig_len> <sig+hashtype> <pubkey_len> <pubkey>
        let mut script_sig = Vec::new();
        script_sig.push(sig_with_hashtype.len() as u8);
        script_sig.extend_from_slice(&sig_with_hashtype);
        script_sig.push(33); // compressed pubkey length
        script_sig.extend_from_slice(&pubkey_bytes);

        script_sigs.push(script_sig);
    }

    // Serialize the signed transaction
    serialize_v5_tx(unsigned_tx, &script_sigs)
}

/// Compute the ZIP-244 signature digest for a specific transparent input.
fn compute_sighash(tx: &UnsignedZecTx, input_index: usize) -> Result<[u8; 32], ZecError> {
    let header_digest = compute_header_digest(tx);
    let transparent_sig_digest = compute_transparent_sig_digest(tx, input_index)?;
    let sapling_digest = blake2b_256(b"ZTxIdSaplingHash", &[]);
    let orchard_digest = blake2b_256(b"ZTxIdOrchardHash", &[]);

    // sig_digest = BLAKE2b-256("ZcashTxHash_" || branch_id, header || transparent_sig || sapling || orchard)
    let mut personalization = [0u8; 16];
    personalization[..12].copy_from_slice(b"ZcashTxHash_");
    personalization[12..16].copy_from_slice(&tx.consensus_branch_id.to_le_bytes());

    let mut data = Vec::new();
    data.extend_from_slice(&header_digest);
    data.extend_from_slice(&transparent_sig_digest);
    data.extend_from_slice(&sapling_digest);
    data.extend_from_slice(&orchard_digest);

    Ok(blake2b_256(&personalization, &data))
}

/// ZIP-244 header digest.
fn compute_header_digest(tx: &UnsignedZecTx) -> [u8; 32] {
    let mut data = Vec::with_capacity(20);
    data.extend_from_slice(&tx.version.to_le_bytes());
    data.extend_from_slice(&tx.version_group_id.to_le_bytes());
    data.extend_from_slice(&tx.consensus_branch_id.to_le_bytes());
    data.extend_from_slice(&tx.lock_time.to_le_bytes());
    data.extend_from_slice(&tx.expiry_height.to_le_bytes());
    blake2b_256(b"ZTxIdHeadersHash", &data)
}

/// ZIP-244 transparent sig digest for SIGHASH_ALL.
fn compute_transparent_sig_digest(
    tx: &UnsignedZecTx,
    input_index: usize,
) -> Result<[u8; 32], ZecError> {
    if input_index >= tx.inputs.len() {
        return Err(ZecError::SigningError("input index out of bounds".into()));
    }

    let prevouts_digest = {
        let mut data = Vec::new();
        for inp in &tx.inputs {
            data.extend_from_slice(&inp.prev_txid);
            data.extend_from_slice(&inp.prev_vout.to_le_bytes());
        }
        blake2b_256(b"ZTxIdPrevoutHash", &data)
    };

    let amounts_digest = {
        let mut data = Vec::new();
        for inp in &tx.inputs {
            data.extend_from_slice(&(inp.amount as i64).to_le_bytes());
        }
        blake2b_256(b"ZTxIdAmountsHash", &data)
    };

    let scriptpubkeys_digest = {
        let mut data = Vec::new();
        for inp in &tx.inputs {
            write_compact_size(&mut data, inp.script_pubkey.len() as u64);
            data.extend_from_slice(&inp.script_pubkey);
        }
        blake2b_256(b"ZTxIdScriptsHash", &data)
    };

    let sequence_digest = {
        let mut data = Vec::new();
        for inp in &tx.inputs {
            data.extend_from_slice(&inp.sequence.to_le_bytes());
        }
        blake2b_256(b"ZTxIdSequencHash", &data)
    };

    let outputs_digest = {
        let mut data = Vec::new();
        for out in &tx.outputs {
            data.extend_from_slice(&(out.amount as i64).to_le_bytes());
            write_compact_size(&mut data, out.script_pubkey.len() as u64);
            data.extend_from_slice(&out.script_pubkey);
        }
        blake2b_256(b"ZTxIdOutputsHash", &data)
    };

    // Per-input data
    let inp = &tx.inputs[input_index];
    let txin_digest = {
        let mut data = Vec::new();
        data.extend_from_slice(&inp.prev_txid);
        data.extend_from_slice(&inp.prev_vout.to_le_bytes());
        data.extend_from_slice(&(inp.amount as i64).to_le_bytes());
        write_compact_size(&mut data, inp.script_pubkey.len() as u64);
        data.extend_from_slice(&inp.script_pubkey);
        data.extend_from_slice(&inp.sequence.to_le_bytes());
        blake2b_256(b"Zcash___TxInHash", &data)
    };

    // Combine into transparent_sig_digest
    let mut combined = Vec::new();
    combined.push(SIGHASH_ALL);
    combined.extend_from_slice(&prevouts_digest);
    combined.extend_from_slice(&amounts_digest);
    combined.extend_from_slice(&scriptpubkeys_digest);
    combined.extend_from_slice(&sequence_digest);
    combined.extend_from_slice(&outputs_digest);
    combined.extend_from_slice(&txin_digest);

    Ok(blake2b_256(b"ZTxIdTranspaHash", &combined))
}

/// Serialize a signed Zcash v5 transaction (transparent only).
fn serialize_v5_tx(
    tx: &UnsignedZecTx,
    script_sigs: &[Vec<u8>],
) -> Result<Vec<u8>, ZecError> {
    let mut buf = Vec::with_capacity(512);

    // Header fields
    buf.extend_from_slice(&tx.version.to_le_bytes());
    buf.extend_from_slice(&tx.version_group_id.to_le_bytes());
    buf.extend_from_slice(&tx.consensus_branch_id.to_le_bytes());
    buf.extend_from_slice(&tx.lock_time.to_le_bytes());
    buf.extend_from_slice(&tx.expiry_height.to_le_bytes());

    // Transparent inputs
    write_compact_size(&mut buf, tx.inputs.len() as u64);
    for (i, inp) in tx.inputs.iter().enumerate() {
        buf.extend_from_slice(&inp.prev_txid);
        buf.extend_from_slice(&inp.prev_vout.to_le_bytes());
        let sig = &script_sigs[i];
        write_compact_size(&mut buf, sig.len() as u64);
        buf.extend_from_slice(sig);
        buf.extend_from_slice(&inp.sequence.to_le_bytes());
    }

    // Transparent outputs
    write_compact_size(&mut buf, tx.outputs.len() as u64);
    for out in &tx.outputs {
        buf.extend_from_slice(&(out.amount as i64).to_le_bytes());
        write_compact_size(&mut buf, out.script_pubkey.len() as u64);
        buf.extend_from_slice(&out.script_pubkey);
    }

    // Sapling (empty)
    write_compact_size(&mut buf, 0); // nSpendsSapling
    write_compact_size(&mut buf, 0); // nOutputsSapling

    // Orchard (empty)
    write_compact_size(&mut buf, 0); // nActionsOrchard

    Ok(buf)
}

/// BLAKE2b-256 with a 16-byte personalization string.
fn blake2b_256(personalization: &[u8], data: &[u8]) -> [u8; 32] {
    let mut persona = [0u8; 16];
    let len = personalization.len().min(16);
    persona[..len].copy_from_slice(&personalization[..len]);

    let hash = blake2b_simd::Params::new()
        .hash_length(32)
        .personal(&persona)
        .hash(data);

    let mut result = [0u8; 32];
    result.copy_from_slice(hash.as_bytes());
    result
}

/// Parse a hex txid string (big-endian display) to internal byte order (little-endian).
fn parse_txid(txid_hex: &str) -> Result<[u8; 32], ZecError> {
    let bytes = hex::decode(txid_hex)
        .map_err(|e| ZecError::TransactionBuildError(format!("invalid txid hex: {e}")))?;
    if bytes.len() != 32 {
        return Err(ZecError::TransactionBuildError(format!(
            "txid must be 32 bytes, got {}",
            bytes.len()
        )));
    }
    let mut result = [0u8; 32];
    // Reverse to internal byte order
    for (i, &b) in bytes.iter().rev().enumerate() {
        result[i] = b;
    }
    Ok(result)
}

/// Write a Bitcoin-style CompactSize (variable-length integer).
fn write_compact_size(buf: &mut Vec<u8>, val: u64) {
    if val < 0xFD {
        buf.push(val as u8);
    } else if val <= 0xFFFF {
        buf.push(0xFD);
        buf.extend_from_slice(&(val as u16).to_le_bytes());
    } else if val <= 0xFFFFFFFF {
        buf.push(0xFE);
        buf.extend_from_slice(&(val as u32).to_le_bytes());
    } else {
        buf.push(0xFF);
        buf.extend_from_slice(&val.to_le_bytes());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_test_utxo(txid: &str, vout: u32, amount: u64) -> ZecUtxo {
        // P2PKH scriptPubKey for a known pubkey hash
        let pubkey_hash = [0xAB; 20];
        let script = p2pkh_script(&pubkey_hash);
        ZecUtxo {
            txid: txid.to_string(),
            vout,
            amount_zatoshi: amount,
            script_pubkey: script,
        }
    }

    #[test]
    fn estimate_fee_basic() {
        let fee = estimate_fee(1, 2, 1);
        // 46 + 148 + 68 = 262
        assert!(fee > 0);
        assert!(fee < 1000);
    }

    #[test]
    fn estimate_fee_scales_with_inputs() {
        let fee_1 = estimate_fee(1, 2, 10);
        let fee_2 = estimate_fee(2, 2, 10);
        assert!(fee_2 > fee_1);
        assert_eq!(fee_2 - fee_1, INPUT_BYTES * 10);
    }

    #[test]
    fn estimate_fee_zero_rate() {
        assert_eq!(estimate_fee(5, 5, 0), 0);
    }

    #[test]
    fn p2pkh_script_format() {
        let hash = [0x42; 20];
        let script = p2pkh_script(&hash);
        assert_eq!(script.len(), 25);
        assert_eq!(script[0], 0x76); // OP_DUP
        assert_eq!(script[1], 0xA9); // OP_HASH160
        assert_eq!(script[2], 0x14); // Push 20
        assert_eq!(&script[3..23], &hash);
        assert_eq!(script[23], 0x88); // OP_EQUALVERIFY
        assert_eq!(script[24], 0xAC); // OP_CHECKSIG
    }

    #[test]
    fn build_transaction_single_input() {
        let txid = "a".repeat(64);
        let utxos = vec![make_test_utxo(&txid, 0, 10_000_000)]; // 0.1 ZEC

        // Use a known compressed pubkey to derive addresses
        let pubkey_hex = "0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798";
        let pubkey: [u8; 33] = hex::decode(pubkey_hex).unwrap().try_into().unwrap();

        let addr = address::pubkey_to_t_address(&pubkey, ZecNetwork::Mainnet).unwrap();

        let result = build_transparent_transaction(
            &utxos,
            &addr,
            5_000_000,
            &addr,
            1,
            ZecNetwork::Mainnet,
            1_000_000,
        );

        assert!(result.is_ok());
        let tx = result.unwrap();
        assert_eq!(tx.inputs.len(), 1);
        assert_eq!(tx.outputs.len(), 2); // recipient + change
        assert_eq!(tx.outputs[0].amount, 5_000_000);
        assert_eq!(tx.version, TX_VERSION);
        assert_eq!(tx.consensus_branch_id, CONSENSUS_BRANCH_ID_MAINNET);
    }

    #[test]
    fn build_transaction_dust_change_omitted() {
        let txid = "b".repeat(64);
        // Amount close to total so change < dust
        let utxos = vec![make_test_utxo(&txid, 0, 1_000_000)];

        let pubkey_hex = "0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798";
        let pubkey: [u8; 33] = hex::decode(pubkey_hex).unwrap().try_into().unwrap();
        let addr = address::pubkey_to_t_address(&pubkey, ZecNetwork::Mainnet).unwrap();

        let result = build_transparent_transaction(
            &utxos,
            &addr,
            999_500,
            &addr,
            1,
            ZecNetwork::Mainnet,
            1_000_000,
        );

        assert!(result.is_ok());
        let tx = result.unwrap();
        assert_eq!(tx.outputs.len(), 1); // no change output
    }

    #[test]
    fn build_transaction_insufficient_funds() {
        let txid = "c".repeat(64);
        let utxos = vec![make_test_utxo(&txid, 0, 1_000)];

        let pubkey_hex = "0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798";
        let pubkey: [u8; 33] = hex::decode(pubkey_hex).unwrap().try_into().unwrap();
        let addr = address::pubkey_to_t_address(&pubkey, ZecNetwork::Mainnet).unwrap();

        let result = build_transparent_transaction(
            &utxos,
            &addr,
            500_000_000,
            &addr,
            1,
            ZecNetwork::Mainnet,
            1_000_000,
        );

        assert!(result.is_err());
        match result.unwrap_err() {
            ZecError::InsufficientFunds { .. } => {}
            other => panic!("expected InsufficientFunds, got: {other}"),
        }
    }

    #[test]
    fn sign_transaction_produces_valid_bytes() {
        let txid = "a".repeat(64);
        let utxos = vec![make_test_utxo(&txid, 0, 10_000_000)];

        let pubkey_hex = "0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798";
        let pubkey: [u8; 33] = hex::decode(pubkey_hex).unwrap().try_into().unwrap();
        let addr = address::pubkey_to_t_address(&pubkey, ZecNetwork::Mainnet).unwrap();

        let unsigned = build_transparent_transaction(
            &utxos,
            &addr,
            5_000_000,
            &addr,
            1,
            ZecNetwork::Mainnet,
            1_000_000,
        )
        .unwrap();

        // Private key = 1
        let mut privkey = [0u8; 32];
        privkey[31] = 1;

        let signed = sign_transaction(&unsigned, &privkey).unwrap();
        assert!(!signed.is_empty());
        assert!(signed.len() > 100);

        // First 4 bytes should be the version
        let ver = u32::from_le_bytes(signed[0..4].try_into().unwrap());
        assert_eq!(ver, TX_VERSION);
    }

    #[test]
    fn sign_transaction_deterministic() {
        let txid = "d".repeat(64);
        let utxos = vec![make_test_utxo(&txid, 0, 5_000_000)];

        let pubkey_hex = "0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798";
        let pubkey: [u8; 33] = hex::decode(pubkey_hex).unwrap().try_into().unwrap();
        let addr = address::pubkey_to_t_address(&pubkey, ZecNetwork::Mainnet).unwrap();

        let unsigned = build_transparent_transaction(
            &utxos, &addr, 2_000_000, &addr, 1, ZecNetwork::Mainnet, 1_000_000,
        )
        .unwrap();

        let mut privkey = [0u8; 32];
        privkey[31] = 1;

        let signed1 = sign_transaction(&unsigned, &privkey).unwrap();
        let signed2 = sign_transaction(&unsigned, &privkey).unwrap();
        assert_eq!(signed1, signed2);
    }

    #[test]
    fn sign_transaction_invalid_key() {
        let txid = "e".repeat(64);
        let utxos = vec![make_test_utxo(&txid, 0, 5_000_000)];

        let pubkey_hex = "0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798";
        let pubkey: [u8; 33] = hex::decode(pubkey_hex).unwrap().try_into().unwrap();
        let addr = address::pubkey_to_t_address(&pubkey, ZecNetwork::Mainnet).unwrap();

        let unsigned = build_transparent_transaction(
            &utxos, &addr, 2_000_000, &addr, 1, ZecNetwork::Mainnet, 1_000_000,
        )
        .unwrap();

        let bad_key = [0u8; 32]; // zero is not a valid secp256k1 key
        assert!(sign_transaction(&unsigned, &bad_key).is_err());
    }

    #[test]
    fn blake2b_256_known_output() {
        // Just verify the function doesn't panic and returns 32 bytes
        let result = blake2b_256(b"test_personalize", b"hello");
        assert_eq!(result.len(), 32);
        assert!(result.iter().any(|&b| b != 0));
    }

    #[test]
    fn blake2b_256_different_personalization_different_output() {
        let r1 = blake2b_256(b"personalizatio1\0", b"data");
        let r2 = blake2b_256(b"personalizatio2\0", b"data");
        assert_ne!(r1, r2);
    }

    #[test]
    fn parse_txid_reverses_bytes() {
        let hex = "0100000000000000000000000000000000000000000000000000000000000002";
        let result = parse_txid(hex).unwrap();
        assert_eq!(result[0], 0x02);
        assert_eq!(result[31], 0x01);
    }

    #[test]
    fn parse_txid_invalid_hex() {
        assert!(parse_txid("not_hex").is_err());
    }

    #[test]
    fn parse_txid_wrong_length() {
        assert!(parse_txid("0102").is_err());
    }

    #[test]
    fn write_compact_size_small() {
        let mut buf = Vec::new();
        write_compact_size(&mut buf, 42);
        assert_eq!(buf, vec![42]);
    }

    #[test]
    fn write_compact_size_medium() {
        let mut buf = Vec::new();
        write_compact_size(&mut buf, 300);
        assert_eq!(buf.len(), 3);
        assert_eq!(buf[0], 0xFD);
    }

    #[test]
    fn header_digest_deterministic() {
        let tx = UnsignedZecTx {
            version: TX_VERSION,
            version_group_id: VERSION_GROUP_ID,
            consensus_branch_id: CONSENSUS_BRANCH_ID_MAINNET,
            lock_time: 0,
            expiry_height: 1_000_000,
            inputs: vec![],
            outputs: vec![],
        };
        let d1 = compute_header_digest(&tx);
        let d2 = compute_header_digest(&tx);
        assert_eq!(d1, d2);
    }
}
