import SwiftUI

/// TokenDetailView shows detailed information about a specific token,
/// including balance, price chart, and recent transactions.
struct TokenDetailView: View {
    @EnvironmentObject var walletService: WalletService
    @EnvironmentObject var router: AppRouter

    let token: TokenModel

    /// Whether CoinGecko has price history data for this token.
    private var showPriceChart: Bool {
        PriceHistoryService.shared.hasPriceHistory(
            symbol: token.symbol,
            contractAddress: token.contractAddress,
            chain: token.chain
        )
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 28) {
                // Hero header
                VStack(spacing: 16) {
                    TokenIconView(symbol: token.symbol, chain: token.chain, size: 72)

                    Text(token.name)
                        .font(.title2.bold())
                        .foregroundColor(.textPrimary)

                    VStack(spacing: 4) {
                        Text(token.formattedBalance + " " + token.symbol)
                            .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundColor(.textPrimary)

                        Text(token.formattedBalanceUsd)
                            .font(.headline.monospacedDigit())
                            .foregroundColor(.textSecondary)
                    }
                }
                .padding(.top, 20)

                // Action buttons
                HStack(spacing: 12) {
                    Button {
                        router.navigateToTab(.send)
                    } label: {
                        Label("Send", systemImage: "arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentGreen)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    Button {
                        if let address = walletService.addresses[token.chain] {
                            router.walletPath.append(
                                AppRouter.WalletDestination.receive(chain: token.chain, address: address)
                            )
                        }
                    } label: {
                        Label("Receive", systemImage: "arrow.down.left")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.accentGreen)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentGreen.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 20)

                // Price chart (only if CoinGecko data is available)
                if showPriceChart {
                    PriceChartView(token: token)
                }

                // Info card
                VStack(spacing: 0) {
                    infoRow(label: "Price", value: formatPrice(token.priceUsd))
                    Divider().foregroundColor(.separator)
                    infoRow(label: "Network", value: token.chain.capitalized)

                    if let contractAddress = token.contractAddress {
                        Divider().foregroundColor(.separator)
                        HStack {
                            Text("Contract")
                                .font(.subheadline)
                                .foregroundColor(.textSecondary)
                            Spacer()
                            Text(contractAddress.prefix(6) + "..." + contractAddress.suffix(4))
                                .font(.subheadline.monospaced())
                                .foregroundColor(.textPrimary)
                            Button {
                                SecurityService.shared.copyWithAutoClear(contractAddress)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption2)
                                    .foregroundColor(.accentGreen)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }

                    Divider().foregroundColor(.separator)
                    infoRow(label: "Decimals", value: "\(token.decimals)")
                }
                .background(Color.backgroundCard)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)

                // Recent transactions
                VStack(spacing: 12) {
                    Text("Recent Transactions")
                        .font(.headline)
                        .foregroundColor(.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if tokenTransactions.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "tray")
                                .font(.title2)
                                .foregroundColor(.textTertiary)
                            Text("No transactions yet")
                                .font(.subheadline)
                                .foregroundColor(.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .background(Color.backgroundCard)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(tokenTransactions.prefix(10)) { tx in
                                NavigationLink(destination: TransactionDetailView(transaction: tx)) {
                                    tokenTransactionRow(tx)
                                }
                                if tx.id != tokenTransactions.prefix(10).last?.id {
                                    Divider().foregroundColor(.separator)
                                }
                            }
                        }
                        .background(Color.backgroundCard)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .background(Color.backgroundPrimary)
        .navigationTitle(token.symbol)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            try? await walletService.refreshTransactions()
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundColor(.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func formatPrice(_ price: Double) -> String {
        if price >= 1 {
            return String(format: "$%.2f", price)
        } else if price > 0 {
            return String(format: "$%.6f", price)
        }
        return "$0.00"
    }

    // MARK: - Transaction Filtering

    /// All known wallet addresses (lowercased) for determining send vs receive direction.
    private var walletAddresses: Set<String> {
        Set(walletService.addresses.values.map { $0.lowercased() })
    }

    /// Transactions filtered to this specific token.
    /// For native tokens (ETH, MATIC, etc.): matches by tokenSymbol + chain where contractAddress is nil.
    /// For ERC-20 tokens (USDT, USDC, etc.): matches by contractAddress + chain.
    private var tokenTransactions: [TransactionModel] {
        walletService.transactions.filter { tx in
            guard tx.chain == token.chain else { return false }
            if let tokenContract = token.contractAddress?.lowercased(),
               let txContract = tx.contractAddress?.lowercased() {
                return tokenContract == txContract
            }
            // Native token: match symbol and ensure tx has no contract (native transfer)
            return tx.tokenSymbol == token.symbol && tx.contractAddress == nil
        }
    }

    private func tokenTransactionRow(_ tx: TransactionModel) -> some View {
        let isSent = walletAddresses.contains(tx.from.lowercased())
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let timeStr = formatter.localizedString(for: tx.timestamp, relativeTo: Date())

        return HStack(spacing: 12) {
            Image(systemName: isSent ? "arrow.up.right" : "arrow.down.left")
                .font(.body.bold())
                .foregroundColor(isSent ? .error : .success)
                .frame(width: 36, height: 36)
                .background((isSent ? Color.error : Color.success).opacity(0.1))
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: 2) {
                Text(isSent ? "Sent" : "Received")
                    .font(.subheadline.bold())
                    .foregroundColor(.textPrimary)
                Text(isSent ? tx.shortTo : tx.shortFrom)
                    .font(.caption.monospaced())
                    .foregroundColor(.textTertiary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text((isSent ? "-" : "+") + tx.formattedAmount)
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(isSent ? .error : .success)
                Text(timeStr)
                    .font(.caption2)
                    .foregroundColor(.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

#Preview {
    NavigationStack {
        TokenDetailView(
            token: TokenModel(symbol: "ETH", name: "Ethereum", chain: "ethereum", balance: 1.5, priceUsd: 3500)
        )
        .environmentObject(WalletService.shared)
        .environmentObject(AppRouter())
    }
}
