import SwiftUI

/// ActivityView shows a chronological list of all wallet transactions.
struct ActivityView: View {
    @EnvironmentObject var walletService: WalletService

    @State private var selectedFilter: TransactionFilter = .all
    @State private var isLoading = false

    enum TransactionFilter: String, CaseIterable {
        case all = "All"
        case sent = "Sent"
        case received = "Received"
        case failed = "Failed"
    }

    private var filteredTransactions: [TransactionModel] {
        switch selectedFilter {
        case .all:
            return walletService.transactions
        case .sent:
            return walletService.transactions.filter { tx in
                walletService.addresses.values.contains(tx.from)
            }
        case .received:
            return walletService.transactions.filter { tx in
                walletService.addresses.values.contains(tx.to)
            }
        case .failed:
            return walletService.transactions.filter { $0.status == .failed }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filter tabs
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(TransactionFilter.allCases, id: \.self) { filter in
                            Button {
                                withAnimation { selectedFilter = filter }
                            } label: {
                                Text(filter.rawValue)
                                    .font(.subheadline.bold())
                                    .foregroundColor(selectedFilter == filter ? .white : .textSecondary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(
                                        selectedFilter == filter
                                            ? Color.accentGreen
                                            : Color.backgroundCard
                                    )
                                    .cornerRadius(20)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }

                // Transaction list
                if filteredTransactions.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()

                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 56))
                            .foregroundColor(.textTertiary)

                        Text("No Transactions Yet")
                            .font(.title3.bold())
                            .foregroundColor(.textPrimary)

                        Text("Your transaction history will appear here.")
                            .font(.body)
                            .foregroundColor(.textSecondary)

                        Spacer()
                    }
                } else {
                    List(filteredTransactions) { transaction in
                        NavigationLink(destination: TransactionDetailView(transaction: transaction)) {
                            TransactionRowView(
                                transaction: transaction,
                                isSent: walletService.addresses.values.contains(transaction.from)
                            )
                        }
                        .listRowBackground(Color.backgroundPrimary)
                        .listRowSeparatorTint(Color.separator)
                    }
                    .listStyle(.plain)
                }
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.large)
            .refreshable {
                // TODO: Fetch transaction history from chain
                isLoading = true
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                isLoading = false
            }
        }
    }
}

// MARK: - Transaction Row

private struct TransactionRowView: View {
    let transaction: TransactionModel
    let isSent: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Direction icon
            Image(systemName: isSent ? "arrow.up.right" : "arrow.down.left")
                .font(.body.bold())
                .foregroundColor(isSent ? .error : .success)
                .frame(width: 40, height: 40)
                .background(
                    (isSent ? Color.error : Color.success).opacity(0.1)
                )
                .cornerRadius(12)

            // Transaction info
            VStack(alignment: .leading, spacing: 4) {
                Text(isSent ? "Sent" : "Received")
                    .font(.body.bold())
                    .foregroundColor(.textPrimary)

                Text(isSent ? transaction.shortTo : transaction.shortFrom)
                    .font(.caption.monospaced())
                    .foregroundColor(.textTertiary)
            }

            Spacer()

            // Amount and status
            VStack(alignment: .trailing, spacing: 4) {
                Text((isSent ? "-" : "+") + transaction.formattedAmount)
                    .font(.body.monospacedDigit())
                    .foregroundColor(isSent ? .error : .success)

                Text(transaction.status.displayName)
                    .font(.caption)
                    .foregroundColor(statusColor(transaction.status))
            }
        }
        .padding(.vertical, 4)
    }

    private func statusColor(_ status: TransactionModel.TransactionStatus) -> Color {
        switch status {
        case .pending: return .warning
        case .confirmed: return .success
        case .failed: return .error
        }
    }
}

#Preview {
    ActivityView()
        .environmentObject(WalletService.shared)
}
