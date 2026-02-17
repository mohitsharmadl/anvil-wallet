import SwiftUI

/// SendView allows users to compose a token transfer transaction.
///
/// Flow: SendView -> ConfirmTransactionView -> TransactionResultView
struct SendView: View {
    @EnvironmentObject var walletService: WalletService
    @EnvironmentObject var router: AppRouter

    @State private var recipientAddress = ""
    @State private var amount = ""
    @State private var selectedToken: TokenModel?
    @State private var showTokenPicker = false
    @State private var showQRScanner = false
    @State private var errorMessage: String?

    private var isValidInput: Bool {
        !recipientAddress.isEmpty && !amount.isEmpty && selectedToken != nil
    }

    var body: some View {
        NavigationStack(path: $router.sendPath) {
            ScrollView {
                VStack(spacing: 20) {
                    // Token selector
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Token")
                            .font(.subheadline.bold())
                            .foregroundColor(.textSecondary)

                        Button {
                            showTokenPicker = true
                        } label: {
                            HStack {
                                if let token = selectedToken {
                                    Circle()
                                        .fill(Color.accentGreen.opacity(0.2))
                                        .frame(width: 32, height: 32)
                                        .overlay(
                                            Text(String(token.symbol.prefix(1)))
                                                .font(.caption.bold())
                                                .foregroundColor(.accentGreen)
                                        )

                                    Text(token.symbol)
                                        .foregroundColor(.textPrimary)

                                    Spacer()

                                    Text(token.formattedBalance)
                                        .foregroundColor(.textSecondary)
                                        .monospacedDigit()
                                } else {
                                    Text("Select token")
                                        .foregroundColor(.textTertiary)
                                    Spacer()
                                }

                                Image(systemName: "chevron.down")
                                    .foregroundColor(.textTertiary)
                            }
                            .font(.body)
                            .padding(14)
                            .background(Color.backgroundCard)
                            .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal, 20)

                    // Recipient address
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recipient")
                            .font(.subheadline.bold())
                            .foregroundColor(.textSecondary)

                        HStack {
                            TextField("Address or ENS name", text: $recipientAddress)
                                .font(.body)
                                .foregroundColor(.textPrimary)
                                .autocapitalization(.none)
                                .autocorrectionDisabled()

                            Button {
                                showQRScanner = true
                            } label: {
                                Image(systemName: "qrcode.viewfinder")
                                    .foregroundColor(.accentGreen)
                            }

                            Button {
                                if let clipboard = UIPasteboard.general.string {
                                    recipientAddress = clipboard
                                }
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                                    .foregroundColor(.accentGreen)
                            }
                        }
                        .padding(14)
                        .background(Color.backgroundCard)
                        .cornerRadius(12)
                    }
                    .padding(.horizontal, 20)

                    // Amount
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Amount")
                            .font(.subheadline.bold())
                            .foregroundColor(.textSecondary)

                        HStack {
                            TextField("0.0", text: $amount)
                                .font(.title2.monospacedDigit())
                                .foregroundColor(.textPrimary)
                                .keyboardType(.decimalPad)

                            if let token = selectedToken {
                                Text(token.symbol)
                                    .foregroundColor(.textSecondary)

                                Button("Max") {
                                    amount = String(token.balance)
                                }
                                .font(.caption.bold())
                                .foregroundColor(.accentGreen)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentGreen.opacity(0.1))
                                .cornerRadius(8)
                            }
                        }
                        .padding(14)
                        .background(Color.backgroundCard)
                        .cornerRadius(12)

                        if let token = selectedToken {
                            let amountDouble = Double(amount) ?? 0
                            Text(String(format: "~$%.2f", amountDouble * token.priceUsd))
                                .font(.caption)
                                .foregroundColor(.textTertiary)
                        }
                    }
                    .padding(.horizontal, 20)

                    // Error
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.error)
                            .padding(.horizontal, 20)
                    }

                    Spacer(minLength: 40)

                    // Review button
                    Button {
                        guard let token = selectedToken,
                              let amountValue = Double(amount),
                              !recipientAddress.isEmpty else {
                            errorMessage = "Please fill in all fields."
                            return
                        }

                        let tx = TransactionModel(
                            hash: "",
                            chain: token.chain,
                            from: walletService.addresses[token.chain] ?? "",
                            to: recipientAddress,
                            amount: amountValue,
                            tokenSymbol: token.symbol,
                            tokenDecimals: token.decimals,
                            contractAddress: token.contractAddress
                        )
                        router.sendPath.append(
                            AppRouter.SendDestination.confirmTransaction(transaction: tx)
                        )
                    } label: {
                        Text("Review Transaction")
                    }
                    .buttonStyle(PrimaryButtonStyle(isEnabled: isValidInput))
                    .disabled(!isValidInput)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
                .padding(.top, 16)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.large)
            .hideKeyboard()
            .sheet(isPresented: $showTokenPicker) {
                TokenPickerSheet(
                    tokens: walletService.tokens,
                    selectedToken: $selectedToken
                )
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView { scannedAddress in
                    recipientAddress = scannedAddress
                    showQRScanner = false
                }
            }
            .navigationDestination(for: AppRouter.SendDestination.self) { destination in
                switch destination {
                case .confirmTransaction(let tx):
                    ConfirmTransactionView(transaction: tx)
                case .transactionResult(let hash, let success):
                    TransactionResultView(txHash: hash, success: success)
                case .qrScanner:
                    QRScannerView { address in
                        recipientAddress = address
                    }
                }
            }
            .onAppear {
                if selectedToken == nil {
                    selectedToken = walletService.tokens.first
                }
            }
        }
    }
}

// MARK: - Token Picker Sheet

private struct TokenPickerSheet: View {
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

                        Text(token.formattedBalance)
                            .font(.body.monospacedDigit())
                            .foregroundColor(.textPrimary)
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
    SendView()
        .environmentObject(WalletService.shared)
        .environmentObject(AppRouter())
}
