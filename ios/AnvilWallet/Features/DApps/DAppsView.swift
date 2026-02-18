import SwiftUI

/// DAppsView shows connected dApps and allows pairing with new ones via WalletConnect.
///
/// Phase 5 feature -- currently shows the pairing UI and placeholder session list.
struct DAppsView: View {
    @EnvironmentObject var walletService: WalletService
    @StateObject private var walletConnect = WalletConnectService.shared

    @State private var pairingURI = ""
    @State private var showQRScanner = false
    @State private var isPairing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Coming Soon banner
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.accentGreen)
                        Text("WalletConnect v2 integration is coming in a future update.")
                            .font(.subheadline)
                            .foregroundColor(.textSecondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentGreen.opacity(0.08))
                    .cornerRadius(10)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                    // Pairing section
                    VStack(spacing: 16) {
                        Text("Connect to DApp")
                            .font(.headline)
                            .foregroundColor(.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // URI input
                        HStack {
                            TextField("Paste WalletConnect URI", text: $pairingURI)
                                .font(.body)
                                .foregroundColor(.textPrimary)
                                .autocapitalization(.none)
                                .autocorrectionDisabled()

                            Button {
                                showQRScanner = true
                            } label: {
                                Image(systemName: "qrcode.viewfinder")
                                    .foregroundColor(.accentGreen)
                            }
                        }
                        .padding(14)
                        .background(Color.backgroundCard)
                        .cornerRadius(12)

                        Button {
                            Task {
                                await pair()
                            }
                        } label: {
                            Text("Connect")
                        }
                        .buttonStyle(PrimaryButtonStyle(isEnabled: false))
                        .disabled(true)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.error)
                            .padding(.horizontal, 20)
                    }

                    Divider()
                        .background(Color.separator)
                        .padding(.horizontal, 20)

                    // Active sessions
                    VStack(spacing: 16) {
                        Text("Connected DApps")
                            .font(.headline)
                            .foregroundColor(.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if walletConnect.activeSessions.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "link.circle")
                                    .font(.system(size: 48))
                                    .foregroundColor(.textTertiary)

                                Text("No Connected DApps")
                                    .font(.body)
                                    .foregroundColor(.textSecondary)

                                Text("Scan a QR code or paste a WalletConnect URI to connect to a dApp.")
                                    .font(.caption)
                                    .foregroundColor(.textTertiary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        } else {
                            ForEach(walletConnect.activeSessions) { session in
                                SessionRowView(session: session) {
                                    Task {
                                        try? await walletConnect.disconnectSession(session)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("DApps")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showQRScanner) {
                QRScannerView { scannedURI in
                    pairingURI = scannedURI
                    showQRScanner = false
                }
            }
            .sheet(item: $walletConnect.pendingProposal) { proposal in
                SessionApproveView(proposal: proposal)
            }
            .sheet(item: $walletConnect.pendingRequest) { request in
                SignRequestView(request: request)
            }
            .loadingOverlay(isLoading: isPairing, message: "Connecting...")
        }
    }

    private func pair() async {
        isPairing = true
        errorMessage = nil

        do {
            try await walletConnect.pair(uri: pairingURI)
            pairingURI = ""
        } catch {
            errorMessage = error.localizedDescription
        }

        isPairing = false
    }
}

// MARK: - Session Row

private struct SessionRowView: View {
    let session: WalletConnectService.WCSession
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // DApp icon placeholder
            Circle()
                .fill(Color.backgroundElevated)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "globe")
                        .foregroundColor(.textTertiary)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(session.peerName)
                    .font(.body.bold())
                    .foregroundColor(.textPrimary)

                Text(session.peerUrl)
                    .font(.caption)
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                onDisconnect()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.textTertiary)
            }
        }
        .padding()
        .background(Color.backgroundCard)
        .cornerRadius(12)
    }
}

// Make WCSessionProposal conform to Identifiable for .sheet(item:)
extension WalletConnectService.WCSessionProposal: @retroactive Equatable {
    static func == (lhs: WalletConnectService.WCSessionProposal, rhs: WalletConnectService.WCSessionProposal) -> Bool {
        lhs.id == rhs.id
    }
}

// Make WCSignRequest conform to Identifiable for .sheet(item:)
extension WalletConnectService.WCSignRequest: @retroactive Equatable {
    static func == (lhs: WalletConnectService.WCSignRequest, rhs: WalletConnectService.WCSignRequest) -> Bool {
        lhs.id == rhs.id
    }
}

#Preview {
    DAppsView()
        .environmentObject(WalletService.shared)
}
