import SwiftUI

/// TransactionDetailView shows full details of a single transaction.
struct TransactionDetailView: View {
    let transaction: TransactionModel

    /// The native fee symbol for this transaction's chain (ETH, BTC, SOL, MATIC, etc.)
    private var feeSymbol: String {
        ChainModel.allChains.first(where: { $0.id == transaction.chain })?.symbol ?? transaction.tokenSymbol
    }

    /// Human-readable chain name for display.
    private var chainDisplayName: String {
        ChainModel.allChains.first(where: { $0.id == transaction.chain })?.name ?? transaction.chain.capitalized
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Status header
                VStack(spacing: 12) {
                    statusIcon
                        .font(.system(size: 56))

                    Text(transaction.status.displayName)
                        .font(.title2.bold())
                        .foregroundColor(.textPrimary)

                    Text(transaction.formattedAmount)
                        .font(.title3.monospacedDigit())
                        .foregroundColor(.textPrimary)
                }
                .padding(.top, 24)

                // Details card
                VStack(spacing: 16) {
                    TransactionDetailRow(label: "Transaction Hash", value: transaction.shortHash, fullValue: transaction.hash)

                    Divider().background(Color.separator)

                    TransactionDetailRow(label: "From", value: transaction.shortFrom, fullValue: transaction.from)

                    Divider().background(Color.separator)

                    TransactionDetailRow(label: "To", value: transaction.shortTo, fullValue: transaction.to)

                    Divider().background(Color.separator)

                    TransactionDetailRow(label: "Network", value: chainDisplayName)

                    Divider().background(Color.separator)

                    TransactionDetailRow(label: "Fee", value: transaction.formattedFee + " " + feeSymbol)

                    Divider().background(Color.separator)

                    TransactionDetailRow(
                        label: "Date",
                        value: transaction.timestamp.formatted(
                            .dateTime.month().day().year().hour().minute()
                        )
                    )
                }
                .padding()
                .background(Color.backgroundCard)
                .cornerRadius(16)
                .padding(.horizontal, 20)

                // View on explorer button
                Button {
                    let chain = ChainModel.allChains.first { $0.id == transaction.chain }
                    if let url = chain?.explorerTransactionUrl(hash: transaction.hash) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("View on Block Explorer", systemImage: "arrow.up.right.square")
                        .font(.headline)
                        .foregroundColor(.accentGreen)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.accentGreen.opacity(0.1))
                        .cornerRadius(12)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .background(Color.backgroundPrimary)
        .navigationTitle("Transaction Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch transaction.status {
        case .confirmed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.success)
        case .pending:
            Image(systemName: "clock.fill")
                .foregroundColor(.warning)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.error)
        }
    }
}

// MARK: - Transaction Detail Row

private struct TransactionDetailRow: View {
    let label: String
    let value: String
    var fullValue: String?

    var body: some View {
        HStack {
            Text(label)
                .font(.body)
                .foregroundColor(.textSecondary)

            Spacer()

            HStack(spacing: 8) {
                Text(value)
                    .font(.body.monospaced())
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)

                if let fullValue {
                    Button {
                        SecurityService.shared.copyWithAutoClear(fullValue, sensitive: false)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundColor(.accentGreen)
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        TransactionDetailView(transaction: .preview)
    }
}
