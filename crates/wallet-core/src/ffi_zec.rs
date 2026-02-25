use crate::error::WalletError;
use crate::hd_derivation;
use crate::types::Chain;
use zeroize::Zeroize;

/// Zcash UTXO data passed from Swift for transaction signing
pub struct ZecUtxoData {
    pub txid: String,
    pub vout: u32,
    pub amount_zatoshi: u64,
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

/// Sign a Zcash transparent P2PKH transaction (v5 format with ZIP-244 sighash)
pub fn sign_zec_transaction(
    seed: Vec<u8>,
    account: u32,
    index: u32,
    utxos: Vec<ZecUtxoData>,
    recipient_address: String,
    amount_zatoshi: u64,
    change_address: String,
    fee_rate_zat_byte: u64,
    expiry_height: u32,
    is_testnet: bool,
) -> Result<Vec<u8>, WalletError> {
    let chain = if is_testnet { Chain::ZcashTestnet } else { Chain::Zcash };
    let network = if is_testnet {
        chain_zec::address::ZecNetwork::Testnet
    } else {
        chain_zec::address::ZecNetwork::Mainnet
    };

    // Convert FFI ZecUtxoData to chain_zec ZecUtxo before entering closure
    let zec_utxos: Vec<chain_zec::transaction::ZecUtxo> = utxos
        .into_iter()
        .map(|u| chain_zec::transaction::ZecUtxo {
            txid: u.txid,
            vout: u.vout,
            amount_zatoshi: u.amount_zatoshi,
            script_pubkey: u.script_pubkey,
        })
        .collect();

    with_zeroized_seed(seed, |s| {
        let key = hd_derivation::derive_secp256k1_key(s, chain, account, index)?;

        let unsigned_tx = chain_zec::transaction::build_transparent_transaction(
            &zec_utxos,
            &recipient_address,
            amount_zatoshi,
            &change_address,
            fee_rate_zat_byte,
            network,
            expiry_height,
        )?;

        let signed_bytes = chain_zec::transaction::sign_transaction(
            &unsigned_tx,
            &key.private_key,
        )?;

        Ok(signed_bytes)
    })
}
