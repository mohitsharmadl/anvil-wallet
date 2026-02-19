import SwiftUI

/// WalletHomeView is the main wallet screen showing total balance
/// and the list of tokens across all chains.
struct WalletHomeView: View {
    @EnvironmentObject var walletService: WalletService
    @EnvironmentObject var router: AppRouter

    @State private var isRefreshing = false
    @State private var showSwap = false
    @State private var isBalanceHidden = false

    private var totalBalanceUsd: Double {
        walletService.tokens.reduce(0) { $0 + $1.balanceUsd }
    }

    var body: some View {
        NavigationStack(path: $router.walletPath) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Hero balance section
                    balanceSection
                        .padding(.top, 8)
                        .padding(.bottom, 28)

                    // Quick actions
                    actionButtons
                        .padding(.horizontal, 20)
                        .padding(.bottom, 32)

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
                        Image(systemName: "bell")
                            .font(.body.weight(.medium))
                            .foregroundColor(.textSecondary)
                            .frame(width: 36, height: 36)
                            .background(Color.backgroundCard)
                            .clipShape(Circle())
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

    // MARK: - Balance Section

    private var balanceSection: some View {
        VStack(spacing: 6) {
            Text("Total Balance")
                .font(.subheadline.weight(.medium))
                .foregroundColor(.textSecondary)

            HStack(spacing: 8) {
                if isBalanceHidden {
                    Text("*****")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundColor(.textPrimary)
                } else {
                    Text(formattedBalance)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundColor(.textPrimary)
                        .contentTransition(.numericText())
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isBalanceHidden.toggle() }
            } label: {
                Image(systemName: isBalanceHidden ? "eye.slash" : "eye")
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.textTertiary)
                    .padding(6)
                    .background(Color.backgroundCard)
                    .clipShape(Circle())
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 20)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            ActionPill(icon: "arrow.up.right", label: "Send", color: .accentGreen) {
                router.navigateToTab(.send)
            }
            ActionPill(icon: "arrow.down.left", label: "Receive", color: .info) {
                router.walletPath.append(AppRouter.WalletDestination.chainPicker)
            }
            ActionPill(icon: "arrow.left.arrow.right", label: "Swap", color: .chainSolana) {
                showSwap = true
            }
            ActionPill(icon: "clock", label: "Activity", color: .warning) {
                router.walletPath.append(AppRouter.WalletDestination.activity)
            }
        }
    }

    private var formattedBalance: String {
        if totalBalanceUsd < 0.01 && totalBalanceUsd > 0 {
            return "<$0.01"
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: totalBalanceUsd)) ?? "$0.00"
    }

    private func refreshData() async {
        isRefreshing = true
        try? await walletService.refreshBalances()
        try? await walletService.refreshPrices()
        isRefreshing = false
    }
}

// MARK: - Action Pill Button

private struct ActionPill: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.12))
                        .frame(width: 52, height: 52)

                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(color)
                }

                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.textPrimary)
            }
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Scale Button Style

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

#Preview {
    WalletHomeView()
        .environmentObject(WalletService.shared)
        .environmentObject(AppRouter())
}
