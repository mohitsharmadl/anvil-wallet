import SwiftUI

/// SwapView allows users to swap tokens on supported EVM chains via 0x
/// and on Solana via Jupiter.
///
/// Flow: select chain -> pick from/to tokens -> enter amount -> set slippage ->
/// get quote -> review rate/impact/gas/sources -> confirm swap -> sign + broadcast.
struct SwapView: View {
    @EnvironmentObject var walletService: WalletService
    @StateObject private var viewModel = SwapViewModel()

    @Environment(\.dismiss) private var dismiss

    @State private var showFromTokenPicker = false
    @State private var showToTokenPicker = false
    @State private var showConfirmation = false

    var body: some View {
        NavigationStack {
            scrollContent
                .background(Color.backgroundPrimary)
                .navigationTitle("Swap")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                            .foregroundColor(.textSecondary)
                    }
                }
                .hideKeyboard()
                .loadingOverlay(
                    isLoading: viewModel.isLoadingQuote,
                    message: "Fetching quote..."
                )
                .sheet(isPresented: $showFromTokenPicker) {
                    SwapTokenPickerSheet(
                        tokens: tokensForSelectedChain,
                        selectedToken: $viewModel.fromToken
                    )
                }
                .sheet(isPresented: $showToTokenPicker) {
                    SwapTokenPickerSheet(
                        tokens: swappableTokens(excluding: viewModel.fromToken),
                        selectedToken: $viewModel.toToken
                    )
                }
                .sheet(isPresented: $showConfirmation) {
                    confirmationSheetContent
                }
                .onAppear(perform: handleOnAppear)
                .onChange(of: viewModel.fromToken) { handleTokenChange() }
                .onChange(of: viewModel.toToken) { handleTokenChange() }
                .onChange(of: viewModel.selectedChainId) { handleChainChange() }
                .onChange(of: viewModel.quote) { handleQuoteChange() }
                .onChange(of: viewModel.txHash) { handleSwapCompleted() }
        }
    }

    // MARK: - Chain Selector

    private var chainSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chain")
                .font(.caption.weight(.medium))
                .foregroundColor(.textTertiary)

            Menu {
                ForEach(SwapService.supportedChains, id: \.chainId) { chain in
                    Button(chain.name) {
                        viewModel.selectedChainId = chain.chainId
                    }
                }
                // Solana option
                Button("Solana") {
                    viewModel.selectedChainId = 0  // sentinel for Solana
                }
            } label: {
                HStack {
                    Text(viewModel.selectedChainName)
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

    // MARK: - Slippage Selector

    private var slippageSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Slippage Tolerance")
                .font(.caption.weight(.medium))
                .foregroundColor(.textTertiary)

            HStack(spacing: 8) {
                ForEach(SwapViewModel.slippagePresets, id: \.self) { preset in
                    Button {
                        viewModel.slippageBps = preset
                        viewModel.quote = nil
                    } label: {
                        Text(SwapViewModel.slippageLabel(bps: preset))
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(
                                viewModel.slippageBps == preset
                                    ? .white
                                    : .textSecondary
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                viewModel.slippageBps == preset
                                    ? Color.accentGreen
                                    : Color.backgroundCard
                            )
                            .cornerRadius(10)
                    }
                }
            }
        }
    }

    // MARK: - Event Handlers

    @ViewBuilder
    private var confirmationSheetContent: some View {
        if let fromToken = viewModel.fromToken, let toToken = viewModel.toToken {
            SwapConfirmationSheet(
                viewModel: viewModel,
                fromToken: fromToken,
                toToken: toToken
            )
        }
    }

    private func handleOnAppear() {
        if viewModel.fromToken == nil {
            viewModel.fromToken = walletService.tokens.first(where: {
                $0.chain == viewModel.selectedChainModelId
            })
        }
    }

    private func handleTokenChange() {
        viewModel.quote = nil
        viewModel.error = nil
    }

    private func handleChainChange() {
        viewModel.cancelAutoQuote()
        viewModel.fromToken = walletService.tokens.first(where: {
            $0.chain == viewModel.selectedChainModelId
        })
        viewModel.toToken = nil
        viewModel.fromAmount = ""
        viewModel.toAmount = ""
        viewModel.quote = nil
        viewModel.error = nil
    }

    private func handleQuoteChange() {
        if viewModel.quote != nil && viewModel.txHash == nil {
            viewModel.error = nil
            showConfirmation = true
        }
    }

    private func handleSwapCompleted() {
        guard let txHash = viewModel.txHash,
              let fromToken = viewModel.fromToken,
              let toToken = viewModel.toToken else { return }

        let chainId = viewModel.selectedChainModelId

        // Record "sent" side (from token)
        let sentTx = TransactionModel(
            hash: txHash,
            chain: chainId,
            from: walletService.addresses[chainId] ?? "",
            to: "Swap",
            amount: viewModel.fromAmount,
            status: .pending,
            tokenSymbol: fromToken.symbol,
            tokenDecimals: fromToken.decimals,
            contractAddress: fromToken.contractAddress
        )
        walletService.recordLocalTransaction(sentTx)

        // Record "received" side (to token) with a synthetic hash suffix to avoid dedup
        let receivedTx = TransactionModel(
            hash: txHash + "-recv",
            chain: chainId,
            from: "Swap",
            to: walletService.addresses[chainId] ?? "",
            amount: viewModel.toAmount,
            status: .pending,
            tokenSymbol: toToken.symbol,
            tokenDecimals: toToken.decimals,
            contractAddress: toToken.contractAddress
        )
        walletService.recordLocalTransaction(receivedTx)

        TransactionHistoryService.shared.invalidateCache(for: chainId)

        // Refresh balances and transactions in background
        Task {
            try? await walletService.refreshTransactions()
            try? await walletService.refreshBalances()
        }
    }

    // MARK: - Scroll Content

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                chainSelector
                    .padding(.horizontal, 20)

                slippageSelector
                    .padding(.horizontal, 20)

                SwapTokenSection(
                    label: "From",
                    token: viewModel.fromToken,
                    amount: Binding(
                        get: { viewModel.fromAmount },
                        set: { viewModel.setFromAmount($0) }
                    ),
                    isEditable: true,
                    showMaxButton: true,
                    onTokenTap: { showFromTokenPicker = true }
                )
                .padding(.horizontal, 20)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.swapTokens()
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.title3)
                        .foregroundColor(.accentGreen)
                        .frame(width: 44, height: 44)
                        .background(Color.accentGreen.opacity(0.1))
                        .cornerRadius(22)
                }

                SwapTokenSection(
                    label: "To",
                    token: viewModel.toToken,
                    amount: Binding(
                        get: { viewModel.toAmount },
                        set: { viewModel.setToAmount($0) }
                    ),
                    isEditable: true,
                    showMaxButton: false,
                    onTokenTap: { showToTokenPicker = true }
                )
                .padding(.horizontal, 20)

                if let quote = viewModel.quote {
                    QuoteDetailsView(
                        quote: quote,
                        exchangeRate: viewModel.exchangeRateDisplay,
                        guaranteedPriceFormatted: viewModel.guaranteedPriceDisplay
                    )
                    .padding(.horizontal, 20)
                }

                if let error = viewModel.error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.error)
                        .padding(.horizontal, 20)
                }

                successSection

                Spacer(minLength: 40)

                actionButtons
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Success & Action Sections

    @ViewBuilder
    private var successSection: some View {
        if let txHash = viewModel.txHash {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundColor(.accentGreen)
                Text("Swap submitted")
                    .font(.headline)
                    .foregroundColor(.textPrimary)
                Text(txHash)
                    .font(.caption)
                    .foregroundColor(.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if viewModel.txHash == nil {
            Button {
                if viewModel.quote != nil {
                    showConfirmation = true
                } else {
                    viewModel.cancelAutoQuote()
                    Task { await viewModel.fetchQuote() }
                }
            } label: {
                Text(viewModel.quote != nil ? "Review Swap" : "Swap")
            }
            .buttonStyle(PrimaryButtonStyle(isEnabled: viewModel.canGetQuote))
            .disabled(!viewModel.canGetQuote)
            .padding(.horizontal, 20)
        } else {
            Button {
                dismiss()
            } label: {
                Text("Done")
            }
            .buttonStyle(.primary)
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Helpers

    /// Tokens available for the selected chain.
    private var tokensForSelectedChain: [TokenModel] {
        walletService.tokens.filter { $0.chain == viewModel.selectedChainModelId }
    }

    /// Filters tokens to only those on the same chain as the selected from token,
    /// excluding the from token itself.
    private func swappableTokens(excluding token: TokenModel?) -> [TokenModel] {
        let chainFilter = viewModel.selectedChainModelId
        return walletService.tokens.filter { t in
            t.chain == chainFilter && t.id != token?.id
        }
    }
}

// MARK: - Swap Confirmation Sheet

private struct SwapConfirmationSheet: View {
    @ObservedObject var viewModel: SwapViewModel
    let fromToken: TokenModel
    let toToken: TokenModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // You pay
                    tokenCard(
                        label: "You pay",
                        token: fromToken,
                        amount: viewModel.fromAmount
                    )

                    // Arrow
                    Image(systemName: "arrow.down")
                        .font(.title3)
                        .foregroundColor(.accentGreen)
                        .frame(width: 36, height: 36)
                        .background(Color.accentGreen.opacity(0.1))
                        .cornerRadius(18)

                    // You receive
                    tokenCard(
                        label: "You receive",
                        token: toToken,
                        amount: viewModel.toAmount
                    )

                    // Quote details
                    if let quote = viewModel.quote {
                        VStack(spacing: 10) {
                            if let rate = viewModel.exchangeRateDisplay {
                                QuoteRow(label: "Rate", value: rate)
                            }
                            if let minRecv = viewModel.guaranteedPriceDisplay {
                                QuoteRow(label: "Min. Received", value: minRecv)
                            }
                            if quote.priceImpact > 0 {
                                QuoteRow(
                                    label: "Price Impact",
                                    value: String(format: "%.2f%%", quote.priceImpact),
                                    valueColor: quote.priceImpact > 1.0 ? .error : .textSecondary
                                )
                            }
                            if let sources = quote.sources, !sources.isEmpty {
                                QuoteRow(
                                    label: "Route",
                                    value: sources.map { $0.name }.joined(separator: ", ")
                                )
                            } else if !quote.route.label.isEmpty {
                                QuoteRow(label: "Route", value: quote.route.label)
                            }
                            QuoteRow(
                                label: "Slippage",
                                value: SwapViewModel.slippageLabel(bps: viewModel.slippageBps)
                            )
                        }
                        .padding(14)
                        .background(Color.backgroundCard)
                        .cornerRadius(12)
                    }

                    // Face ID note
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundColor(.textTertiary)
                        Text("Requires Face ID")
                            .font(.caption)
                            .foregroundColor(.textTertiary)
                    }

                    // Error inside sheet
                    if let error = viewModel.error {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.error)
                    }

                    // Confirm button
                    Button {
                        Task { await viewModel.executeSwap() }
                    } label: {
                        if viewModel.isExecutingSwap {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .tint(.white)
                                Text("Swapping...")
                            }
                        } else {
                            Text("Confirm Swap")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(isEnabled: !viewModel.isExecutingSwap))
                    .disabled(viewModel.isExecutingSwap)

                    // Cancel button
                    Button("Cancel") { dismiss() }
                        .font(.body)
                        .foregroundColor(.textSecondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Review Swap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.textTertiary)
                    }
                }
            }
            .onChange(of: viewModel.txHash) {
                if viewModel.txHash != nil {
                    dismiss()
                }
            }
        }
        .presentationDetents([.large])
    }

    private func tokenCard(label: String, token: TokenModel, amount: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundColor(.textTertiary)

            HStack(spacing: 12) {
                TokenIconView(symbol: token.symbol, chain: token.chain, size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(amount) \(token.symbol)")
                        .font(.title3.bold().monospacedDigit())
                        .foregroundColor(.textPrimary)

                    if let decimalAmount = Decimal(string: amount), decimalAmount > 0 {
                        let usdValue = decimalAmount * Decimal(token.priceUsd)
                        Text(String(format: "~$%.2f", NSDecimalNumber(decimal: usdValue).doubleValue))
                            .font(.caption)
                            .foregroundColor(.textTertiary)
                    }
                }

                Spacer()
            }
            .padding(14)
            .background(Color.backgroundCard)
            .cornerRadius(12)
        }
    }
}

// MARK: - Swap Token Section

private struct SwapTokenSection: View {
    let label: String
    let token: TokenModel?
    @Binding var amount: String
    let isEditable: Bool
    let showMaxButton: Bool
    let onTokenTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.bold())
                .foregroundColor(.textSecondary)

            VStack(spacing: 12) {
                // Token selector row
                Button(action: onTokenTap) {
                    HStack {
                        if let token {
                            TokenIconView(symbol: token.symbol, chain: token.chain, size: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(token.symbol)
                                    .font(.body.bold())
                                    .foregroundColor(.textPrimary)
                                Text(token.name)
                                    .font(.caption)
                                    .foregroundColor(.textTertiary)
                            }
                        } else {
                            Text("Select token")
                                .foregroundColor(.textTertiary)
                        }

                        Spacer()

                        if let token {
                            Text(token.formattedBalance)
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.textTertiary)
                        }

                        Image(systemName: "chevron.down")
                            .foregroundColor(.textTertiary)
                            .font(.caption)
                    }
                }

                // Amount row
                HStack {
                    if isEditable {
                        TextField("0.0", text: $amount)
                            .font(.title2.monospacedDigit())
                            .foregroundColor(.textPrimary)
                            .keyboardType(.decimalPad)
                    } else {
                        Text(amount.isEmpty ? "0.0" : amount)
                            .font(.title2.monospacedDigit())
                            .foregroundColor(amount.isEmpty ? .textTertiary : .textPrimary)
                    }

                    Spacer()

                    if isEditable, showMaxButton, let token {
                        Button("Max") {
                            amount = token.formattedBalance
                        }
                        .font(.caption.bold())
                        .foregroundColor(.accentGreen)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accentGreen.opacity(0.1))
                        .cornerRadius(8)
                    }
                }

                // USD value
                if let token, let decimalAmount = Decimal(string: amount), decimalAmount > 0 {
                    let usdValue = decimalAmount * Decimal(token.priceUsd)
                    HStack {
                        Text(String(format: "~$%.2f", NSDecimalNumber(decimal: usdValue).doubleValue))
                            .font(.caption)
                            .foregroundColor(.textTertiary)
                        Spacer()
                    }
                }
            }
            .padding(14)
            .background(Color.backgroundCard)
            .cornerRadius(12)
        }
    }
}

// MARK: - Quote Details

private struct QuoteDetailsView: View {
    let quote: SwapQuote
    let exchangeRate: String?
    let guaranteedPriceFormatted: String?

    var body: some View {
        VStack(spacing: 10) {
            if let exchangeRate {
                QuoteRow(label: "Rate", value: exchangeRate)
            }

            if let guaranteedPriceFormatted {
                QuoteRow(label: "Min. Received", value: guaranteedPriceFormatted)
            }

            if quote.priceImpact > 0 {
                QuoteRow(
                    label: "Price Impact",
                    value: String(format: "%.2f%%", quote.priceImpact),
                    valueColor: quote.priceImpact > 1.0 ? .error : .textSecondary
                )
            }

            if let sources = quote.sources, !sources.isEmpty {
                QuoteRow(
                    label: "Route",
                    value: sources.map { $0.name }.joined(separator: ", ")
                )
            } else if !quote.route.label.isEmpty {
                QuoteRow(label: "Route", value: quote.route.label)
            }
        }
        .padding(14)
        .background(Color.backgroundCard)
        .cornerRadius(12)
    }
}

private struct QuoteRow: View {
    let label: String
    let value: String
    var valueColor: Color = .textSecondary

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.textTertiary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundColor(valueColor)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Token Picker Sheet

private struct SwapTokenPickerSheet: View {
    let tokens: [TokenModel]
    @Binding var selectedToken: TokenModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(tokens) { token in
                Button {
                    selectedToken = token
                    dismiss()
                } label: {
                    HStack {
                        TokenIconView(symbol: token.symbol, chain: token.chain, size: 36)

                        VStack(alignment: .leading) {
                            Text(token.symbol)
                                .font(.body.bold())
                                .foregroundColor(.textPrimary)
                            Text(token.name)
                                .font(.caption)
                                .foregroundColor(.textSecondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing) {
                            Text(token.formattedBalance)
                                .font(.body.monospacedDigit())
                                .foregroundColor(.textPrimary)
                            Text(token.formattedBalanceUsd)
                                .font(.caption)
                                .foregroundColor(.textTertiary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Select Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SwapView()
        .environmentObject(WalletService.shared)
}
