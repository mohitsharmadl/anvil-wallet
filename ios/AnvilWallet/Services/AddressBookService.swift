import Foundation

/// A saved contact address in the address book.
struct SavedAddress: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    let address: String
    /// Chain scope: "ethereum" (covers all EVM chains), "solana", "bitcoin", or "all".
    let chain: String
    var notes: String?
    let dateAdded: Date

    /// Truncated address for display (e.g. "0x1234...abcd").
    var shortAddress: String {
        guard address.count > 12 else { return address }
        return "\(address.prefix(6))...\(address.suffix(4))"
    }

    /// Human-readable chain label for display.
    var chainDisplayName: String {
        switch chain {
        case "ethereum": return "Ethereum & EVM"
        case "solana": return "Solana"
        case "bitcoin": return "Bitcoin"
        default: return chain.capitalized
        }
    }
}

/// Manages persistence and CRUD operations for the address book.
///
/// Addresses are stored in UserDefaults as JSON. EVM addresses are saved once
/// with chain="ethereum" and shown for all EVM chains (Polygon, Arbitrum, etc.).
/// Deduplication is by address+chain (case-insensitive for EVM).
final class AddressBookService: ObservableObject {

    static let shared = AddressBookService()

    private let defaults = UserDefaults.standard
    private static let storageKey = "com.anvilwallet.addressBook"

    @Published private(set) var addresses: [SavedAddress] = []

    private init() {
        loadAddresses()
    }

    // MARK: - Public API

    /// All saved addresses.
    func allAddresses() -> [SavedAddress] {
        addresses
    }

    /// Addresses relevant to a specific chain ID (e.g. "ethereum", "polygon", "solana").
    ///
    /// For EVM chains, returns addresses saved with chain="ethereum" since
    /// all EVM chains share the same address format.
    func addresses(for chainId: String) -> [SavedAddress] {
        let chainType = chainTypeForId(chainId)
        return addresses.filter { saved in
            switch chainType {
            case .evm:
                return saved.chain == "ethereum"
            case .solana:
                return saved.chain == "solana"
            case .bitcoin:
                return saved.chain == "bitcoin"
            case .zcash:
                return saved.chain == "zcash"
            }
        }
    }

    /// Adds a new address to the book. Returns false if a duplicate exists.
    @discardableResult
    func addAddress(name: String, address: String, chain: String, notes: String? = nil) -> Bool {
        let normalizedAddress = normalizeAddress(address, chain: chain)
        let normalizedChain = normalizeChain(chain)

        // Check for duplicates
        let isDuplicate = addresses.contains { saved in
            normalizeAddress(saved.address, chain: saved.chain) == normalizedAddress
                && saved.chain == normalizedChain
        }
        guard !isDuplicate else { return false }

        let saved = SavedAddress(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            address: address.trimmingCharacters(in: .whitespacesAndNewlines),
            chain: normalizedChain,
            notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines),
            dateAdded: Date()
        )
        addresses.append(saved)
        persistAddresses()
        return true
    }

    /// Removes an address by ID.
    func removeAddress(id: UUID) {
        addresses.removeAll { $0.id == id }
        persistAddresses()
    }

    /// Updates the name and notes of an existing address.
    func updateAddress(id: UUID, name: String, notes: String?) {
        guard let index = addresses.firstIndex(where: { $0.id == id }) else { return }
        addresses[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        addresses[index].notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        persistAddresses()
    }

    /// Checks if an address is already saved for the given chain.
    func isSaved(address: String, chain: String) -> Bool {
        let normalizedAddress = normalizeAddress(address, chain: chain)
        let normalizedChain = normalizeChain(chain)
        return addresses.contains { saved in
            normalizeAddress(saved.address, chain: saved.chain) == normalizedAddress
                && saved.chain == normalizedChain
        }
    }

    // MARK: - Private

    private func loadAddresses() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([SavedAddress].self, from: data) else {
            return
        }
        addresses = decoded
    }

    private func persistAddresses() {
        guard let data = try? JSONEncoder().encode(addresses) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Normalizes chain IDs: all EVM chain IDs map to "ethereum".
    private func normalizeChain(_ chainId: String) -> String {
        let evmChains: Set<String> = ["ethereum", "polygon", "arbitrum", "base", "optimism", "bsc", "avalanche", "sepolia"]
        return evmChains.contains(chainId) ? "ethereum" : chainId
    }

    /// Normalizes addresses for comparison. EVM addresses are lowercased.
    private func normalizeAddress(_ address: String, chain: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedChain = normalizeChain(chain)
        if normalizedChain == "ethereum" {
            return trimmed.lowercased()
        }
        return trimmed
    }

    /// Maps a chain ID to its chain type for filtering.
    private func chainTypeForId(_ chainId: String) -> ChainModel.ChainType {
        if let chain = ChainModel.allChains.first(where: { $0.id == chainId }) {
            return chain.chainType
        }
        // Default EVM chains
        let evmChains: Set<String> = ["ethereum", "polygon", "arbitrum", "base", "optimism", "bsc", "avalanche", "sepolia"]
        if evmChains.contains(chainId) { return .evm }
        if chainId == "solana" { return .solana }
        if chainId == "bitcoin" { return .bitcoin }
        return .evm
    }
}
