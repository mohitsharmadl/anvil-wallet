use bitcoin::address::Address;
use bitcoin::CompressedPublicKey;

use crate::error::BtcError;
use crate::network::BtcNetwork;

/// Derive a P2WPKH (native SegWit bech32) address from a compressed public key.
///
/// Takes a 33-byte compressed secp256k1 public key and returns a bech32 address
/// string: `bc1...` for mainnet, `tb1...` for testnet/signet.
pub fn pubkey_to_p2wpkh_address(
    pubkey_bytes: &[u8; 33],
    network: BtcNetwork,
) -> Result<String, BtcError> {
    let compressed_pk = CompressedPublicKey::from_slice(pubkey_bytes).map_err(|e| {
        BtcError::InvalidPublicKey(format!("failed to parse compressed public key: {e}"))
    })?;

    let address = Address::p2wpkh(&compressed_pk, network.to_bitcoin_network());

    Ok(address.to_string())
}

/// Validate a Bitcoin address string for the given network.
///
/// Supports P2PKH, P2SH, P2WPKH, P2WSH, and P2TR address formats.
/// Returns `true` if the address is valid for the specified network,
/// `false` if it is valid but for a different network.
pub fn validate_address(address: &str, network: BtcNetwork) -> Result<bool, BtcError> {
    let parsed = address
        .parse::<Address<bitcoin::address::NetworkUnchecked>>()
        .map_err(|e| BtcError::InvalidAddress(format!("failed to parse address: {e}")))?;

    let net = network.to_bitcoin_network();
    Ok(parsed.is_valid_for_network(net))
}

#[cfg(test)]
mod tests {
    use super::*;
    use bitcoin::secp256k1::Secp256k1;

    /// Well-known test vector: derive address from a known private key.
    /// Private key (hex): 0000000000000000000000000000000000000000000000000000000000000001
    /// Compressed pubkey: 0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
    /// Expected P2WPKH mainnet: bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4
    #[test]
    fn p2wpkh_mainnet_test_vector() {
        let pubkey_hex = "0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798";
        let pubkey_bytes: [u8; 33] = hex::decode(pubkey_hex)
            .unwrap()
            .try_into()
            .unwrap();

        let address = pubkey_to_p2wpkh_address(&pubkey_bytes, BtcNetwork::Mainnet).unwrap();
        assert_eq!(address, "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4");
    }

    #[test]
    fn p2wpkh_testnet_address_starts_with_tb1() {
        let pubkey_hex = "0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798";
        let pubkey_bytes: [u8; 33] = hex::decode(pubkey_hex)
            .unwrap()
            .try_into()
            .unwrap();

        let address = pubkey_to_p2wpkh_address(&pubkey_bytes, BtcNetwork::Testnet).unwrap();
        assert!(address.starts_with("tb1"), "expected tb1 prefix, got {address}");
    }

    #[test]
    fn p2wpkh_signet_address_starts_with_tb1() {
        let pubkey_hex = "0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798";
        let pubkey_bytes: [u8; 33] = hex::decode(pubkey_hex)
            .unwrap()
            .try_into()
            .unwrap();

        let address = pubkey_to_p2wpkh_address(&pubkey_bytes, BtcNetwork::Signet).unwrap();
        assert!(address.starts_with("tb1"), "expected tb1 prefix, got {address}");
    }

    #[test]
    fn invalid_pubkey_returns_error() {
        let bad_bytes = [0u8; 33];
        let result = pubkey_to_p2wpkh_address(&bad_bytes, BtcNetwork::Mainnet);
        assert!(result.is_err());
    }

    #[test]
    fn pubkey_from_secp256k1_roundtrip() {
        let secp = Secp256k1::new();
        let secret_key =
            bitcoin::secp256k1::SecretKey::from_slice(&[0xcd; 32]).unwrap();
        let public_key = bitcoin::secp256k1::PublicKey::from_secret_key(&secp, &secret_key);
        let pubkey_bytes: [u8; 33] = public_key.serialize();

        let address = pubkey_to_p2wpkh_address(&pubkey_bytes, BtcNetwork::Mainnet).unwrap();
        assert!(address.starts_with("bc1q"));
    }

    #[test]
    fn validate_known_mainnet_address() {
        let valid = validate_address(
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
            BtcNetwork::Mainnet,
        )
        .unwrap();
        assert!(valid);
    }

    #[test]
    fn validate_mainnet_address_on_testnet_returns_false() {
        let valid = validate_address(
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
            BtcNetwork::Testnet,
        )
        .unwrap();
        assert!(!valid);
    }

    #[test]
    fn validate_garbage_address_returns_error() {
        let result = validate_address("notanaddress!!!", BtcNetwork::Mainnet);
        assert!(result.is_err());
    }

    #[test]
    fn validate_p2pkh_mainnet_address() {
        // A well-known P2PKH address (Satoshi's genesis coinbase address).
        let valid = validate_address(
            "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
            BtcNetwork::Mainnet,
        )
        .unwrap();
        assert!(valid);
    }
}
