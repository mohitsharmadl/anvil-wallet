import SwiftUI

/// TransactionResultView shows the outcome of a submitted transaction.
///
/// Displays success or failure state with the transaction hash and
/// a link to view on the block explorer. On success, offers to save
/// the recipient address to the address book if not already saved.
struct TransactionResultView: View {
    @EnvironmentObject var router: AppRouter

    let txHash: String
    let success: Bool
    let chain: String
    let recipientAddress: String

    @State private var showSaveContactSheet = false
    @State private var didSaveContact = false
    @State private var txStatus: TxStatus = .submitted
    @State private var statusMessage: String?
    @State private var isCheckingStatus = false

    enum TxStatus: String {
        case submitted
        case pending
        case confirmed
        case unknown
    }

    /// Whether the recipient is already in the address book.
    private var isAlreadySaved: Bool {
        AddressBookService.shared.isSaved(address: recipientAddress, chain: chain)
    }

    /// Resolves the block explorer URL for this transaction's chain.
    private var explorerUrl: URL? {
        ChainModel.allChains
            .first { $0.id == chain }?
            .explorerTransactionUrl(hash: txHash)
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Status icon
            if success {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.success)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.error)
                    .accessibilityHidden(true)
            }

            // Status text
            VStack(spacing: 8) {
                Text(success ? "Transaction Sent" : "Transaction Failed")
                    .font(.title2.bold())
                    .foregroundColor(.textPrimary)

                Text(success
                    ? "Your transaction has been submitted to the network."
                    : "Something went wrong. Please try again.")
                    .font(.body)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)

            if success {
                statusTimeline
                    .padding(.horizontal, 24)
            }

            // Transaction hash
            if success {
                VStack(spacing: 8) {
                    Text("Transaction Hash")
                        .font(.caption)
                        .foregroundColor(.textTertiary)

                    let shortHash = txHash.count > 12
                        ? "\(txHash.prefix(10))...\(txHash.suffix(8))"
                        : txHash

                    Text(shortHash)
                        .font(.body.monospaced())
                        .foregroundColor(.textPrimary)

                    Button {
                        SecurityService.shared.copyWithAutoClear(txHash, sensitive: false)
                        Haptic.impact(.light)
                    } label: {
                        Label("Copy Hash", systemImage: "doc.on.doc")
                            .font(.caption.bold())
                            .foregroundColor(.accentGreen)
                    }
                    .frame(minHeight: 44)
                    .accessibilityLabel("Copy transaction hash")
                    .accessibilityHint("Double tap to copy hash to clipboard")
                }
                .padding()
                .background(Color.backgroundCard)
                .cornerRadius(16)
                .padding(.horizontal, 24)

                // View on explorer
                if let explorerUrl {
                    Button {
                        UIApplication.shared.open(explorerUrl)
                    } label: {
                        Label("View on Explorer", systemImage: "arrow.up.right.square")
                            .font(.subheadline.bold())
                            .foregroundColor(.accentGreen)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentGreen.opacity(0.1))
                            .cornerRadius(12)
                    }
                    .padding(.horizontal, 24)
                }

                // Save to address book (only if not already saved)
                if !isAlreadySaved && !didSaveContact {
                    Button {
                        showSaveContactSheet = true
                    } label: {
                        Label("Save Address to Contacts", systemImage: "person.crop.rectangle.stack.fill")
                            .font(.subheadline.bold())
                            .foregroundColor(.accentGreen)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentGreen.opacity(0.1))
                            .cornerRadius(12)
                    }
                    .padding(.horizontal, 24)
                }

                if didSaveContact {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.success)
                        Text("Address saved to contacts")
                            .font(.caption)
                            .foregroundColor(.success)
                    }
                }
            }

            Spacer()

            // Action buttons
            VStack(spacing: 12) {
                Button {
                    // Reset send flow and go back to wallet
                    router.sendPath = NavigationPath()
                    router.navigateToTab(.wallet)
                } label: {
                    Text("Back to Wallet")
                }
                .buttonStyle(.primary)

                if !success {
                    Button {
                        router.sendPath = NavigationPath()
                    } label: {
                        Text("Try Again")
                    }
                    .buttonStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(Color.backgroundPrimary)
        .navigationBarBackButtonHidden()
        .onAppear {
            if success {
                Haptic.success()
                Task { await trackTransactionStatus() }
            } else {
                Haptic.error()
            }
        }
        .sheet(isPresented: $showSaveContactSheet) {
            AddAddressSheet(
                prefillAddress: recipientAddress,
                prefillChain: chain
            )
            .onDisappear {
                // Check if it was saved after the sheet closes
                if AddressBookService.shared.isSaved(address: recipientAddress, chain: chain) {
                    didSaveContact = true
                }
            }
        }
    }

    private var statusTimeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Network Status")
                .font(.subheadline.bold())
                .foregroundColor(.textPrimary)

            HStack(spacing: 10) {
                statusDot(active: true, done: true)
                Text("Submitted")
                    .font(.caption)
                    .foregroundColor(.textSecondary)
                Spacer()
            }

            HStack(spacing: 10) {
                statusDot(active: txStatus == .pending || txStatus == .confirmed, done: txStatus == .confirmed)
                Text(txStatus == .confirmed ? "Confirmed" : "Pending confirmations")
                    .font(.caption)
                    .foregroundColor(.textSecondary)
                Spacer()
                if isCheckingStatus && txStatus != .confirmed {
                    ProgressView()
                        .scaleEffect(0.75)
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption2)
                    .foregroundColor(.textTertiary)
            }
        }
        .padding()
        .background(Color.backgroundCard)
        .cornerRadius(14)
    }

    private func statusDot(active: Bool, done: Bool) -> some View {
        Circle()
            .fill(done ? Color.success : (active ? Color.warning : Color.textTertiary.opacity(0.4)))
            .frame(width: 10, height: 10)
    }

    private func trackTransactionStatus() async {
        guard let chainModel = ChainModel.allChains.first(where: { $0.id == chain }) else { return }
        await MainActor.run {
            txStatus = .pending
            isCheckingStatus = true
            statusMessage = "Waiting for network confirmation..."
        }

        for attempt in 0..<12 {
            do {
                let confirmed: Bool
                switch chainModel.chainType {
                case .evm:
                    confirmed = try await RPCService.shared.isEvmTransactionConfirmed(
                        rpcUrl: chainModel.activeRpcUrl,
                        txHash: txHash
                    )
                case .solana:
                    confirmed = try await RPCService.shared.isSolanaTransactionConfirmed(
                        rpcUrl: chainModel.activeRpcUrl,
                        signature: txHash
                    )
                case .bitcoin:
                    confirmed = try await RPCService.shared.isBitcoinTransactionConfirmed(
                        apiUrl: chainModel.activeRpcUrl,
                        txid: txHash
                    )
                case .zcash:
                    confirmed = try await RPCService.shared.isZcashTransactionConfirmed(txHash: txHash)
                }

                if confirmed {
                    await MainActor.run {
                        txStatus = .confirmed
                        isCheckingStatus = false
                        statusMessage = "Confirmed on-chain."
                    }
                    return
                }
            } catch {
                await MainActor.run {
                    statusMessage = "Temporary status lookup issue. Retrying..."
                }
            }

            await MainActor.run {
                statusMessage = "Still pending... (\(attempt + 1)/12)"
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }

        await MainActor.run {
            txStatus = .unknown
            isCheckingStatus = false
            statusMessage = "Status check timed out. You can verify on explorer."
        }
    }
}

#Preview {
    TransactionResultView(
        txHash: "0xabc123def456789012345678901234567890abcdef123456",
        success: true,
        chain: "ethereum",
        recipientAddress: "0xabcdef1234567890abcdef1234567890abcdef12"
    )
    .environmentObject(AppRouter())
}
