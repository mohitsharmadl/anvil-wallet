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
    @State private var showBridge = false
    @State private var showStaking = false
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

    private var chainBreakdown: [(chain: String, total: Double)] {
        var totals: [String: Double] = [:]
        for token in walletService.tokens {
            totals[token.chain, default: 0] += token.balanceUsd
        }
        let sorted = totals
            .map { (chain: $0.key, total: $0.value) }
            .sorted { $0.total > $1.total }
        return Array(sorted.prefix(3))
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
                        .padding(.bottom, 18)

                    chainAllocation
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)

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
                        if !walletService.watchPortfolio.isEmpty {
                            watchOnlySection
                                .padding(.horizontal, 20)
                                .padding(.top, 14)
                        }
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
                                .frame(width: 44, height: 44)
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
                    .buttonStyle(.plain)
                    .accessibilityLabel(notificationService.unreadCount > 0
                        ? "Notifications, \(notificationService.unreadCount) unread"
                        : "Notifications")
                    .accessibilityHint("Double tap to view notifications")
                }
            }
            .sheet(isPresented: $showSwap) {
                SwapView()
            }
            .sheet(isPresented: $showBuy) {
                BuyView()
            }
            .sheet(isPresented: $showBridge) {
                BridgeView()
            }
            .sheet(isPresented: $showStaking) {
                StakingView()
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

    private var chainAllocation: some View {
        HStack(spacing: 8) {
            if chainBreakdown.isEmpty {
                Label("No balances yet", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundColor(.textTertiary)
            } else {
                ForEach(chainBreakdown, id: \.chain) { item in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.accentGreen.opacity(0.2))
                            .frame(width: 8, height: 8)
                        Text("\(item.chain.capitalized): $\(String(format: "%.2f", item.total))")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.backgroundCard)
                    .clipShape(Capsule())
                }
            }
            Spacer()
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
                        .minimumScaleFactor(0.5)
                } else {
                    Text(formattedBalance)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundColor(.textPrimary)
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.5)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isBalanceHidden ? "Balance hidden" : "Total balance: \(formattedBalance)")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isBalanceHidden.toggle() }
                Haptic.impact(.light)
            } label: {
                Image(systemName: isBalanceHidden ? "eye.slash" : "eye")
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.textTertiary)
                    .padding(6)
                    .background(Color.backgroundCard)
                    .clipShape(Circle())
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(isBalanceHidden ? "Show balance" : "Hide balance")
            .accessibilityHint("Double tap to toggle balance visibility")
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
                Haptic.impact(.medium)
                showBuy = true
            }
            .accessibilityHint("Double tap to buy crypto")
            ActionPill(icon: "arrow.up.right", label: "Send", color: .accentGreen) {
                Haptic.impact(.medium)
                router.navigateToTab(.send)
            }
            .accessibilityHint("Double tap to send tokens")
            ActionPill(icon: "arrow.down.left", label: "Receive", color: .info) {
                Haptic.impact(.medium)
                router.walletPath.append(AppRouter.WalletDestination.chainPicker)
            }
            .accessibilityHint("Double tap to receive tokens")
            ActionPill(icon: "arrow.left.arrow.right", label: "Swap", color: .chainSolana) {
                Haptic.impact(.medium)
                showSwap = true
            }
            .accessibilityHint("Double tap to swap tokens")
            ActionPill(icon: "arrow.triangle.branch", label: "Bridge", color: .chainEthereum) {
                Haptic.impact(.medium)
                showBridge = true
            }
            .accessibilityHint("Double tap to bridge tokens across chains")
            ActionPill(icon: "chart.line.uptrend.xyaxis", label: "Stake", color: .warning) {
                Haptic.impact(.medium)
                showStaking = true
            }
            .accessibilityHint("Double tap to stake tokens")
        }
    }

    // MARK: - Account Switcher

    private var accountSwitcher: some View {
        Button {
            Haptic.impact(.light)
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
        .frame(minHeight: 44)
        .accessibilityLabel("Switch account: \(walletService.currentWallet?.displayName ?? "Account 0")")
        .accessibilityHint("Double tap to switch wallet accounts")
    }

    // MARK: - Segment Picker

    private var segmentPicker: some View {
        HStack(spacing: 0) {
            ForEach(WalletSegment.allCases, id: \.self) { segment in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedSegment = segment
                    }
                    Haptic.selection()
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
                .accessibilityLabel("\(segment.rawValue) tab")
                .accessibilityAddTraits(selectedSegment == segment ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
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
        try? await walletService.refreshWatchOnlyData()
        isRefreshing = false
    }

    private var watchOnlySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Watch-Only Portfolio")
                    .font(.headline)
                    .foregroundColor(.textPrimary)
                Spacer()
                NavigationLink(destination: WatchAddressesView()) {
                    Text("Manage")
                        .font(.caption.bold())
                        .foregroundColor(.accentGreen)
                }
            }

            ForEach(walletService.watchPortfolio.prefix(4)) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.subheadline.bold())
                            .foregroundColor(.textPrimary)
                        Text("\(item.chainId.capitalized) • \(item.address.prefix(8))...\(item.address.suffix(6))")
                            .font(.caption.monospaced())
                            .foregroundColor(.textTertiary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.6f %@", item.balanceNative, item.nativeSymbol))
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(.textPrimary)
                        Text(String(format: "$%.2f", item.balanceUsd))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.textSecondary)
                    }
                }
                .padding(12)
                .background(Color.backgroundCard)
                .cornerRadius(12)
            }
        }
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
        .frame(maxWidth: .infinity, minHeight: 44)
        .buttonStyle(ScaleButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
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
