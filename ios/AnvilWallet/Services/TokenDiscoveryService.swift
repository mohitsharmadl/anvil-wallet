import Foundation

/// Discovers ERC-20 tokens held by the wallet using Etherscan token transfer history.
/// Checks on-chain balanceOf for each discovered contract, adds tokens with non-zero balance.
/// Persists discovered tokens to UserDefaults to avoid re-fetching on every launch.
actor TokenDiscoveryService {

    static let shared = TokenDiscoveryService()

    private let persistenceKey = "com.anvilwallet.discoveredTokens"

    private init() {}

    // MARK: - Discovery

    struct DiscoveredToken: Codable, Hashable {
        let contractAddress: String
        let symbol: String
        let name: String
        let decimals: Int
        let chain: String
    }

    /// Discovers ERC-20 tokens for an Ethereum address.
    /// Fetches token transfer history from Etherscan, checks balanceOf for each,
    /// returns tokens with non-zero balances.
    func discoverTokens(for address: String) async throws -> [DiscoveredToken] {
        let transfers = try await EtherscanService.shared.fetchTokenTransfers(address: address)
        var discovered: [DiscoveredToken] = []

        // Get the Ethereum mainnet RPC URL
        guard let ethChain = ChainModel.allChains.first(where: { $0.id == "ethereum" }) else {
            return []
        }

        for transfer in transfers {
            guard let decimals = Int(transfer.tokenDecimal), decimals > 0 && decimals <= 18 else {
                continue
            }

            // Check on-chain balance via balanceOf(address)
            let cleanAddr = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
            let paddedAddr = String(repeating: "0", count: max(0, 64 - cleanAddr.count)) + cleanAddr.lowercased()
            let callData = "0x70a08231" + paddedAddr // balanceOf(address)

            do {
                let hexBalance: String = try await RPCService.shared.ethCall(
                    rpcUrl: ethChain.rpcUrl,
                    to: transfer.contractAddress,
                    data: callData
                )

                // Skip zero balances
                let cleanHex = hexBalance.hasPrefix("0x") ? String(hexBalance.dropFirst(2)) : hexBalance
                let isZero = cleanHex.isEmpty || cleanHex.allSatisfy { $0 == "0" }
                if isZero { continue }

                discovered.append(DiscoveredToken(
                    contractAddress: transfer.contractAddress,
                    symbol: transfer.tokenSymbol,
                    name: transfer.tokenName,
                    decimals: decimals,
                    chain: "ethereum"
                ))
            } catch {
                // Skip tokens where balanceOf fails (e.g. proxy contracts, non-standard tokens)
                continue
            }
        }

        // Persist for next launch
        persist(discovered)

        return discovered
    }

    // MARK: - Persistence

    private func persist(_ tokens: [DiscoveredToken]) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    /// Loads previously discovered tokens from UserDefaults.
    nonisolated func loadPersistedTokens() -> [DiscoveredToken] {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let tokens = try? JSONDecoder().decode([DiscoveredToken].self, from: data) else {
            return []
        }
        return tokens
    }

    /// Clears persisted discovered tokens.
    nonisolated func clearPersistedTokens() {
        UserDefaults.standard.removeObject(forKey: persistenceKey)
    }
}
