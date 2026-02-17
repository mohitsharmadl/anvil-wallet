import SwiftUI

/// TransactionResultView shows the outcome of a submitted transaction.
///
/// Displays success or failure state with the transaction hash and
/// a link to view on the block explorer.
struct TransactionResultView: View {
    @EnvironmentObject var router: AppRouter

    let txHash: String
    let success: Bool

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Status icon
            if success {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.success)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.error)
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
                        ClipboardManager.shared.copyToClipboard(txHash, sensitive: false)
                    } label: {
                        Label("Copy Hash", systemImage: "doc.on.doc")
                            .font(.caption.bold())
                            .foregroundColor(.accentGreen)
                    }
                }
                .padding()
                .background(Color.backgroundCard)
                .cornerRadius(16)
                .padding(.horizontal, 24)

                // View on explorer
                Button {
                    // TODO: Open block explorer URL
                    // if let url = ChainModel.ethereum.explorerTransactionUrl(hash: txHash) {
                    //     UIApplication.shared.open(url)
                    // }
                } label: {
                    Label("View on Explorer", systemImage: "arrow.up.right.square")
                        .font(.subheadline)
                        .foregroundColor(.accentGreen)
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
    }
}

#Preview {
    TransactionResultView(
        txHash: "0xabc123def456789012345678901234567890abcdef123456",
        success: true
    )
    .environmentObject(AppRouter())
}
