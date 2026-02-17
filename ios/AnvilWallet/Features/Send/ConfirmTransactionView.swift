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

    @State private var estimatedFee: Double = 0
    @State private var estimatedFeeUsd: Double = 0
    @State private var isSimulating = true
    @State private var simulationError: String?
    @State private var isSigning = false

    // Fetched gas params for EVM signing
    @State private var fetchedNonce: UInt64 = 0
    @State private var fetchedGasLimit: UInt64 = 21000
    @State private var fetchedMaxFeeHex: String = "0x0"
    @State private var fetchedMaxPriorityFeeHex: String = "0x0"

    /// Maps chain model IDs to EIP-155 chain IDs
    private func evmChainId(for chainId: String) -> UInt64 {
        switch chainId {
        case "ethereum": return 1
        case "polygon": return 137
        case "arbitrum": return 42161
        case "base": return 8453
        case "sepolia": return 11155111
        default: return 1
        }
    }

    /// Finds the ChainModel for the transaction's chain string
    private var chainModel: ChainModel? {
        ChainModel.allChains.first { $0.id == transaction.chain }
    }

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

        guard let chain = chainModel else {
            simulationError = "Unknown chain"
            isSimulating = false
            return
        }

        do {
            switch chain.chainType {
            case .evm:
                // Fetch nonce, gas price, and estimate gas
                let nonceHex: String = try await RPCService.shared.getTransactionCount(
                    rpcUrl: chain.rpcUrl,
                    address: transaction.from
                )
                fetchedNonce = UInt64(nonceHex.dropFirst(2), radix: 16) ?? 0

                let gasPriceHex: String = try await RPCService.shared.gasPrice(rpcUrl: chain.rpcUrl)
                fetchedMaxFeeHex = gasPriceHex
                // Use 1.5 gwei priority fee as default
                fetchedMaxPriorityFeeHex = "0x59682f00"

                let gasEstimateHex: String = try await RPCService.shared.estimateGas(
                    rpcUrl: chain.rpcUrl,
                    from: transaction.from,
                    to: transaction.to,
                    value: "0x" + String(UInt64(transaction.amount * 1e18), radix: 16),
                    data: nil
                )
                fetchedGasLimit = UInt64(gasEstimateHex.dropFirst(2), radix: 16) ?? 21000

                // Calculate fee in native token
                let gasPrice = Double(UInt64(gasPriceHex.dropFirst(2), radix: 16) ?? 0)
                estimatedFee = (gasPrice * Double(fetchedGasLimit)) / 1e18

            case .solana:
                // Solana fees are fixed (~5000 lamports)
                estimatedFee = 0.000005

            case .bitcoin:
                // BTC signing not yet supported
                simulationError = "Bitcoin signing is not yet supported"
                isSimulating = false
                return
            }

            isSimulating = false
        } catch {
            simulationError = error.localizedDescription
            isSimulating = false
        }
    }

    private func signAndSend() async {
        isSigning = true

        guard let chain = chainModel else {
            simulationError = "Unknown chain"
            isSigning = false
            return
        }

        do {
            let signedTx: Data
            let txHash: String

            switch chain.chainType {
            case .evm:
                let chainId = evmChainId(for: chain.id)
                let valueWei = UInt64(transaction.amount * 1e18)
                let valueHex = "0x" + String(valueWei, radix: 16)

                let ethReq = EthTransactionRequest(
                    chainId: chainId,
                    nonce: fetchedNonce,
                    to: transaction.to,
                    valueWeiHex: valueHex,
                    data: Data(),
                    maxPriorityFeeHex: fetchedMaxPriorityFeeHex,
                    maxFeeHex: fetchedMaxFeeHex,
                    gasLimit: fetchedGasLimit
                )

                signedTx = try await walletService.signTransaction(request: .eth(ethReq))
                let signedHex = "0x" + signedTx.map { String(format: "%02x", $0) }.joined()
                txHash = try await RPCService.shared.sendRawTransaction(
                    rpcUrl: chain.rpcUrl,
                    signedTx: signedHex
                )

            case .solana:
                let lamports = UInt64(transaction.amount * 1e9)
                let blockhash = try await RPCService.shared.getRecentBlockhash(rpcUrl: chain.rpcUrl)

                let solReq = SolTransactionRequest(
                    to: transaction.to,
                    lamports: lamports,
                    recentBlockhash: blockhash
                )

                signedTx = try await walletService.signTransaction(request: .sol(solReq))
                txHash = try await RPCService.shared.sendSolanaTransaction(
                    rpcUrl: chain.rpcUrl,
                    signedTx: signedTx.base64EncodedString()
                )

            case .bitcoin:
                throw WalletError.signingFailed
            }

            await MainActor.run {
                isSigning = false
                router.sendPath.append(
                    AppRouter.SendDestination.transactionResult(txHash: txHash, success: true)
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
