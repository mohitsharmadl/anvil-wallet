use bitcoin::absolute::LockTime;
use bitcoin::address::Address;
use bitcoin::hashes::Hash;
use bitcoin::script::ScriptBuf;
use bitcoin::secp256k1::{Message, Secp256k1, SecretKey};
use bitcoin::sighash::{EcdsaSighashType, SighashCache};
use bitcoin::transaction::Version;
use bitcoin::{
    Amount, CompressedPublicKey, OutPoint, Sequence, Transaction, TxIn, TxOut, Txid, Witness,
};

use crate::error::BtcError;
use crate::network::BtcNetwork;
use crate::utxo::Utxo;

/// Estimated virtual size of a P2WPKH input (in vbytes).
/// Breakdown: 41 bytes non-witness + ~27 witness bytes / 4 = ~68 vbytes per input.
const P2WPKH_INPUT_VBYTES: u64 = 68;

/// Estimated virtual size of any output (in vbytes).
const OUTPUT_VBYTES: u64 = 31;

/// Fixed transaction overhead (in vbytes): version + locktime + segwit marker/flag + counts.
const TX_OVERHEAD_VBYTES: u64 = 11;

/// An unsigned Bitcoin transaction ready for signing.
#[derive(Debug, Clone)]
pub struct UnsignedBtcTx {
    /// The bitcoin transaction with empty witnesses.
    pub tx: Transaction,
    /// The UTXOs being spent (in the same order as the transaction inputs).
    /// Needed for computing sighashes during signing.
    pub prevouts: Vec<TxOut>,
}

/// Estimate the fee for a P2WPKH transaction.
///
/// Computes `estimated_vsize * fee_rate_sat_vbyte` where the vsize is derived
/// from the number of inputs and outputs using P2WPKH weight estimates.
pub fn estimate_fee(num_inputs: usize, num_outputs: usize, fee_rate_sat_vbyte: u64) -> u64 {
    let vsize =
        TX_OVERHEAD_VBYTES + (num_inputs as u64 * P2WPKH_INPUT_VBYTES) + (num_outputs as u64 * OUTPUT_VBYTES);
    vsize * fee_rate_sat_vbyte
}

/// Build an unsigned P2WPKH Bitcoin transaction.
///
/// Selects UTXOs, constructs inputs/outputs, and returns an `UnsignedBtcTx`
/// ready for signing. A change output is added if the change exceeds the dust
/// threshold (546 sats).
pub fn build_p2wpkh_transaction(
    utxos: &[Utxo],
    recipient: &str,
    amount_sat: u64,
    change_address: &str,
    fee_rate_sat_vbyte: u64,
    network: BtcNetwork,
) -> Result<UnsignedBtcTx, BtcError> {
    let net = network.to_bitcoin_network();

    // Parse and validate the recipient address.
    let recipient_addr: Address = recipient
        .parse::<Address<bitcoin::address::NetworkUnchecked>>()
        .map_err(|e| BtcError::InvalidAddress(format!("invalid recipient address: {e}")))?
        .require_network(net)
        .map_err(|e| BtcError::InvalidAddress(format!("recipient address wrong network: {e}")))?;

    // Parse and validate the change address.
    let change_addr: Address = change_address
        .parse::<Address<bitcoin::address::NetworkUnchecked>>()
        .map_err(|e| BtcError::InvalidAddress(format!("invalid change address: {e}")))?
        .require_network(net)
        .map_err(|e| BtcError::InvalidAddress(format!("change address wrong network: {e}")))?;

    // Select UTXOs.
    let selection = crate::utxo::select_utxos(utxos, amount_sat, fee_rate_sat_vbyte)?;

    // Build inputs.
    let mut inputs = Vec::with_capacity(selection.selected.len());
    let mut prevouts = Vec::with_capacity(selection.selected.len());

    for utxo in &selection.selected {
        let txid: Txid = utxo
            .txid
            .parse()
            .map_err(|e| BtcError::TransactionBuildError(format!("invalid txid: {e}")))?;

        inputs.push(TxIn {
            previous_output: OutPoint::new(txid, utxo.vout),
            script_sig: ScriptBuf::new(), // Empty for segwit.
            sequence: Sequence::ENABLE_RBF_NO_LOCKTIME,
            witness: Witness::default(),
        });

        prevouts.push(TxOut {
            value: Amount::from_sat(utxo.amount_sat),
            script_pubkey: ScriptBuf::from(utxo.script_pubkey.clone()),
        });
    }

    // Determine number of outputs (1 or 2) to compute the fee accurately.
    let fee_2_outputs = estimate_fee(selection.selected.len(), 2, fee_rate_sat_vbyte);
    let fee_1_output = estimate_fee(selection.selected.len(), 1, fee_rate_sat_vbyte);

    let change_sat = selection.total_sat.saturating_sub(amount_sat + fee_2_outputs);
    let dust_threshold: u64 = 546;

    let (outputs, _fee) = if change_sat > dust_threshold {
        // Two outputs: recipient + change.
        let outs = vec![
            TxOut {
                value: Amount::from_sat(amount_sat),
                script_pubkey: recipient_addr.script_pubkey(),
            },
            TxOut {
                value: Amount::from_sat(change_sat),
                script_pubkey: change_addr.script_pubkey(),
            },
        ];
        (outs, fee_2_outputs)
    } else {
        // One output: no change (dust goes to fee).
        let outs = vec![TxOut {
            value: Amount::from_sat(amount_sat),
            script_pubkey: recipient_addr.script_pubkey(),
        }];
        (outs, fee_1_output + change_sat)
    };

    let tx = Transaction {
        version: Version::TWO,
        lock_time: LockTime::ZERO,
        input: inputs,
        output: outputs,
    };

    Ok(UnsignedBtcTx { tx, prevouts })
}

/// Sign an unsigned P2WPKH transaction with the given private key.
///
/// All inputs are assumed to be controlled by the same key. The private key
/// must be a 32-byte secp256k1 scalar. Returns the serialized signed
/// transaction ready for broadcast.
pub fn sign_transaction(
    unsigned_tx: &UnsignedBtcTx,
    private_key: &[u8; 32],
    _network: BtcNetwork,
) -> Result<Vec<u8>, BtcError> {
    let secp = Secp256k1::new();
    let secret_key = SecretKey::from_slice(private_key)
        .map_err(|e| BtcError::InvalidPrivateKey(format!("invalid secret key: {e}")))?;
    let public_key = bitcoin::secp256k1::PublicKey::from_secret_key(&secp, &secret_key);
    let compressed_pk = CompressedPublicKey(public_key);

    let mut signed_tx = unsigned_tx.tx.clone();

    // We need to sign each input.
    for input_index in 0..signed_tx.input.len() {
        let script_code = ScriptBuf::new_p2wpkh(&compressed_pk.wpubkey_hash());

        let mut sighash_cache = SighashCache::new(&unsigned_tx.tx);
        let sighash = sighash_cache
            .p2wpkh_signature_hash(
                input_index,
                &script_code,
                unsigned_tx.prevouts[input_index].value,
                EcdsaSighashType::All,
            )
            .map_err(|e| BtcError::SigningError(format!("sighash computation failed: {e}")))?;

        let msg = Message::from_digest(sighash.to_byte_array());
        let signature = secp.sign_ecdsa(&msg, &secret_key);

        // Serialize signature in DER + sighash type byte.
        let mut sig_bytes = signature.serialize_der().to_vec();
        sig_bytes.push(EcdsaSighashType::All as u8);

        // Build witness: [signature, pubkey].
        let mut witness = Witness::new();
        witness.push(&sig_bytes);
        witness.push(&public_key.serialize());

        signed_tx.input[input_index].witness = witness;
    }

    Ok(bitcoin::consensus::serialize(&signed_tx))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::utxo::Utxo;

    #[test]
    fn estimate_fee_basic() {
        // 1 input, 2 outputs: 11 + 68 + 62 = 141 vbytes at 1 sat/vbyte = 141
        let fee = estimate_fee(1, 2, 1);
        assert_eq!(fee, 141);
    }

    #[test]
    fn estimate_fee_scales_with_inputs() {
        let fee_1 = estimate_fee(1, 2, 10);
        let fee_2 = estimate_fee(2, 2, 10);
        assert!(fee_2 > fee_1);
        assert_eq!(fee_2 - fee_1, P2WPKH_INPUT_VBYTES * 10);
    }

    #[test]
    fn estimate_fee_zero_rate() {
        assert_eq!(estimate_fee(5, 5, 0), 0);
    }

    fn make_test_utxo(txid: &str, vout: u32, amount_sat: u64, script_hex: &str) -> Utxo {
        Utxo {
            txid: txid.to_string(),
            vout,
            amount_sat,
            script_pubkey: hex::decode(script_hex).unwrap(),
        }
    }

    #[test]
    fn build_transaction_single_input() {
        // Use a well-formed txid (64 hex chars).
        let txid = "a".repeat(64);

        // P2WPKH scriptPubKey: OP_0 <20-byte hash>
        let script_hex = format!("0014{}", "ab".repeat(20));

        let utxos = vec![make_test_utxo(&txid, 0, 100_000, &script_hex)];

        let result = build_p2wpkh_transaction(
            &utxos,
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
            50_000,
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
            1,
            BtcNetwork::Mainnet,
        );

        assert!(result.is_ok());
        let unsigned = result.unwrap();
        assert_eq!(unsigned.tx.input.len(), 1);
        // Should have 2 outputs (recipient + change) given enough value.
        assert_eq!(unsigned.tx.output.len(), 2);
        assert_eq!(unsigned.tx.output[0].value.to_sat(), 50_000);
    }

    #[test]
    fn build_transaction_dust_change_omitted() {
        let txid = "b".repeat(64);
        let script_hex = format!("0014{}", "cd".repeat(20));

        // Amount very close to total, so change < dust threshold.
        // 1 input, 1 output, 1 sat/vbyte: fee ~110 vbytes.
        // total=100_000, amount=99_800 => change = 200 - fee ~= small (< 546).
        let utxos = vec![make_test_utxo(&txid, 0, 100_000, &script_hex)];

        let result = build_p2wpkh_transaction(
            &utxos,
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
            99_700,
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
            1,
            BtcNetwork::Mainnet,
        );

        assert!(result.is_ok());
        let unsigned = result.unwrap();
        // Change should be dust, so only 1 output.
        assert_eq!(unsigned.tx.output.len(), 1);
    }

    #[test]
    fn build_transaction_insufficient_funds() {
        let txid = "c".repeat(64);
        let script_hex = format!("0014{}", "ef".repeat(20));

        let utxos = vec![make_test_utxo(&txid, 0, 1_000, &script_hex)];

        let result = build_p2wpkh_transaction(
            &utxos,
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
            500_000,
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
            1,
            BtcNetwork::Mainnet,
        );

        assert!(result.is_err());
    }

    #[test]
    fn build_transaction_invalid_recipient() {
        let txid = "d".repeat(64);
        let script_hex = format!("0014{}", "11".repeat(20));

        let utxos = vec![make_test_utxo(&txid, 0, 100_000, &script_hex)];

        let result = build_p2wpkh_transaction(
            &utxos,
            "not_a_valid_address",
            50_000,
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
            1,
            BtcNetwork::Mainnet,
        );

        assert!(result.is_err());
    }

    #[test]
    fn build_transaction_wrong_network() {
        let txid = "e".repeat(64);
        let script_hex = format!("0014{}", "22".repeat(20));

        let utxos = vec![make_test_utxo(&txid, 0, 100_000, &script_hex)];

        // Use a mainnet address but specify testnet.
        let result = build_p2wpkh_transaction(
            &utxos,
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
            50_000,
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
            1,
            BtcNetwork::Testnet,
        );

        assert!(result.is_err());
    }

    #[test]
    fn sign_transaction_produces_valid_bytes() {
        let txid = "a".repeat(64);
        let script_hex = format!("0014{}", "ab".repeat(20));

        let utxos = vec![make_test_utxo(&txid, 0, 100_000, &script_hex)];

        let unsigned = build_p2wpkh_transaction(
            &utxos,
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
            50_000,
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
            1,
            BtcNetwork::Mainnet,
        )
        .unwrap();

        // Use a known valid private key.
        let privkey = [0xcd; 32];
        let result = sign_transaction(&unsigned, &privkey, BtcNetwork::Mainnet);

        assert!(result.is_ok());
        let signed_bytes = result.unwrap();
        // Signed transaction should be non-empty and longer than unsigned serialization.
        assert!(!signed_bytes.is_empty());
        // A signed segwit tx typically starts with version bytes.
        assert!(signed_bytes.len() > 100);
    }

    #[test]
    fn sign_transaction_invalid_key() {
        let txid = "f".repeat(64);
        let script_hex = format!("0014{}", "33".repeat(20));

        let utxos = vec![make_test_utxo(&txid, 0, 100_000, &script_hex)];

        let unsigned = build_p2wpkh_transaction(
            &utxos,
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
            50_000,
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
            1,
            BtcNetwork::Mainnet,
        )
        .unwrap();

        // All-zero is not a valid secp256k1 private key.
        let bad_key = [0u8; 32];
        let result = sign_transaction(&unsigned, &bad_key, BtcNetwork::Mainnet);
        assert!(result.is_err());
    }

    #[test]
    fn build_and_sign_roundtrip_testnet() {
        let txid = "ab".repeat(32);
        let script_hex = format!("0014{}", "44".repeat(20));

        let utxos = vec![make_test_utxo(&txid, 0, 200_000, &script_hex)];

        // Use testnet addresses (tb1q...).
        let secp = Secp256k1::new();
        let secret_key = SecretKey::from_slice(&[0x42; 32]).unwrap();
        let public_key = bitcoin::secp256k1::PublicKey::from_secret_key(&secp, &secret_key);
        let compressed = CompressedPublicKey(public_key);
        let addr = bitcoin::Address::p2wpkh(&compressed, bitcoin::Network::Testnet);
        let addr_str = addr.to_string();

        let unsigned = build_p2wpkh_transaction(
            &utxos,
            &addr_str,
            100_000,
            &addr_str,
            2,
            BtcNetwork::Testnet,
        )
        .unwrap();

        let signed = sign_transaction(&unsigned, &[0x42; 32], BtcNetwork::Testnet);
        assert!(signed.is_ok());
        assert!(signed.unwrap().len() > 100);
    }
}
