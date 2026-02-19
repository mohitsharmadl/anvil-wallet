import SwiftUI

/// TokenDetailView shows detailed information about a specific token,
/// including balance, price chart placeholder, and recent transactions.
struct TokenDetailView: View {
    @EnvironmentObject var walletService: WalletService
    @EnvironmentObject var router: AppRouter

    let token: TokenModel

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
                                ClipboardManager.shared.copyToClipboard(contractAddress)
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

                // Chart placeholder
                VStack(spacing: 12) {
                    Text("Price Chart")
                        .font(.headline)
                        .foregroundColor(.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.backgroundCard)
                        .frame(height: 180)
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "chart.xyaxis.line")
                                    .font(.title2)
                                    .foregroundColor(.textTertiary)
                                Text("Coming soon")
                                    .font(.caption)
                                    .foregroundColor(.textTertiary)
                            }
                        )
                }
                .padding(.horizontal, 20)

                // Recent transactions
                VStack(spacing: 12) {
                    Text("Recent Transactions")
                        .font(.headline)
                        .foregroundColor(.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)

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
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .background(Color.backgroundPrimary)
        .navigationTitle(token.symbol)
        .navigationBarTitleDisplayMode(.inline)
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
