import Foundation

/// Manages persistence of user-configured custom RPC URLs per chain.
///
/// Stores overrides in UserDefaults with keys like "customRPC_ethereum".
/// When a custom URL is set for a chain, it takes priority over the
/// default `ChainModel.rpcUrl` everywhere in the app.
final class CustomRPCStore: ObservableObject {

    static let shared = CustomRPCStore()

    private let defaults = UserDefaults.standard
    private static let keyPrefix = "customRPC_"

    /// Published so SwiftUI views react to changes.
    @Published private(set) var overrides: [String: String] = [:]

    private init() {
        loadAll()
    }

    // MARK: - Public API

    /// Returns the active RPC URL for a chain — custom override if set, otherwise the default.
    func activeRpcUrl(for chain: ChainModel) -> String {
        overrides[chain.id] ?? chain.rpcUrl
    }

    /// Returns true if the chain has a custom RPC URL override.
    func hasCustomUrl(for chain: ChainModel) -> Bool {
        overrides[chain.id] != nil
    }

    /// Persists a custom RPC URL for the given chain.
    func setCustomUrl(_ url: String, for chain: ChainModel) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        defaults.set(trimmed, forKey: Self.keyPrefix + chain.id)
        overrides[chain.id] = trimmed
    }

    /// Removes the custom RPC URL for a chain, reverting to the default.
    func resetToDefault(for chain: ChainModel) {
        defaults.removeObject(forKey: Self.keyPrefix + chain.id)
        overrides.removeValue(forKey: chain.id)
    }

    /// Removes all custom RPC overrides.
    func resetAll() {
        for chainId in overrides.keys {
            defaults.removeObject(forKey: Self.keyPrefix + chainId)
        }
        overrides.removeAll()
    }

    // MARK: - Validation

    /// Validates that a URL string is well-formed and uses HTTPS.
    static func validateUrl(_ urlString: String) -> URLValidationResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return .invalid("URL cannot be empty")
        }

        guard let url = URL(string: trimmed) else {
            return .invalid("Invalid URL format")
        }

        guard url.scheme == "https" else {
            return .invalid("Only HTTPS URLs are allowed")
        }

        guard url.host != nil else {
            return .invalid("URL must have a valid host")
        }

        return .valid
    }

    enum URLValidationResult: Equatable {
        case valid
        case invalid(String)

        var isValid: Bool {
            if case .valid = self { return true }
            return false
        }

        var errorMessage: String? {
            if case .invalid(let msg) = self { return msg }
            return nil
        }
    }

    // MARK: - Connectivity Test

    /// Tests connectivity to an RPC endpoint by calling `eth_chainId` (EVM)
    /// or a simple method for the chain type. Returns the chain ID on success.
    func testConnectivity(url: String, chainType: ChainModel.ChainType) async -> ConnectivityResult {
        switch chainType {
        case .evm:
            return await testEvmConnectivity(url: url)
        case .solana:
            return await testSolanaConnectivity(url: url)
        case .bitcoin:
            return await testBitcoinConnectivity(url: url)
        }
    }

    enum ConnectivityResult: Equatable {
        case success(String) // description of what was verified
        case failure(String) // error message

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }

    // MARK: - Private

    private func loadAll() {
        var loaded: [String: String] = [:]
        for chain in ChainModel.allChains {
            let key = Self.keyPrefix + chain.id
            if let url = defaults.string(forKey: key) {
                loaded[chain.id] = url
            }
        }
        overrides = loaded
    }

    private func testEvmConnectivity(url: String) async -> ConnectivityResult {
        do {
            let chainIdHex: String = try await RPCService.shared.call(
                url: url,
                method: "eth_chainId",
                params: []
            )
            return .success("Connected (chain ID: \(chainIdHex))")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func testSolanaConnectivity(url: String) async -> ConnectivityResult {
        do {
            // getHealth returns "ok" on a healthy node
            let _: String = try await RPCService.shared.call(
                url: url,
                method: "getHealth",
                params: []
            )
            return .success("Connected (node healthy)")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func testBitcoinConnectivity(url: String) async -> ConnectivityResult {
        // Bitcoin uses REST, not JSON-RPC — try fetching the tip hash
        guard let endpoint = URL(string: "\(url)/blocks/tip/hash") else {
            return .failure("Invalid URL")
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: endpoint)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let hash = String(data: data, encoding: .utf8),
                  hash.count >= 64 else {
                return .failure("Unexpected response from Bitcoin API")
            }
            return .success("Connected (tip: \(hash.prefix(12))...)")
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
