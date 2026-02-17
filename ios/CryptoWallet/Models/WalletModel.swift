import Foundation

struct WalletModel: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    let createdAt: Date
    var chains: [ChainModel]
    var addresses: [String: String] // chainId -> address

    init(
        id: UUID = UUID(),
        name: String = "My Wallet",
        createdAt: Date = Date(),
        chains: [ChainModel] = ChainModel.defaults,
        addresses: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.chains = chains
        self.addresses = addresses
    }

    func address(for chain: ChainModel) -> String? {
        addresses[chain.id]
    }
}
