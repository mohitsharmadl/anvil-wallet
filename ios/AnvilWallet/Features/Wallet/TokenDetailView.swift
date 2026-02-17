import SwiftUI

/// TokenDetailView shows detailed information about a specific token,
/// including balance, price chart placeholder, and recent transactions.
struct TokenDetailView: View {
    @EnvironmentObject var walletService: WalletService
    @EnvironmentObject var router: AppRouter

    let token: TokenModel

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Token header
                VStack(spacing: 12) {
                    Circle()
                        .fill(Color.accentGreen.opacity(0.2))
                        .frame(width: 64, height: 64)
                        .overlay(
                            Text(token.symbol)
                                .font(.title3.bold())
                                .foregroundColor(.accentGreen)
                        )

                    Text(token.name)
                        .font(.title2.bold())
                        .foregroundColor(.textPrimary)

                    Text(token.formattedBalance + " " + token.symbol)
                        .font(.title3.monospacedDigit())
                        .foregroundColor(.textPrimary)

                    Text(token.formattedBalanceUsd)
                        .font(.headline)
                        .foregroundColor(.textSecondary)
                }
                .padding(.top, 16)

                // Price info
                VStack(spacing: 8) {
                    HStack {
                        Text("Price")
                            .foregroundColor(.textSecondary)
                        Spacer()
                        Text(String(format: "$%.2f", token.priceUsd))
                            .foregroundColor(.textPrimary)
                            .monospacedDigit()
                    }

                    HStack {
                        Text("Chain")
                            .foregroundColor(.textSecondary)
                        Spacer()
                        Text(token.chain.capitalized)
                            .foregroundColor(.textPrimary)
                    }

                    if let contractAddress = token.contractAddress {
                        HStack {
                            Text("Contract")
                                .foregroundColor(.textSecondary)
                            Spacer()
                            Text(contractAddress.prefix(6) + "..." + contractAddress.suffix(4))
                                .foregroundColor(.textPrimary)
                                .monospacedDigit()

                            Button {
                                ClipboardManager.shared.copyToClipboard(contractAddress)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                                    .foregroundColor(.accentGreen)
                            }
                        }
                    }

                    HStack {
                        Text("Decimals")
                            .foregroundColor(.textSecondary)
                        Spacer()
                        Text("\(token.decimals)")
                            .foregroundColor(.textPrimary)
                    }
                }
                .font(.body)
                .padding()
                .background(Color.backgroundCard)
                .cornerRadius(16)
                .padding(.horizontal, 20)

                // Price chart placeholder
                VStack(spacing: 8) {
                    Text("Price Chart")
                        .font(.headline)
                        .foregroundColor(.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.backgroundCard)
                        .frame(height: 200)
                        .overlay(
                            Text("Chart coming in Phase 4")
                                .font(.subheadline)
                                .foregroundColor(.textTertiary)
                        )
                }
                .padding(.horizontal, 20)

                // Action buttons
                HStack(spacing: 16) {
                    Button {
                        router.navigateToTab(.send)
                    } label: {
                        Label("Send", systemImage: "paperplane.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentGreen)
                            .cornerRadius(12)
                    }

                    Button {
                        if let address = walletService.addresses[token.chain] {
                            router.walletPath.append(
                                AppRouter.WalletDestination.receive(chain: token.chain, address: address)
                            )
                        }
                    } label: {
                        Label("Receive", systemImage: "qrcode")
                            .font(.headline)
                            .foregroundColor(.accentGreen)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentGreen.opacity(0.1))
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 20)

                // Recent transactions placeholder
                VStack(spacing: 12) {
                    Text("Recent Transactions")
                        .font(.headline)
                        .foregroundColor(.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("No transactions yet")
                        .font(.body)
                        .foregroundColor(.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .background(Color.backgroundCard)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .background(Color.backgroundPrimary)
        .navigationTitle(token.symbol)
        .navigationBarTitleDisplayMode(.inline)
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
