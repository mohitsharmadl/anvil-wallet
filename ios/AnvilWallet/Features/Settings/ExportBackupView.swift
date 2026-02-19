import SwiftUI
import UniformTypeIdentifiers

// MARK: - Anvil Backup UTType

extension UTType {
    /// Custom UTType for Anvil Wallet encrypted backup files.
    static let anvilBackup = UTType(exportedAs: "com.anvilwallet.backup", conformingTo: .data)
}

// MARK: - Export Backup View

/// ExportBackupView guides the user through creating an encrypted backup of their wallet.
///
/// Flow:
///   1. Biometric authentication gate
///   2. Backup password entry with confirmation
///   3. Encryption via Rust FFI (Argon2id + AES-256-GCM)
///   4. Share sheet to save the .anvilbackup file
struct ExportBackupView: View {
    @EnvironmentObject var walletService: WalletService
    @Environment(\.dismiss) private var dismiss

    // Authentication
    @State private var isAuthenticated = false
    @State private var isAuthenticating = false
    @State private var authError: String?

    // Password entry
    @State private var backupPassword = ""
    @State private var confirmPassword = ""
    @State private var passwordError: String?

    // Export state
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var exportedFileURL: URL?
    @State private var showShareSheet = false
    @State private var showSuccess = false

    private let biometricService = BiometricService()

    private var passwordsMatch: Bool {
        !backupPassword.isEmpty && backupPassword == confirmPassword
    }

    private var isPasswordStrong: Bool {
        backupPassword.count >= 8
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if !isAuthenticated {
                    authenticationSection
                } else if showSuccess {
                    successSection
                } else {
                    passwordSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .background(Color.backgroundPrimary)
        .navigationTitle("Export Backup")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShareSheet) {
            if let url = exportedFileURL {
                ShareSheet(activityItems: [url])
            }
        }
    }

    // MARK: - Authentication Section

    private var authenticationSection: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentGreen)

            Text("Authentication Required")
                .font(.title3.bold())
                .foregroundColor(.textPrimary)

            Text("Authenticate with biometrics to access your wallet data for backup.")
                .font(.body)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)

            if let authError {
                Text(authError)
                    .font(.caption)
                    .foregroundColor(.error)
            }

            Button {
                Task { await authenticate() }
            } label: {
                HStack {
                    Image(systemName: biometricService.biometricType() == .faceID ? "faceid" : "touchid")
                    Text("Authenticate")
                }
            }
            .buttonStyle(.primary)
            .disabled(isAuthenticating)
        }
        .padding()
        .background(Color.backgroundCard)
        .cornerRadius(16)
    }

    // MARK: - Password Section

    private var passwordSection: some View {
        VStack(spacing: 20) {
            // Warning banner
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.warning)
                Text("You are responsible for remembering this password. If you lose it, the backup cannot be decrypted.")
                    .font(.caption)
                    .foregroundColor(.warning)
            }
            .padding(12)
            .background(Color.warning.opacity(0.1))
            .cornerRadius(10)

            // Info card
            VStack(spacing: 12) {
                Image(systemName: "doc.badge.gearshape.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.info)

                Text("Set Backup Password")
                    .font(.title3.bold())
                    .foregroundColor(.textPrimary)

                Text("Choose a strong password to encrypt your backup. This is separate from your app password.")
                    .font(.body)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .background(Color.backgroundCard)
            .cornerRadius(16)

            // Password fields
            VStack(spacing: 12) {
                SecureField("Backup Password", text: $backupPassword)
                    .padding(14)
                    .background(Color.backgroundCard)
                    .cornerRadius(10)
                    .textContentType(.newPassword)

                if !backupPassword.isEmpty && !isPasswordStrong {
                    Text("Password must be at least 8 characters")
                        .font(.caption)
                        .foregroundColor(.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                SecureField("Confirm Backup Password", text: $confirmPassword)
                    .padding(14)
                    .background(Color.backgroundCard)
                    .cornerRadius(10)
                    .textContentType(.newPassword)

                if !confirmPassword.isEmpty && !passwordsMatch {
                    Text("Passwords do not match")
                        .font(.caption)
                        .foregroundColor(.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let passwordError {
                    Text(passwordError)
                        .font(.caption)
                        .foregroundColor(.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let exportError {
                    Text(exportError)
                        .font(.caption)
                        .foregroundColor(.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Export button
            Button {
                Task { await exportBackup() }
            } label: {
                if isExporting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    HStack {
                        Image(systemName: "arrow.up.doc.fill")
                        Text("Create Encrypted Backup")
                    }
                }
            }
            .buttonStyle(.primary)
            .disabled(!passwordsMatch || !isPasswordStrong || isExporting)

            // Security notes
            VStack(alignment: .leading, spacing: 8) {
                Text("Security Notes")
                    .font(.headline)
                    .foregroundColor(.textPrimary)

                SecurityNote(
                    icon: "lock.fill",
                    text: "Encrypted with Argon2id + AES-256-GCM (same as your wallet storage)"
                )
                SecurityNote(
                    icon: "key.fill",
                    text: "The backup password is not stored anywhere -- only you know it"
                )
                SecurityNote(
                    icon: "icloud.slash.fill",
                    text: "Save the backup file somewhere safe and offline if possible"
                )
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Success Section

    private var successSection: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(.success)

            Text("Backup Created")
                .font(.title2.bold())
                .foregroundColor(.textPrimary)

            Text("Your encrypted backup file has been created. Save it in a secure location.")
                .font(.body)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)

            if exportedFileURL != nil {
                Button {
                    showShareSheet = true
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share Backup File")
                    }
                }
                .buttonStyle(.primary)
            }

            Button {
                dismiss()
            } label: {
                Text("Done")
            }
            .buttonStyle(.secondary)
        }
        .padding()
        .background(Color.backgroundCard)
        .cornerRadius(16)
    }

    // MARK: - Actions

    private func authenticate() async {
        isAuthenticating = true
        authError = nil

        do {
            let success = try await biometricService.authenticate(
                reason: "Authenticate to export wallet backup"
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

    private func exportBackup() async {
        isExporting = true
        exportError = nil

        do {
            let backupData = try await walletService.exportEncryptedBackup(backupPassword: backupPassword)

            // Write to a temporary file with .anvilbackup extension
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let dateStr = formatter.string(from: Date())
            let fileName = "AnvilWallet-\(dateStr).anvilbackup"
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

            try backupData.write(to: tempURL)

            await MainActor.run {
                exportedFileURL = tempURL
                showSuccess = true
                showShareSheet = true
                isExporting = false
                // Clear password fields
                backupPassword = ""
                confirmPassword = ""
            }
        } catch {
            await MainActor.run {
                exportError = error.localizedDescription
                isExporting = false
            }
        }
    }
}

// MARK: - Security Note

private struct SecurityNote: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.accentGreen)
                .frame(width: 20)

            Text(text)
                .font(.caption)
                .foregroundColor(.textSecondary)
        }
    }
}

// MARK: - Share Sheet

/// UIKit wrapper for UIActivityViewController to present the iOS share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        ExportBackupView()
            .environmentObject(WalletService.shared)
    }
}
