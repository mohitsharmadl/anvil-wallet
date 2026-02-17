use crate::error::BtcError;

/// A single unspent transaction output (UTXO).
#[derive(Debug, Clone)]
pub struct Utxo {
    /// Transaction ID as a hex string (big-endian / display order).
    pub txid: String,
    /// Output index within the transaction.
    pub vout: u32,
    /// Value in satoshis.
    pub amount_sat: u64,
    /// The locking script (scriptPubKey) serialized bytes.
    pub script_pubkey: Vec<u8>,
}

/// Result of UTXO selection: the chosen UTXOs and their aggregate value.
#[derive(Debug, Clone)]
pub struct UtxoSelection {
    /// The selected UTXOs.
    pub selected: Vec<Utxo>,
    /// Total value of the selected UTXOs in satoshis.
    pub total_sat: u64,
}

/// Select UTXOs to cover `target_sat` plus estimated fees.
///
/// Uses a simple largest-first (descending by value) coin selection strategy.
/// The estimated fee is computed for a P2WPKH transaction with the number of
/// selected inputs and two outputs (recipient + change).
pub fn select_utxos(
    utxos: &[Utxo],
    target_sat: u64,
    fee_rate_sat_vbyte: u64,
) -> Result<UtxoSelection, BtcError> {
    if utxos.is_empty() {
        return Err(BtcError::TransactionBuildError(
            "no UTXOs available".into(),
        ));
    }

    // Sort by value descending (largest first).
    let mut sorted: Vec<&Utxo> = utxos.iter().collect();
    sorted.sort_by(|a, b| b.amount_sat.cmp(&a.amount_sat));

    let mut selected: Vec<Utxo> = Vec::new();
    let mut total_sat: u64 = 0;

    for utxo in &sorted {
        selected.push((*utxo).clone());
        total_sat += utxo.amount_sat;

        // Estimate fee with current selection count and 2 outputs (recipient + change).
        let fee = crate::transaction::estimate_fee(selected.len(), 2, fee_rate_sat_vbyte);
        if total_sat >= target_sat + fee {
            return Ok(UtxoSelection { selected, total_sat });
        }
    }

    // Even after selecting all UTXOs, check if we have enough.
    let fee = crate::transaction::estimate_fee(selected.len(), 2, fee_rate_sat_vbyte);
    if total_sat >= target_sat + fee {
        return Ok(UtxoSelection { selected, total_sat });
    }

    Err(BtcError::TransactionBuildError(format!(
        "insufficient funds: have {} sat, need {} sat (target {} + fee {})",
        total_sat,
        target_sat + fee,
        target_sat,
        fee,
    )))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_utxo(txid: &str, vout: u32, amount_sat: u64) -> Utxo {
        Utxo {
            txid: txid.to_string(),
            vout,
            amount_sat,
            script_pubkey: vec![0xaa; 22], // dummy script bytes
        }
    }

    #[test]
    fn selects_single_large_utxo() {
        let utxos = vec![
            make_utxo("aaaa", 0, 100_000),
            make_utxo("bbbb", 0, 50_000),
        ];
        let selection = select_utxos(&utxos, 40_000, 1).unwrap();
        assert_eq!(selection.selected.len(), 1);
        assert_eq!(selection.total_sat, 100_000);
    }

    #[test]
    fn selects_multiple_utxos_when_needed() {
        let utxos = vec![
            make_utxo("aaaa", 0, 30_000),
            make_utxo("bbbb", 0, 30_000),
            make_utxo("cccc", 0, 30_000),
        ];
        let selection = select_utxos(&utxos, 55_000, 1).unwrap();
        assert!(selection.selected.len() >= 2);
        assert!(selection.total_sat >= 55_000);
    }

    #[test]
    fn insufficient_funds_returns_error() {
        let utxos = vec![make_utxo("aaaa", 0, 1_000)];
        let result = select_utxos(&utxos, 500_000, 1);
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("insufficient funds"));
    }

    #[test]
    fn empty_utxos_returns_error() {
        let result = select_utxos(&[], 1_000, 1);
        assert!(result.is_err());
    }

    #[test]
    fn largest_first_ordering() {
        let utxos = vec![
            make_utxo("small", 0, 1_000),
            make_utxo("large", 0, 100_000),
            make_utxo("medium", 0, 50_000),
        ];
        let selection = select_utxos(&utxos, 10_000, 1).unwrap();
        // Should pick the largest first, so only one UTXO needed.
        assert_eq!(selection.selected.len(), 1);
        assert_eq!(selection.selected[0].txid, "large");
    }

    #[test]
    fn fee_rate_affects_selection() {
        let utxos = vec![
            make_utxo("aaaa", 0, 50_000),
            make_utxo("bbbb", 0, 50_000),
        ];
        // With a very high fee rate, one UTXO may not be enough.
        let result_low = select_utxos(&utxos, 40_000, 1);
        let result_high = select_utxos(&utxos, 40_000, 500);

        assert!(result_low.is_ok());
        // High fee rate may need more UTXOs or may fail.
        if let Ok(sel) = result_high {
            assert!(sel.selected.len() >= result_low.unwrap().selected.len());
        }
    }
}
