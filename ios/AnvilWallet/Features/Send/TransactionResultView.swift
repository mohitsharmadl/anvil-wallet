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
