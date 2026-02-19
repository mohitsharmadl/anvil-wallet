import SwiftUI

/// BridgeView lets users bridge tokens between supported EVM chains.
///
/// Flow: select source chain + token -> select destination chain -> enter amount ->
/// fetch routes from Socket API -> select best route -> confirm.
struct BridgeView: View {
    @EnvironmentObject var walletService: WalletService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var bridgeService = BridgeService.shared

    @State private var fromChainId: Int = 1
    @State private var toChainId: Int = 137
    @State private var amount = ""
    @State private var selectedRoute: BridgeService.BridgeRoute?
    @State private var showConfirmation = false

    private var fromChainName: String {
        BridgeService.supportedChains.first { $0.chainId == fromChainId }?.name ?? "Unknown"
    }

    private var toChainName: String {
        BridgeService.supportedChains.first { $0.chainId == toChainId }?.name ?? "Unknown"
    }

    /// ETH address from the wallet (used for all EVM chains).
    private var userAddress: String {
        walletService.addresses["ethereum"] ?? ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Chain selectors
                    chainSelectors

                    // Amount input
                    amountSection

                    // Fetch routes button
                    Button {
                        Task { await fetchRoutes() }
                    } label: {
                        Text("Find Routes")
                    }
                    .buttonStyle(.primary)
                    .disabled(amount.isEmpty || fromChainId == toChainId)
                    .padding(.horizontal, 20)

                    // Routes
                    if bridgeService.isLoading {
                        ProgressView("Finding best routes...")
                            .padding(.vertical, 32)
                    }

                    if let error = bridgeService.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.error)
                            .padding(.horizontal, 20)
                    }

                    if !bridgeService.routes.isEmpty {
                        routesList
                    }
                }
                .padding(.top, 16)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Bridge")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
            }
            .alert("Confirm Bridge", isPresented: $showConfirmation) {
                Button("Bridge", role: .none) {
                    // In production, this would build + sign + broadcast the bridge tx
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let route = selectedRoute {
                    Text("Bridge via \(route.bridgeName)\nEstimated output: \(route.estimatedOutputFormatted)\nGas: ~$\(String(format: "%.2f", route.estimatedGasUsd))\nTime: ~\(route.estimatedTimeMinutes) min")
                }
            }
        }
    }

    // MARK: - Chain Selectors

    private var chainSelectors: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // From chain
                VStack(alignment: .leading, spacing: 6) {
                    Text("From")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.textTertiary)

                    Menu {
                        ForEach(BridgeService.supportedChains, id: \.chainId) { chain in
                            Button(chain.name) {
                                fromChainId = chain.chainId
                            }
                        }
                    } label: {
                        HStack {
                            Text(fromChainName)
                                .font(.body.bold())
                                .foregroundColor(.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .foregroundColor(.textTertiary)
                        }
                        .padding(14)
                        .background(Color.backgroundCard)
                        .cornerRadius(12)
                    }
                }

                // Swap direction
                Button {
                    let temp = fromChainId
                    fromChainId = toChainId
                    toChainId = temp
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.body.weight(.medium))
                        .foregroundColor(.accentGreen)
                        .frame(width: 36, height: 36)
                        .background(Color.accentGreen.opacity(0.1))
                        .cornerRadius(18)
                }
                .padding(.top, 20)

                // To chain
                VStack(alignment: .leading, spacing: 6) {
                    Text("To")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.textTertiary)

                    Menu {
                        ForEach(BridgeService.supportedChains, id: \.chainId) { chain in
                            Button(chain.name) {
                                toChainId = chain.chainId
                            }
                        }
                    } label: {
                        HStack {
                            Text(toChainName)
                                .font(.body.bold())
                                .foregroundColor(.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .foregroundColor(.textTertiary)
                        }
                        .padding(14)
                        .background(Color.backgroundCard)
                        .cornerRadius(12)
                    }
                }
            }
            .padding(.horizontal, 20)

            if fromChainId == toChainId {
                Text("Source and destination chains must be different")
                    .font(.caption)
                    .foregroundColor(.error)
                    .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Amount Section

    private var amountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Amount (ETH)")
                .font(.caption.weight(.medium))
                .foregroundColor(.textTertiary)

            HStack {
                TextField("0.0", text: $amount)
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundColor(.textPrimary)
                    .keyboardType(.decimalPad)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("ETH")
                        .font(.subheadline.bold())
                        .foregroundColor(.textPrimary)

                    if let ethBalance = walletService.tokens.first(where: { $0.symbol == "ETH" && $0.chain == "ethereum" })?.balance {
                        Button {
                            amount = String(format: "%.6f", ethBalance)
                        } label: {
                            Text("Max: \(String(format: "%.4f", ethBalance))")
                                .font(.caption)
                                .foregroundColor(.accentGreen)
                        }
                    }
                }
            }
            .padding(14)
            .background(Color.backgroundCard)
            .cornerRadius(12)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Routes List

    private var routesList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Available Routes")
                .font(.headline)
                .foregroundColor(.textPrimary)

            ForEach(bridgeService.routes) { route in
                Button {
                    selectedRoute = route
                    showConfirmation = true
                } label: {
                    RouteCard(route: route)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Data

    private func fetchRoutes() async {
        guard let amountDouble = Double(amount), amountDouble > 0 else { return }

        // Convert to wei (18 decimals for ETH)
        let weiAmount = String(format: "%.0f", amountDouble * 1e18)

        let fromToken = BridgeService.nativeTokenAddress(chainId: fromChainId)
        let toToken = BridgeService.nativeTokenAddress(chainId: toChainId)

        await bridgeService.fetchRoutes(
            fromChainId: fromChainId,
            toChainId: toChainId,
            fromTokenAddress: fromToken,
            toTokenAddress: toToken,
            amount: weiAmount,
            userAddress: userAddress,
            decimals: 18
        )
    }
}

// MARK: - Route Card

private struct RouteCard: View {
    let route: BridgeService.BridgeRoute

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(route.bridgeName)
                        .font(.body.bold())
                        .foregroundColor(.textPrimary)

                    Text("~\(route.estimatedTimeMinutes) min")
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(route.estimatedOutputFormatted)
                        .font(.body.bold().monospacedDigit())
                        .foregroundColor(.textPrimary)

                    Text("Gas: ~$\(String(format: "%.2f", route.estimatedGasUsd))")
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                }
            }
        }
        .padding(16)
        .background(Color.backgroundCard)
        .cornerRadius(12)
    }
}

#Preview {
    BridgeView()
        .environmentObject(WalletService.shared)
}
