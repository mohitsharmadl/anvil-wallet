import SwiftUI

/// DAppsView shows connected dApps, popular dApp shortcuts, and allows
/// pairing with new ones via WalletConnect or opening them in the in-app browser.
struct DAppsView: View {
    @EnvironmentObject var walletService: WalletService
    @StateObject private var walletConnect = WalletConnectService.shared

    @State private var pairingURI = ""
    @State private var showQRScanner = false
    @State private var isPairing = false
    @State private var errorMessage: String?
    @State private var browserURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Popular DApps
                    popularDAppsSection

                    Divider()
                        .background(Color.separator)
                        .padding(.horizontal, 20)

                    // Pairing section
                    VStack(spacing: 16) {
                        Text("WalletConnect")
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
                        .buttonStyle(.primary)
                        .disabled(pairingURI.isEmpty || isPairing)
                    }
                    .padding(.horizontal, 20)

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

                                Text("Connect via WalletConnect or open a dApp from the browser above.")
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
                    .padding(.bottom, 20)
                }
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("DApps")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: URL.self) { url in
                DAppBrowserView(initialURL: url)
            }
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

    // MARK: - Popular DApps

    private var popularDAppsSection: some View {
        VStack(spacing: 16) {
            Text("Popular DApps")
                .font(.headline)
                .foregroundColor(.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ], spacing: 12) {
                ForEach(PopularDApp.all) { dapp in
                    NavigationLink(value: dapp.url) {
                        DAppTile(dapp: dapp)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    // MARK: - Pairing

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

// MARK: - Popular DApp Model

private struct PopularDApp: Identifiable {
    let id: String
    let name: String
    let icon: String
    let url: URL
    let color: Color

    static let all: [PopularDApp] = [
        PopularDApp(id: "uniswap", name: "Uniswap", icon: "arrow.triangle.2.circlepath", url: URL(string: "https://app.uniswap.org")!, color: .pink),
        PopularDApp(id: "aave", name: "Aave", icon: "building.columns", url: URL(string: "https://app.aave.com")!, color: .purple),
        PopularDApp(id: "opensea", name: "OpenSea", icon: "photo.stack", url: URL(string: "https://opensea.io")!, color: .blue),
        PopularDApp(id: "lido", name: "Lido", icon: "water.waves", url: URL(string: "https://stake.lido.fi")!, color: .cyan),
        PopularDApp(id: "curve", name: "Curve", icon: "chart.line.uptrend.xyaxis", url: URL(string: "https://curve.fi")!, color: .yellow),
        PopularDApp(id: "ens", name: "ENS", icon: "person.text.rectangle", url: URL(string: "https://app.ens.domains")!, color: .indigo),
        PopularDApp(id: "raydium", name: "Raydium", icon: "bolt.circle", url: URL(string: "https://raydium.io/swap")!, color: .mint),
        PopularDApp(id: "jupiter", name: "Jupiter", icon: "globe.americas", url: URL(string: "https://jup.ag")!, color: .green),
        PopularDApp(id: "zapper", name: "Zapper", icon: "chart.pie", url: URL(string: "https://zapper.xyz")!, color: .orange),
    ]
}

// MARK: - DApp Tile

private struct DAppTile: View {
    let dapp: PopularDApp

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(dapp.color.opacity(0.15))
                    .frame(width: 52, height: 52)

                Image(systemName: dapp.icon)
                    .font(.title3)
                    .foregroundColor(dapp.color)
            }

            Text(dapp.name)
                .font(.caption.weight(.medium))
                .foregroundColor(.textPrimary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.backgroundCard)
        .cornerRadius(12)
    }
}

// MARK: - Session Row

private struct SessionRowView: View {
    let session: WalletConnectService.WCSession
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
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

#Preview {
    DAppsView()
        .environmentObject(WalletService.shared)
        .environmentObject(AppRouter())
}
