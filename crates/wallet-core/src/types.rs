use serde::{Deserialize, Serialize};

/// Supported blockchain networks
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Chain {
    Bitcoin,
    BitcoinTestnet,
    Ethereum,
    Polygon,
    Arbitrum,
    Base,
    Optimism,
    Bsc,
    Avalanche,
    Solana,
    SolanaDevnet,
    // Testnets
    Sepolia,
    PolygonAmoy,
}

impl Chain {
    /// BIP-44 coin type for this chain
    pub fn coin_type(&self) -> u32 {
        match self {
            Chain::Bitcoin => 0,
            Chain::BitcoinTestnet => 1,
            Chain::Ethereum
            | Chain::Polygon
            | Chain::Arbitrum
            | Chain::Base
            | Chain::Optimism
            | Chain::Bsc
            | Chain::Avalanche
            | Chain::Sepolia
            | Chain::PolygonAmoy => 60,
            Chain::Solana | Chain::SolanaDevnet => 501,
        }
    }

    /// Whether this chain uses secp256k1 (BTC/ETH) or Ed25519 (SOL)
    pub fn curve(&self) -> CurveType {
        match self {
            Chain::Solana | Chain::SolanaDevnet => CurveType::Ed25519,
            _ => CurveType::Secp256k1,
        }
    }

    /// Display name
    pub fn display_name(&self) -> &'static str {
        match self {
            Chain::Bitcoin => "Bitcoin",
            Chain::BitcoinTestnet => "Bitcoin Testnet",
            Chain::Ethereum => "Ethereum",
            Chain::Polygon => "Polygon",
            Chain::Arbitrum => "Arbitrum One",
            Chain::Base => "Base",
            Chain::Optimism => "Optimism",
            Chain::Bsc => "BNB Smart Chain",
            Chain::Avalanche => "Avalanche C-Chain",
            Chain::Solana => "Solana",
            Chain::SolanaDevnet => "Solana Devnet",
            Chain::Sepolia => "Sepolia Testnet",
            Chain::PolygonAmoy => "Polygon Amoy Testnet",
        }
    }

    /// Native token symbol
    pub fn symbol(&self) -> &'static str {
        match self {
            Chain::Bitcoin | Chain::BitcoinTestnet => "BTC",
            Chain::Ethereum | Chain::Sepolia => "ETH",
            Chain::Polygon | Chain::PolygonAmoy => "MATIC",
            Chain::Arbitrum => "ETH",
            Chain::Base => "ETH",
            Chain::Optimism => "ETH",
            Chain::Bsc => "BNB",
            Chain::Avalanche => "AVAX",
            Chain::Solana | Chain::SolanaDevnet => "SOL",
        }
    }

    /// Whether this is a testnet
    pub fn is_testnet(&self) -> bool {
        matches!(
            self,
            Chain::BitcoinTestnet | Chain::Sepolia | Chain::PolygonAmoy | Chain::SolanaDevnet
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CurveType {
    Secp256k1,
    Ed25519,
}

/// Derived address for a specific chain
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DerivedAddress {
    pub chain: Chain,
    pub address: String,
    pub derivation_path: String,
}

/// Encrypted seed data — stored in iOS Keychain
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EncryptedSeed {
    /// AES-256-GCM encrypted seed (nonce prepended)
    pub ciphertext: Vec<u8>,
    /// Argon2id salt
    pub salt: Vec<u8>,
    /// Optional: Secure Enclave encrypted layer (ECIES ciphertext)
    pub se_ciphertext: Option<Vec<u8>>,
}

/// Wallet metadata (non-sensitive, can be stored in UserDefaults)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WalletMetadata {
    pub name: String,
    pub created_at: u64,
    pub chains: Vec<Chain>,
    pub has_passphrase: bool,
}
