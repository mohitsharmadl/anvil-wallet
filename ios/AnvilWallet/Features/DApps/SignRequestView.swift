import SwiftUI

/// SignRequestView presents a WalletConnect sign request from a connected dApp.
///
/// Supports:
///   - personal_sign (message signing)
///   - eth_signTypedData (EIP-712)
///   - eth_sendTransaction (transaction signing)
struct SignRequestView: View {
    @StateObject private var walletConnect = WalletConnectService.shared
    @EnvironmentObject var walletService: WalletService
    @Environment(\.dismiss) private var dismiss

    let request: WalletConnectService.WCSignRequest

    @State private var isProcessing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // DApp info
                VStack(spacing: 8) {
                    Circle()
                        .fill(Color.backgroundElevated)
                        .frame(width: 48, height: 48)
                        .overlay(
                            Image(systemName: "signature")
                                .foregroundColor(.textSecondary)
                        )

                    Text(request.peerName)
                        .font(.headline)
                        .foregroundColor(.textPrimary)

                    Text("requests a signature")
                        .font(.body)
                        .foregroundColor(.textSecondary)
                }
                .padding(.top, 24)

                // Request details
                VStack(alignment: .leading, spacing: 12) {
                    DetailItem(label: "Method", value: request.method)
                    DetailItem(label: "Chain", value: request.chain)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Data")
                            .font(.subheadline.bold())
                            .foregroundColor(.textSecondary)

                        ScrollView {
                            if let paramsString = String(data: request.params, encoding: .utf8) {
                                Text(paramsString)
                                    .font(.caption.monospaced())
                                    .foregroundColor(.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text("\(request.params.count) bytes")
                                    .font(.caption)
                                    .foregroundColor(.textTertiary)
                            }
                        }
                        .frame(maxHeight: 200)
                        .padding(12)
                        .background(Color.backgroundElevated)
                        .cornerRadius(8)
                    }
                }
                .padding()
                .background(Color.backgroundCard)
                .cornerRadius(16)
                .padding(.horizontal, 20)

                // Security note
                HStack(spacing: 8) {
                    Image(systemName: "faceid")
                        .foregroundColor(.accentGreen)

                    Text("Signing requires biometric authentication.")
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                }
                .padding(12)
                .background(Color.backgroundCard)
                .cornerRadius(12)
                .padding(.horizontal, 20)

                Spacer()

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.error)
                        .padding(.horizontal, 20)
                }

                // Buttons
                VStack(spacing: 12) {
                    Button {
                        Task {
                            isProcessing = true
                            errorMessage = nil
                            do {
                                try await walletConnect.approveRequest(request, walletService: walletService)
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                            isProcessing = false
                        }
                    } label: {
                        Text("Sign")
                    }
                    .buttonStyle(.primary)
                    .disabled(isProcessing)

                    Button {
                        Task {
                            isProcessing = true
                            try? await walletConnect.rejectRequest(request)
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
            .navigationTitle("Sign Request")
            .navigationBarTitleDisplayMode(.inline)
            .loadingOverlay(isLoading: isProcessing, message: "Signing...")
        }
    }
}

private struct DetailItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline.bold())
                .foregroundColor(.textSecondary)

            Text(value)
                .font(.body.monospaced())
                .foregroundColor(.textPrimary)
        }
    }
}

#Preview {
    SignRequestView(
        request: WalletConnectService.WCSignRequest(
            id: "test",
            sessionId: "session1",
            chain: "eip155:1",
            method: "personal_sign",
            params: "Hello from Uniswap".data(using: .utf8)!,
            peerName: "Uniswap"
        )
    )
}
