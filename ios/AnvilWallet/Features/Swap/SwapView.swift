import SwiftUI

/// SwapView allows users to swap tokens via Jupiter (Solana) or 0x (EVM).
struct SwapView: View {
    @EnvironmentObject var walletService: WalletService
    @StateObject private var viewModel = SwapViewModel()

    @Environment(\.dismiss) private var dismiss

    @State private var showFromTokenPicker = false
    @State private var showToTokenPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // From token
                    SwapTokenSection(
                        label: "From",
                        token: viewModel.fromToken,
                        amount: $viewModel.amount,
                        isEditable: true,
                        onTokenTap: { showFromTokenPicker = true }
                    )
                    .padding(.horizontal, 20)

                    // Swap direction button
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

                    // To token
                    SwapTokenSection(
                        label: "To",
                        token: viewModel.toToken,
                        amount: .constant(viewModel.formattedOutputAmount ?? ""),
                        isEditable: false,
                        onTokenTap: { showToTokenPicker = true }
                    )
                    .padding(.horizontal, 20)

                    // Quote details
                    if let quote = viewModel.quote {
                        QuoteDetailsView(
                            quote: quote,
                            exchangeRate: viewModel.exchangeRateDisplay
                        )
                        .padding(.horizontal, 20)
                    }

                    // Error
                    if let error = viewModel.error {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.error)
                            .padding(.horizontal, 20)
                    }

                    // Success
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

                    Spacer(minLength: 40)

                    // Action buttons
                    if viewModel.quote != nil && viewModel.txHash == nil {
                        Button {
                            Task { await viewModel.executeSwap() }
                        } label: {
                            Text("Confirm Swap")
                        }
                        .buttonStyle(PrimaryButtonStyle(isEnabled: !viewModel.isExecutingSwap))
                        .disabled(viewModel.isExecutingSwap)
                        .padding(.horizontal, 20)
                    } else if viewModel.txHash == nil {
                        Button {
                            Task { await viewModel.fetchQuote() }
                        } label: {
                            Text("Get Quote")
                        }
                        .buttonStyle(PrimaryButtonStyle(isEnabled: viewModel.canGetQuote && !viewModel.isLoadingQuote))
                        .disabled(!viewModel.canGetQuote || viewModel.isLoadingQuote)
                        .padding(.horizontal, 20)
                    }

                    // Done button after successful swap
                    if viewModel.txHash != nil {
                        Button {
                            dismiss()
                        } label: {
                            Text("Done")
                        }
                        .buttonStyle(PrimaryButtonStyle(isEnabled: true))
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
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
                isLoading: viewModel.isLoading,
                message: viewModel.isExecutingSwap ? "Swapping..." : "Fetching quote..."
            )
            .sheet(isPresented: $showFromTokenPicker) {
                SwapTokenPickerSheet(
                    tokens: walletService.tokens,
                    selectedToken: $viewModel.fromToken
                )
            }
            .sheet(isPresented: $showToTokenPicker) {
                SwapTokenPickerSheet(
                    tokens: swappableTokens(excluding: viewModel.fromToken),
                    selectedToken: $viewModel.toToken
                )
            }
            .onAppear {
                if viewModel.fromToken == nil {
                    viewModel.fromToken = walletService.tokens.first
                }
            }
            .onChange(of: viewModel.fromToken) { _ in
                viewModel.quote = nil
            }
            .onChange(of: viewModel.toToken) { _ in
                viewModel.quote = nil
            }
        }
    }

    /// Filters tokens to only those on the same chain as the selected from token.
    private func swappableTokens(excluding token: TokenModel?) -> [TokenModel] {
        let chainFilter = token?.chain
        return walletService.tokens.filter { t in
            if let chainFilter { return t.chain == chainFilter }
            return true
        }
    }
}

// MARK: - Swap Token Section

private struct SwapTokenSection: View {
    let label: String
    let token: TokenModel?
    @Binding var amount: String
    let isEditable: Bool
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
                            Circle()
                                .fill(Color.accentGreen.opacity(0.2))
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Text(String(token.symbol.prefix(1)))
                                        .font(.caption.bold())
                                        .foregroundColor(.accentGreen)
                                )

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

                    if isEditable, let token {
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

    var body: some View {
        VStack(spacing: 10) {
            if let exchangeRate {
                QuoteRow(label: "Rate", value: exchangeRate)
            }

            QuoteRow(
                label: "Price Impact",
                value: String(format: "%.2f%%", quote.priceImpact),
                valueColor: quote.priceImpact > 1.0 ? .error : .textSecondary
            )

            QuoteRow(label: "Network Fee", value: "\(quote.estimatedGas) gas")

            QuoteRow(label: "Anvil Fee", value: String(format: "%.1f%%", quote.fee))

            QuoteRow(
                label: "Route",
                value: quote.route.label.isEmpty ? "Direct" : quote.route.label
            )
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
                        Circle()
                            .fill(Color.accentGreen.opacity(0.2))
                            .frame(width: 36, height: 36)
                            .overlay(
                                Text(String(token.symbol.prefix(1)))
                                    .font(.caption.bold())
                                    .foregroundColor(.accentGreen)
                            )

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
