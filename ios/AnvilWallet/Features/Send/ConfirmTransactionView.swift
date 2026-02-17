import SwiftUI

/// ConfirmTransactionView shows transaction details for user confirmation before signing.
///
/// Displays:
///   - Sender and recipient addresses
///   - Amount and token
///   - Estimated gas fee
///   - Total cost
///
/// On confirmation, triggers biometric auth -> signing -> broadcast.
struct ConfirmTransactionView: View {
    @EnvironmentObject var walletService: WalletService
    @EnvironmentObject var router: AppRouter

    let transaction: TransactionModel

    @State private var estimatedFee: Double = 0.002
    @State private var estimatedFeeUsd: Double = 7.00
    @State private var isSimulating = true
    @State private var simulationError: String?
    @State private var isSigning = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "paperplane.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.accentGreen)

                        Text("Confirm Transaction")
                            .font(.title3.bold())
                            .foregroundColor(.textPrimary)
                    }
                    .padding(.top, 16)

                    // Transaction details
                    VStack(spacing: 16) {
                        DetailRow(label: "From", value: transaction.shortFrom)
                        Divider().background(Color.separator)

                        DetailRow(label: "To", value: transaction.shortTo)
                        Divider().background(Color.separator)

                        DetailRow(
                            label: "Amount",
                            value: transaction.formattedAmount,
                            valueColor: .textPrimary
                        )
                        Divider().background(Color.separator)

                        DetailRow(label: "Network", value: transaction.chain.capitalized)
                        Divider().background(Color.separator)

                        if isSimulating {
                            HStack {
                                Text("Estimated Fee")
                                    .foregroundColor(.textSecondary)
                                Spacer()
                                ProgressView()
                                    .tint(.textSecondary)
                            }
                        } else if let error = simulationError {
                            DetailRow(label: "Fee Error", value: error, valueColor: .error)
                        } else {
                            DetailRow(
                                label: "Estimated Fee",
                                value: String(format: "%.6f (~$%.2f)", estimatedFee, estimatedFeeUsd)
                            )
                        }
                    }
                    .font(.body)
                    .padding()
                    .background(Color.backgroundCard)
                    .cornerRadius(16)
                    .padding(.horizontal, 20)

                    // Total
                    if !isSimulating && simulationError == nil {
                        HStack {
                            Text("Total")
                                .font(.headline)
                                .foregroundColor(.textSecondary)

                            Spacer()

                            VStack(alignment: .trailing) {
                                Text(String(format: "%.4f %@", transaction.amount + estimatedFee, transaction.tokenSymbol))
                                    .font(.headline.monospacedDigit())
                                    .foregroundColor(.textPrimary)

                                Text(String(format: "~$%.2f", (transaction.amount * 3500) + estimatedFeeUsd))
                                    .font(.caption)
                                    .foregroundColor(.textSecondary)
                            }
                        }
                        .padding()
                        .background(Color.backgroundCard)
                        .cornerRadius(16)
                        .padding(.horizontal, 20)
                    }

                    // Security note
                    HStack(spacing: 8) {
                        Image(systemName: "faceid")
                            .foregroundColor(.accentGreen)

                        Text("You'll need to authenticate with biometrics to sign this transaction.")
                            .font(.caption)
                            .foregroundColor(.textSecondary)
                    }
                    .padding(12)
                    .background(Color.backgroundCard)
                    .cornerRadius(12)
                    .padding(.horizontal, 20)
                }
            }

            // Bottom buttons
            VStack(spacing: 12) {
                Button {
                    Task {
                        await signAndSend()
                    }
                } label: {
                    Text("Confirm & Send")
                }
                .buttonStyle(PrimaryButtonStyle(isEnabled: !isSimulating && simulationError == nil))
                .disabled(isSimulating || simulationError != nil || isSigning)

                Button {
                    router.sendPath.removeLast()
                } label: {
                    Text("Cancel")
                        .font(.headline)
                        .foregroundColor(.textSecondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .padding(.top, 12)
            .background(Color.backgroundPrimary)
        }
        .background(Color.backgroundPrimary)
        .navigationTitle("Confirm")
        .navigationBarTitleDisplayMode(.inline)
        .loadingOverlay(isLoading: isSigning, message: "Signing transaction...")
        .task {
            await simulateTransaction()
        }
    }

    // MARK: - Logic

    private func simulateTransaction() async {
        isSimulating = true
        // TODO: Integrate TransactionSimulator
        // let simulator = TransactionSimulator()
        // let result = try await simulator.simulate(...)
        try? await Task.sleep(nanoseconds: 1_000_000_000) // Simulate delay
        isSimulating = false
    }

    private func signAndSend() async {
        isSigning = true

        do {
            // TODO: Integrate Rust FFI for transaction signing
            // 1. Build raw transaction
            // 2. walletService.signTransaction(chain:txData:)
            // 3. RPCService.shared.sendRawTransaction(...)

            try await Task.sleep(nanoseconds: 2_000_000_000) // Simulate signing

            let fakeTxHash = "0x" + UUID().uuidString.replacingOccurrences(of: "-", with: "")

            await MainActor.run {
                isSigning = false
                router.sendPath.append(
                    AppRouter.SendDestination.transactionResult(txHash: fakeTxHash, success: true)
                )
            }
        } catch {
            await MainActor.run {
                isSigning = false
                simulationError = error.localizedDescription
            }
        }
    }
}

// MARK: - Detail Row

private struct DetailRow: View {
    let label: String
    let value: String
    var valueColor: Color = .textPrimary

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.textSecondary)
            Spacer()
            Text(value)
                .foregroundColor(valueColor)
                .monospacedDigit()
        }
    }
}

#Preview {
    NavigationStack {
        ConfirmTransactionView(transaction: .preview)
            .environmentObject(WalletService.shared)
            .environmentObject(AppRouter())
    }
}
