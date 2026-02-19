import SwiftUI

/// WalletHomeView is the main wallet screen showing total balance
/// and the list of tokens across all chains.
struct WalletHomeView: View {
    @EnvironmentObject var walletService: WalletService
    @EnvironmentObject var router: AppRouter

    @ObservedObject private var notificationService = NotificationService.shared

    @State private var isRefreshing = false
    @State private var showSwap = false
    @State private var showBuy = false
    @State private var isBalanceHidden = false
    @State private var showAccountPicker = false
    @State private var selectedSegment: WalletSegment = .tokens

    enum WalletSegment: String, CaseIterable {
        case tokens = "Tokens"
        case nfts = "NFTs"
    }

    private var totalBalanceUsd: Double {
        walletService.tokens.reduce(0) { $0 + $1.balanceUsd }
    }

    var body: some View {
        NavigationStack(path: $router.walletPath) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Account switcher chip
                    accountSwitcher
                        .padding(.top, 4)

                    // Hero balance section
                    balanceSection
                        .padding(.top, 4)
                        .padding(.bottom, 28)

                    // Quick actions
                    actionButtons
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)

                    // Tokens / NFTs segment picker
                    segmentPicker
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)

                    // Content based on selected segment
                    switch selectedSegment {
                    case .tokens:
                        TokenListView()
                    case .nfts:
                        NFTListView()
                    }
                }
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Wallet")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: AppRouter.WalletDestination.notifications) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "bell")
                                .font(.body.weight(.medium))
                                .foregroundColor(.textSecondary)
                                .frame(width: 36, height: 36)
                                .background(Color.backgroundCard)
                                .clipShape(Circle())

                            if notificationService.unreadCount > 0 {
                                Text("\(min(notificationService.unreadCount, 99))")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(minWidth: 16, minHeight: 16)
                                    .background(Color.error)
                                    .clipShape(Circle())
                                    .offset(x: 4, y: -4)
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showSwap) {
                SwapView()
            }
            .sheet(isPresented: $showBuy) {
                BuyView()
            }
            .sheet(isPresented: $showAccountPicker) {
                AccountPickerView()
                    .presentationDetents([.medium, .large])
            }
            .refreshable {
                await refreshData()
            }
            .navigationDestination(for: AppRouter.WalletDestination.self) { destination in
                switch destination {
                case .tokenDetail(let token):
                    TokenDetailView(token: token)
                case .nftDetail(let nft):
                    NFTDetailView(nft: nft)
                case .chainPicker:
                    ChainPickerView()
                case .receive(let chain, let address):
                    ReceiveView(chain: chain, address: address)
                case .activity:
                    ActivityView()
                case .notifications:
                    NotificationHistoryView()
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
            ActionPill(icon: "plus.circle", label: "Buy", color: .accentGreen) {
                showBuy = true
            }
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

    // MARK: - Account Switcher

    private var accountSwitcher: some View {
        Button {
            showAccountPicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.accentGreen)

                Text(walletService.currentWallet?.displayName ?? "Account 0")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.textPrimary)

                Image(systemName: "chevron.down")
                    .font(.caption2.bold())
                    .foregroundColor(.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.backgroundCard)
            .clipShape(Capsule())
        }
    }

    // MARK: - Segment Picker

    private var segmentPicker: some View {
        HStack(spacing: 0) {
            ForEach(WalletSegment.allCases, id: \.self) { segment in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedSegment = segment
                    }
                } label: {
                    Text(segment.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(selectedSegment == segment ? .textPrimary : .textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            selectedSegment == segment
                                ? Color.backgroundCard
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(3)
        .background(Color.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
