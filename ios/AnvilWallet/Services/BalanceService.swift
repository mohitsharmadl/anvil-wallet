import Foundation

/// BalanceService handles balance fetching and watch-only portfolio refresh.
///
/// Extracted from WalletService. Returns balance results that WalletService
/// applies to its @Published `tokens`, `watchPortfolio`, and `watchTransactions`.
final class BalanceService {

    static let shared = BalanceService()

    private init() {}

    // MARK: - Balance Fetching

    /// Fetches balances for all tokens and returns index-balance pairs.
    ///
    /// - Parameters:
    ///   - tokens: Current token list snapshot
    ///   - addresses: Chain ID -> address mapping
    /// - Returns: Array of (index, balance) pairs to apply
    func fetchBalances(
        tokens: [TokenModel],
        addresses: [String: String]
    ) async -> [(index: Int, balance: Double)] {
        let rpc = RPCService.shared
        var results: [(index: Int, balance: Double)] = []

        for (index, token) in tokens.enumerated() {
            guard let chain = ChainPreferencesStore.shared.enabledDefaults.first(where: { $0.id == token.chain }),
                  let address = addresses[token.chain] else {
                continue
            }

            do {
                let balance: Double

                switch chain.chainType {
                case .evm:
                    if token.isNativeToken {
                        let hexBalance: String = try await rpc.getBalance(rpcUrl: chain.activeRpcUrl, address: address)
                        balance = Self.hexToDouble(hexBalance) / pow(10.0, Double(token.decimals))
                    } else {
                        guard let contractAddress = token.contractAddress else { continue }
                        let stripped = String(address.dropFirst(2)).lowercased()
                        let paddedAddress = String(repeating: "0", count: max(0, 64 - stripped.count)) + stripped
                        let callData = "0x70a08231" + paddedAddress
                        let hexBalance: String = try await rpc.ethCall(rpcUrl: chain.activeRpcUrl, to: contractAddress, data: callData)
                        balance = Self.hexToDouble(hexBalance) / pow(10.0, Double(token.decimals))
                    }

                case .solana:
                    let lamports = try await rpc.getSolanaBalance(rpcUrl: chain.activeRpcUrl, address: address)
                    balance = Double(lamports) / pow(10.0, Double(token.decimals))

                case .bitcoin:
                    let satoshis = try await rpc.getBitcoinBalance(apiUrl: chain.activeRpcUrl, address: address)
                    balance = Double(satoshis) / pow(10.0, Double(token.decimals))

                case .zcash:
                    let zatoshi = try await rpc.getZcashBalance(address: address)
                    balance = Double(zatoshi) / pow(10.0, Double(token.decimals))
                }

                results.append((index: index, balance: balance))
            } catch {
                continue
            }
        }

        return results
    }

    // MARK: - Watch-Only Data

    /// Refreshes balances and recent history for watch-only addresses.
    ///
    /// - Returns: Tuple of (portfolio entries, transactions)
    func fetchWatchOnlyData() async throws -> (portfolio: [WatchPortfolioEntry], transactions: [TransactionModel]) {
        let watches = WatchAddressService.shared.watchAddresses
        guard !watches.isEmpty else {
            return (portfolio: [], transactions: [])
        }

        let rpc = RPCService.shared
        var nativeBalances: [(watch: WatchAddress, chain: ChainModel, balance: Double)] = []

        for watch in watches {
            guard let chain = ChainModel.allChains.first(where: { $0.id == watch.chainId }) else { continue }
            do {
                let balance: Double
                switch chain.chainType {
                case .evm:
                    let hexBalance = try await rpc.getBalance(rpcUrl: chain.activeRpcUrl, address: watch.address)
                    balance = Self.hexToDouble(hexBalance) / 1e18
                case .solana:
                    let lamports = try await rpc.getSolanaBalance(rpcUrl: chain.activeRpcUrl, address: watch.address)
                    balance = Double(lamports) / 1e9
                case .bitcoin:
                    let sat = try await rpc.getBitcoinBalance(apiUrl: chain.activeRpcUrl, address: watch.address)
                    balance = Double(sat) / 1e8
                case .zcash:
                    let zat = try await rpc.getZcashBalance(address: watch.address)
                    balance = Double(zat) / 1e8
                }
                nativeBalances.append((watch: watch, chain: chain, balance: balance))
            } catch {
                continue
            }
        }

        let symbols = Array(Set(nativeBalances.map { $0.chain.symbol.lowercased() }))
        let prices = (try? await PriceService.shared.fetchPrices(for: symbols)) ?? [:]

        let entries = nativeBalances.map { item in
            let price = prices[item.chain.symbol.lowercased()] ?? 0
            return WatchPortfolioEntry(
                id: item.watch.id,
                name: item.watch.name,
                chainId: item.chain.id,
                address: item.watch.address,
                nativeSymbol: item.chain.symbol,
                balanceNative: item.balance,
                balanceUsd: item.balance * price
            )
        }
        .sorted { $0.balanceUsd > $1.balanceUsd }

        // Fetch per-watch recent transactions and merge
        var mergedWatchTxs: [TransactionModel] = []
        let txService = TransactionHistoryService.shared
        for watch in watches {
            let txs = (try? await txService.fetchAllTransactions(addresses: [watch.chainId: watch.address])) ?? []
            mergedWatchTxs.append(contentsOf: txs.prefix(20))
        }

        var seen = Set<String>()
        let deduped = mergedWatchTxs.filter { tx in
            seen.insert("\(tx.chain.lowercased())_\(tx.hash.lowercased())").inserted
        }
        .sorted { $0.timestamp > $1.timestamp }

        return (portfolio: entries, transactions: deduped)
    }

    // MARK: - Utilities

    /// Parses a hex string (with or without 0x prefix) to Double.
    /// Uses Double arithmetic to avoid UInt64 overflow for large token balances.
    static func hexToDouble(_ hex: String) -> Double {
        let cleaned = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        var result: Double = 0
        for char in cleaned {
            guard let digit = Int(String(char), radix: 16) else { return 0 }
            result = result * 16.0 + Double(digit)
        }
        return result
    }

    // MARK: - Widget Data

    /// Pushes the current portfolio snapshot to the shared App Group UserDefaults
    /// so the home screen widget can display up-to-date balances.
    func updateWidgetData(tokens: [TokenModel], accountName: String) {
        WidgetDataProvider.shared.updateWidgetData(
            tokens: tokens,
            accountName: accountName
        )
    }
}
