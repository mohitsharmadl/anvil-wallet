use crate::error::WalletError;
use crate::hd_derivation;
use crate::types::Chain;
use zeroize::Zeroize;

/// UTXO data passed from Swift for Bitcoin transaction signing
pub struct UtxoData {
    pub txid: String,
    pub vout: u32,
    pub amount_sat: u64,
    pub script_pubkey: Vec<u8>,
}

/// Execute a closure with the seed, guaranteeing zeroization on both success and error paths.
fn with_zeroized_seed<F, T>(mut seed: Vec<u8>, f: F) -> Result<T, WalletError>
where
    F: FnOnce(&[u8]) -> Result<T, WalletError>,
{
    let result = f(&seed);
    seed.zeroize();
    result
}

/// Sign a Bitcoin P2WPKH transaction
pub fn sign_btc_transaction(
    seed: Vec<u8>,
    account: u32,
    index: u32,
    utxos: Vec<UtxoData>,
    recipient_address: String,
    amount_sat: u64,
    change_address: String,
    fee_rate_sat_vbyte: u64,
    is_testnet: bool,
) -> Result<Vec<u8>, WalletError> {
    let chain = if is_testnet { Chain::BitcoinTestnet } else { Chain::Bitcoin };
    let network = if is_testnet {
        chain_btc::network::BtcNetwork::Testnet
    } else {
        chain_btc::network::BtcNetwork::Mainnet
    };

    // Convert FFI UtxoData to chain_btc Utxo before entering closure
    let btc_utxos: Vec<chain_btc::utxo::Utxo> = utxos
        .into_iter()
        .map(|u| chain_btc::utxo::Utxo {
            txid: u.txid,
            vout: u.vout,
            amount_sat: u.amount_sat,
            script_pubkey: u.script_pubkey,
        })
        .collect();

    with_zeroized_seed(seed, |s| {
        let key = hd_derivation::derive_secp256k1_key(s, chain, account, index)?;

        let unsigned_tx = chain_btc::transaction::build_p2wpkh_transaction(
            &btc_utxos,
            &recipient_address,
            amount_sat,
            &change_address,
            fee_rate_sat_vbyte,
            network,
        )?;

        let signed_bytes = chain_btc::transaction::sign_transaction(
            &unsigned_tx,
            &key.private_key,
            network,
        )?;

        Ok(signed_bytes)
    })
}
