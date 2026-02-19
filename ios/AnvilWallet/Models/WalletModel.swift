import Foundation

struct WalletModel: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    let createdAt: Date
    var chains: [ChainModel]
    var addresses: [String: String] // chainId -> address
    var accountIndex: Int
    var accountName: String?

    init(
        id: UUID = UUID(),
        name: String = "My Wallet",
        createdAt: Date = Date(),
        chains: [ChainModel] = ChainModel.defaults,
        addresses: [String: String] = [:],
        accountIndex: Int = 0,
        accountName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.chains = chains
        self.addresses = addresses
        self.accountIndex = accountIndex
        self.accountName = accountName
    }

    func address(for chain: ChainModel) -> String? {
        addresses[chain.id]
    }

    /// Display name for the account — uses accountName if set, otherwise "Account N".
    var displayName: String {
        accountName ?? "Account \(accountIndex)"
    }

    /// Truncated ETH address for display in account picker (e.g. "0x1234...abcd").
    var shortEthAddress: String {
        guard let eth = addresses["ethereum"], eth.count > 10 else {
            return addresses["ethereum"] ?? ""
        }
        return "\(eth.prefix(6))...\(eth.suffix(4))"
    }

    // MARK: - Backward-compatible Codable

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, chains, addresses, accountIndex, accountName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        chains = try container.decode([ChainModel].self, forKey: .chains)
        addresses = try container.decode([String: String].self, forKey: .addresses)
        // Backward compatibility: default to 0 and nil for wallets created before multi-account
        accountIndex = try container.decodeIfPresent(Int.self, forKey: .accountIndex) ?? 0
        accountName = try container.decodeIfPresent(String.self, forKey: .accountName)
    }
}
