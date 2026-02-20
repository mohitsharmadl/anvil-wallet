import Foundation

struct WatchAddress: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var address: String
    var chainId: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        address: String,
        chainId: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.chainId = chainId
        self.createdAt = createdAt
    }
}

final class WatchAddressService: ObservableObject {
    static let shared = WatchAddressService()

    @Published private(set) var watchAddresses: [WatchAddress] = []
    private let storageKey = "watch_addresses.v1"

    private init() {
        load()
    }

    func add(name: String, address: String, chainId: String) {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else { return }
        if watchAddresses.contains(where: { $0.address.lowercased() == trimmedAddress.lowercased() && $0.chainId == chainId }) {
            return
        }

        let label = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Watched Address" : name
        watchAddresses.insert(
            WatchAddress(name: label, address: trimmedAddress, chainId: chainId),
            at: 0
        )
        persist()
    }

    func remove(id: UUID) {
        watchAddresses.removeAll { $0.id == id }
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([WatchAddress].self, from: data) else {
            return
        }
        watchAddresses = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(watchAddresses) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

