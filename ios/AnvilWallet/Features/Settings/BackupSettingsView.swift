import SwiftUI

/// BackupSettingsView allows users to view their recovery phrase and manage backups.
///
/// Requires biometric authentication before showing the recovery phrase.
struct BackupSettingsView: View {
    @EnvironmentObject var walletService: WalletService

    @State private var isAuthenticated = false
    @State private var isAuthenticating = false
    @State private var authError: String?
    @State private var showMnemonic = false
    @State private var mnemonicWords: [String] = []
    @State private var decryptError: String?
    @State private var isLoadingMnemonic = false

    private let biometricService = BiometricService()

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Backup status card
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.success)

                    Text("Wallet Backed Up")
                        .font(.title3.bold())
                        .foregroundColor(.textPrimary)

                    Text("Your recovery phrase was shown during wallet creation. Make sure you still have it stored safely.")
                        .font(.body)
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.backgroundCard)
                .cornerRadius(16)
                .padding(.horizontal, 20)
                .padding(.top, 16)

                // View recovery phrase
                VStack(spacing: 12) {
                    Text("Recovery Phrase")
                        .font(.headline)
                        .foregroundColor(.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !isAuthenticated {
                        VStack(spacing: 16) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.textTertiary)

                            Text("Authenticate to view your recovery phrase")
                                .font(.body)
                                .foregroundColor(.textSecondary)
                                .multilineTextAlignment(.center)

                            if let authError {
                                Text(authError)
                                    .font(.caption)
                                    .foregroundColor(.error)
                            }

                            Button {
                                Task {
                                    await authenticate()
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "faceid")
                                    Text("Authenticate")
                                }
                            }
                            .buttonStyle(.primary)
                            .disabled(isAuthenticating)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.backgroundCard)
                        .cornerRadius(16)
                    } else {
                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.warning)
                                Text("Make sure no one is watching your screen")
                                    .font(.caption)
                                    .foregroundColor(.warning)
                            }
                            .padding(8)
                            .background(Color.warning.opacity(0.1))
                            .cornerRadius(8)

                            if isLoadingMnemonic {
                                ProgressView()
                                    .padding()
                            } else if let decryptError {
                                Text(decryptError)
                                    .font(.body)
                                    .foregroundColor(.textSecondary)
                                    .multilineTextAlignment(.center)
                                    .padding()
                            } else if mnemonicWords.isEmpty {
                                Text("Recovery phrase not available. This wallet was created before backup support was added. Please re-import your wallet to enable recovery phrase viewing.")
                                    .font(.body)
                                    .foregroundColor(.textSecondary)
                                    .multilineTextAlignment(.center)
                                    .padding()
                            } else {
                                let columns = [
                                    GridItem(.flexible()),
                                    GridItem(.flexible()),
                                    GridItem(.flexible()),
                                ]
                                LazyVGrid(columns: columns, spacing: 10) {
                                    ForEach(Array(mnemonicWords.enumerated()), id: \.offset) { index, word in
                                        HStack(spacing: 4) {
                                            Text("\(index + 1).")
                                                .font(.caption)
                                                .foregroundColor(.textTertiary)
                                                .frame(width: 24, alignment: .trailing)
                                            Text(word)
                                                .font(.body.monospaced())
                                                .foregroundColor(.textPrimary)
                                        }
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 4)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.backgroundElevated)
                                        .cornerRadius(8)
                                    }
                                }
                                .padding(.top, 8)
                            }
                        }
                        .padding()
                        .background(Color.backgroundCard)
                        .cornerRadius(16)
                        .screenshotProtected()
                        .task {
                            await loadMnemonic()
                        }
                        .onDisappear {
                            mnemonicWords = []
                        }
                    }
                }
                .padding(.horizontal, 20)

                // Backup tips
                VStack(alignment: .leading, spacing: 12) {
                    Text("Backup Tips")
                        .font(.headline)
                        .foregroundColor(.textPrimary)

                    BackupTip(
                        icon: "pencil.and.outline",
                        text: "Write your recovery phrase on paper and store it in a safe or safety deposit box"
                    )
                    BackupTip(
                        icon: "lock.rectangle.on.rectangle.fill",
                        text: "Consider using a metal backup plate for fire and water resistance"
                    )
                    BackupTip(
                        icon: "person.2.slash.fill",
                        text: "Never share your recovery phrase with anyone -- not even us"
                    )
                    BackupTip(
                        icon: "iphone.slash",
                        text: "Do not store your recovery phrase digitally (no photos, no cloud storage)"
                    )
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .background(Color.backgroundPrimary)
        .navigationTitle("Backup & Recovery")
        .navigationBarTitleDisplayMode(.inline)
        .blurOnBackground()
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                mnemonicWords = []
                isAuthenticated = false
            }
        }
    }

    private func loadMnemonic() async {
        isLoadingMnemonic = true
        decryptError = nil

        do {
            if let words = try await walletService.decryptMnemonic() {
                await MainActor.run {
                    mnemonicWords = words
                }
            }
            // If nil, mnemonicWords stays empty — shows fallback message
        } catch {
            await MainActor.run {
                decryptError = error.localizedDescription
            }
        }

        await MainActor.run {
            isLoadingMnemonic = false
        }
    }

    private func authenticate() async {
        isAuthenticating = true
        authError = nil

        do {
            let success = try await biometricService.authenticate(
                reason: "Authenticate to view your recovery phrase"
            )
            await MainActor.run {
                isAuthenticated = success
                isAuthenticating = false
            }
        } catch {
            await MainActor.run {
                authError = error.localizedDescription
                isAuthenticating = false
            }
        }
    }
}

// MARK: - Backup Tip

private struct BackupTip: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(.accentGreen)
                .frame(width: 28)

            Text(text)
                .font(.body)
                .foregroundColor(.textSecondary)
        }
    }
}

#Preview {
    NavigationStack {
        BackupSettingsView()
            .environmentObject(WalletService.shared)
    }
}
