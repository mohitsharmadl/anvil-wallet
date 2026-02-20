import SwiftUI

/// ActivityView shows a chronological list of all wallet transactions
/// fetched from blockchain indexers and merged with locally-sent transactions.
///
/// Features:
///   - Filter tabs: All / Sent / Received / Failed
///   - Chain filter: show transactions for a specific chain or all chains
///   - Pull-to-refresh with cache invalidation
///   - Loading indicator during initial fetch
///   - Timestamps on each transaction row
struct ActivityView: View {
    @EnvironmentObject var walletService: WalletService

    @State private var selectedFilter: TransactionFilter = .all
    @State private var selectedChain: String = "all"
    @State private var isLoading = false
    @State private var fetchError: String?

    enum TransactionFilter: String, CaseIterable {
        case all = "All"
        case sent = "Sent"
        case received = "Received"
        case failed = "Failed"
    }

    private var allTransactions: [TransactionModel] {
        (walletService.transactions + walletService.watchTransactions)
            .sorted { $0.timestamp > $1.timestamp }
    }

    private var allKnownAddresses: Set<String> {
        let walletAddresses = walletService.addresses.values.map { $0.lowercased() }
        let watchedAddresses = WatchAddressService.shared.watchAddresses.map { $0.address.lowercased() }
        return Set(walletAddresses + watchedAddresses)
    }

    /// Chains that have at least one transaction, for the chain filter picker.
    private var chainsWithTransactions: [ChainModel] {
        let chainIds = Set(allTransactions.map { $0.chain })
        return ChainModel.defaults.filter { chainIds.contains($0.id) }
    }

    private var filteredTransactions: [TransactionModel] {
        var txs = allTransactions

        // Chain filter
        if selectedChain != "all" {
            txs = txs.filter { $0.chain == selectedChain }
        }

        // Type filter
        switch selectedFilter {
        case .all:
            return txs
        case .sent:
            return txs.filter { tx in
                allKnownAddresses.contains(tx.from.lowercased())
            }
        case .received:
            return txs.filter { tx in
                allKnownAddresses.contains(tx.to.lowercased())
            }
        case .failed:
            return txs.filter { $0.status == .failed }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Chain filter (horizontal scroll)
                if !chainsWithTransactions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ChainFilterChip(
                                label: "All Chains",
                                isSelected: selectedChain == "all"
                            ) {
                                withAnimation { selectedChain = "all" }
                            }

                            ForEach(chainsWithTransactions) { chain in
                                ChainFilterChip(
                                    label: chain.name,
                                    isSelected: selectedChain == chain.id
                                ) {
                                    withAnimation { selectedChain = chain.id }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                    }
                }

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
                    .padding(.vertical, 8)
                }

                // Content
                if isLoading && allTransactions.isEmpty {
                    // Initial loading state (no cached data yet)
                    VStack(spacing: 16) {
                        Spacer()

                        ProgressView()
                            .scaleEffect(1.2)
                            .tint(.accentGreen)

                        Text("Loading transactions...")
                            .font(.body)
                            .foregroundColor(.textSecondary)

                        Spacer()
                    }
                } else if filteredTransactions.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()

                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 56))
                            .foregroundColor(.textTertiary)

                        Text("No Transactions Yet")
                            .font(.title3.bold())
                            .foregroundColor(.textPrimary)

                        if selectedChain != "all" || selectedFilter != .all {
                            Text("Try changing your filters to see more transactions.")
                                .font(.body)
                                .foregroundColor(.textSecondary)
                                .multilineTextAlignment(.center)
                        } else {
                            Text("Your transaction history will appear here.")
                                .font(.body)
                                .foregroundColor(.textSecondary)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 20)
                } else {
                    List(filteredTransactions) { transaction in
                        NavigationLink(destination: TransactionDetailView(transaction: transaction)) {
                            TransactionRowView(
                                transaction: transaction,
                                isSent: allKnownAddresses.contains(transaction.from.lowercased())
                            )
                        }
                        .listRowBackground(Color.backgroundPrimary)
                        .listRowSeparatorTint(Color.separator)
                    }
                    .listStyle(.plain)
                }

                // Error banner (non-blocking, shows at bottom)
                if let error = fetchError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.warning)

                        Text(error)
                            .font(.caption)
                            .foregroundColor(.textSecondary)
                            .lineLimit(1)

                        Spacer()

                        Button("Retry") {
                            Task { await loadTransactions(forceRefresh: true) }
                        }
                        .font(.caption.bold())
                        .foregroundColor(.accentGreen)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.backgroundCard)
                }
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if isLoading && !allTransactions.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        ProgressView()
                            .tint(.accentGreen)
                    }
                }
            }
            .task {
                await loadTransactions(forceRefresh: false)
            }
            .refreshable {
                await loadTransactions(forceRefresh: true)
            }
        }
    }

    private func loadTransactions(forceRefresh: Bool) async {
        isLoading = true
        fetchError = nil

        do {
            if forceRefresh {
                try await walletService.forceRefreshTransactions()
            } else {
                try await walletService.refreshTransactions()
            }
        } catch {
            // Show error but keep existing/cached data visible
            fetchError = "Could not refresh history"
        }

        isLoading = false
    }
}

// MARK: - Chain Filter Chip

private struct ChainFilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.bold())
                .foregroundColor(isSelected ? .white : .textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentGreen.opacity(0.8) : Color.backgroundCard)
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(isSelected ? Color.clear : Color.border, lineWidth: 1)
                )
        }
    }
}

// MARK: - Transaction Row

private struct TransactionRowView: View {
    let transaction: TransactionModel
    let isSent: Bool

    /// Relative timestamp formatter (e.g. "2h ago", "Yesterday").
    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: transaction.timestamp, relativeTo: Date())
    }

    /// Chain display name for multi-chain context.
    private var chainName: String {
        ChainModel.defaults.first(where: { $0.id == transaction.chain })?.name ?? transaction.chain.capitalized
    }

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

                HStack(spacing: 4) {
                    Text(isSent ? transaction.shortTo : transaction.shortFrom)
                        .font(.caption.monospaced())
                        .foregroundColor(.textTertiary)

                    Text("on \(chainName)")
                        .font(.caption2)
                        .foregroundColor(.textTertiary)
                }
            }

            Spacer()

            // Amount, status, and time
            VStack(alignment: .trailing, spacing: 4) {
                Text((isSent ? "-" : "+") + transaction.formattedAmount)
                    .font(.body.monospacedDigit())
                    .foregroundColor(isSent ? .error : .success)

                HStack(spacing: 4) {
                    Text(transaction.status.displayName)
                        .font(.caption)
                        .foregroundColor(statusColor(transaction.status))

                    Text(relativeTime)
                        .font(.caption2)
                        .foregroundColor(.textTertiary)
                }
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
