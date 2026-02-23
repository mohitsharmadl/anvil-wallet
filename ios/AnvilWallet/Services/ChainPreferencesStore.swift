import Foundation

/// Manages which blockchains are active in the wallet UI.
///
/// Stores a set of **disabled** chain IDs in UserDefaults (default: all enabled).
/// Ethereum is always locked on since it's the base EVM chain and shares
/// addresses with all L2s.  Addresses are derived for ALL chains regardless
/// of toggle state, so re-enabling a chain is instant (no re-derivation).
///
/// Same singleton + UserDefaults pattern as `CustomRPCStore`.
final class ChainPreferencesStore: ObservableObject {

    static let shared = ChainPreferencesStore()

    private let defaults = UserDefaults.standard
    private static let key = "disabledChainIds"

    @Published private(set) var disabledChainIds: Set<String> = []

    /// Ethereum is always enabled — it's the base EVM chain.
    private static let alwaysEnabled: Set<String> = ["ethereum"]

    private init() {
        if let stored = defaults.stringArray(forKey: Self.key) {
            disabledChainIds = Set(stored)
        }
    }

    func isEnabled(_ chainId: String) -> Bool {
        !disabledChainIds.contains(chainId)
    }

    func setEnabled(_ chainId: String, enabled: Bool) {
        guard !Self.alwaysEnabled.contains(chainId) else { return }
        if enabled {
            disabledChainIds.remove(chainId)
        } else {
            disabledChainIds.insert(chainId)
        }
        persist()
    }

    /// Filtered version of ChainModel.defaults — only enabled chains.
    var enabledDefaults: [ChainModel] {
        ChainModel.defaults.filter { isEnabled($0.id) }
    }

    private func persist() {
        defaults.set(Array(disabledChainIds), forKey: Self.key)
    }
}
