import SwiftUI

/// SessionApproveView presents a WalletConnect session proposal for user approval.
///
/// Shows:
///   - DApp name and URL
///   - Requested chains and permissions
///   - Approve/Reject buttons
struct SessionApproveView: View {
    @StateObject private var walletConnect = WalletConnectService.shared
    @EnvironmentObject var walletService: WalletService
    @Environment(\.dismiss) private var dismiss

    let proposal: WalletConnectService.WCSessionProposal

    @State private var isProcessing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // DApp info
                VStack(spacing: 12) {
                    Circle()
                        .fill(Color.backgroundElevated)
                        .frame(width: 64, height: 64)
                        .overlay(
                            Image(systemName: "globe")
                                .font(.title)
                                .foregroundColor(.textSecondary)
                        )

                    Text(proposal.peerName)
                        .font(.title3.bold())
                        .foregroundColor(.textPrimary)

                    Text(proposal.peerUrl)
                        .font(.body)
                        .foregroundColor(.accentGreen)
                }
                .padding(.top, 24)

                // Permissions
                VStack(alignment: .leading, spacing: 16) {
                    Text("Permissions Requested")
                        .font(.headline)
                        .foregroundColor(.textPrimary)

                    // Chains
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Chains")
                            .font(.subheadline.bold())
                            .foregroundColor(.textSecondary)

                        ForEach(proposal.requiredChains, id: \.self) { chain in
                            HStack {
                                Image(systemName: "link")
                                    .foregroundColor(.accentGreen)
                                Text(Self.friendlyChainName(chain))
                                    .foregroundColor(.textPrimary)
                            }
                        }
                    }

                    // Methods
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Methods")
                            .font(.subheadline.bold())
                            .foregroundColor(.textSecondary)

                        ForEach(proposal.methods, id: \.self) { method in
                            HStack {
                                Image(systemName: "function")
                                    .foregroundColor(.info)
                                Text(method)
                                    .font(.body.monospaced())
                                    .foregroundColor(.textPrimary)
                            }
                        }
                    }
                }
                .padding()
                .background(Color.backgroundCard)
                .cornerRadius(16)
                .padding(.horizontal, 20)

                // Warning
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.warning)

                    Text("Only connect to dApps you trust. The connected dApp will be able to request transaction signatures.")
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                }
                .padding(12)
                .background(Color.warning.opacity(0.1))
                .cornerRadius(12)
                .padding(.horizontal, 20)

                Spacer()

                // Buttons
                VStack(spacing: 12) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.error)
                    }

                    Button {
                        Task {
                            isProcessing = true
                            errorMessage = nil
                            do {
                                guard let ethAddress = walletService.addresses["ethereum"],
                                      !ethAddress.isEmpty else {
                                    errorMessage = "No Ethereum address available. Please create or import a wallet first."
                                    isProcessing = false
                                    return
                                }
                                let solAddress = walletService.addresses["solana"]
                                try await walletConnect.approveSession(
                                    proposal,
                                    ethAddress: ethAddress,
                                    solAddress: solAddress
                                )
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                            isProcessing = false
                        }
                    } label: {
                        Text("Approve")
                    }
                    .buttonStyle(.primary)
                    .disabled(isProcessing)

                    Button {
                        Task {
                            isProcessing = true
                            try? await walletConnect.rejectSession(proposal)
                            isProcessing = false
                            dismiss()
                        }
                    } label: {
                        Text("Reject")
                            .font(.headline)
                            .foregroundColor(.error)
                    }
                    .disabled(isProcessing)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Session Request")
            .navigationBarTitleDisplayMode(.inline)
            .loadingOverlay(isLoading: isProcessing, message: "Processing...")
        }
    }

    /// Maps WC chain identifiers to human-readable names.
    private static func friendlyChainName(_ chain: String) -> String {
        // EVM chains
        if chain.hasPrefix("eip155:") {
            guard let idStr = chain.split(separator: ":").last,
                  let chainId = UInt64(idStr) else { return chain }
            if let model = ChainModel.allChains.first(where: { $0.evmChainId == chainId }) {
                return model.name
            }
            return chain
        }

        // Solana chains (WC uses genesis hash as chain reference)
        if chain.hasPrefix("solana:") {
            if chain.contains("5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp") {
                return "Solana Mainnet"
            } else if chain.contains("4uhcVJyU9pJkvQyS88uRDiswHXSCkY3z") {
                return "Solana Testnet"
            } else if chain.contains("EtWTRABZaYq6iMfeYKouRu166VU2xqa1") {
                return "Solana Devnet"
            }
            return "Solana"
        }

        return chain
    }
}

#Preview {
    SessionApproveView(
        proposal: WalletConnectService.WCSessionProposal(
            id: "test",
            peerName: "Uniswap",
            peerUrl: "https://app.uniswap.org",
            peerIconUrl: nil,
            requiredChains: ["eip155:1"],
            optionalChains: ["eip155:137"],
            methods: ["eth_sendTransaction", "personal_sign"],
            events: ["chainChanged", "accountsChanged"]
        )
    )
}
