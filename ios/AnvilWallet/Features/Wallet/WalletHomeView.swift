import SwiftUI

/// WalletHomeView is the main wallet screen showing total balance
/// and the list of tokens across all chains.
struct WalletHomeView: View {
    @EnvironmentObject var walletService: WalletService
    @EnvironmentObject var router: AppRouter

    @State private var isRefreshing = false
    @State private var showSwap = false

    private var totalBalanceUsd: Double {
        walletService.tokens.reduce(0) { $0 + $1.balanceUsd }
    }

    var body: some View {
        NavigationStack(path: $router.walletPath) {
            ScrollView {
                VStack(spacing: 24) {
                    // Balance card
                    BalanceCardView(totalBalance: totalBalanceUsd)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                    // Quick actions
                    HStack(spacing: 16) {
                        QuickActionButton(icon: "paperplane.fill", label: "Send") {
                            router.navigateToTab(.send)
                        }
                        QuickActionButton(icon: "qrcode", label: "Receive") {
                            router.walletPath.append(AppRouter.WalletDestination.chainPicker)
                        }
                        QuickActionButton(icon: "arrow.left.arrow.right", label: "Swap") {
                            showSwap = true
                        }
                        QuickActionButton(icon: "clock.arrow.circlepath", label: "Activity") {
                            router.walletPath.append(AppRouter.WalletDestination.activity)
                        }
                    }
                    .padding(.horizontal, 20)

                    // Token list
                    TokenListView()
                }
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Wallet")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // TODO: Navigate to notifications
                    } label: {
                        Image(systemName: "bell.fill")
                            .foregroundColor(.textSecondary)
                    }
                }
            }
            .sheet(isPresented: $showSwap) {
                SwapView()
            }
            .refreshable {
                await refreshData()
            }
            .navigationDestination(for: AppRouter.WalletDestination.self) { destination in
                switch destination {
                case .tokenDetail(let token):
                    TokenDetailView(token: token)
                case .chainPicker:
                    ChainPickerView()
                case .receive(let chain, let address):
                    ReceiveView(chain: chain, address: address)
                case .activity:
                    ActivityView()
                }
            }
        }
    }

    private func refreshData() async {
        isRefreshing = true
        try? await walletService.refreshBalances()
        try? await walletService.refreshPrices()
        isRefreshing = false
    }
}

// MARK: - Balance Card

private struct BalanceCardView: View {
    let totalBalance: Double

    @State private var isBalanceHidden = false

    var body: some View {
        VStack(spacing: 8) {
            Text("Total Balance")
                .font(.subheadline)
                .foregroundColor(.textSecondary)

            if isBalanceHidden {
                Text("********")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.textPrimary)
            } else {
                Text(String(format: "$%.2f", totalBalance))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.textPrimary)
            }

            Button {
                withAnimation { isBalanceHidden.toggle() }
            } label: {
                Image(systemName: isBalanceHidden ? "eye.slash.fill" : "eye.fill")
                    .font(.caption)
                    .foregroundColor(.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            LinearGradient(
                colors: [Color.backgroundCard, Color.backgroundElevated],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.border, lineWidth: 1)
        )
    }
}

// MARK: - Quick Action Button

private struct QuickActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(.accentGreen)
                    .frame(width: 48, height: 48)
                    .background(Color.accentGreen.opacity(0.1))
                    .cornerRadius(14)

                Text(label)
                    .font(.caption)
                    .foregroundColor(.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    WalletHomeView()
        .environmentObject(WalletService.shared)
        .environmentObject(AppRouter())
}
