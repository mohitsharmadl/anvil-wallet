import SwiftUI
import UniformTypeIdentifiers

// MARK: - Import Backup View

/// ImportBackupView guides the user through restoring a wallet from an encrypted .anvilbackup file.
///
/// Flow:
///   1. Pick the .anvilbackup file via document picker
///   2. Validate the file header
///   3. Enter the backup password used during export
///   4. Set a new app password for the restored wallet
///   5. Decrypt and restore via WalletService
struct ImportBackupView: View {
    @EnvironmentObject var walletService: WalletService
    @EnvironmentObject var router: AppRouter

    // File picker
    @State private var showFilePicker = false
    @State private var selectedFileData: Data?
    @State private var selectedFileName: String?
    @State private var fileError: String?

    // Password entry
    @State private var backupPassword = ""
    @State private var appPassword = ""
    @State private var confirmAppPassword = ""
    @State private var passwordError: String?

    // Import state
    @State private var isImporting = false
    @State private var importError: String?
    @State private var showSuccess = false
    @State private var showReplaceWarning = false

    private var appPasswordsMatch: Bool {
        !appPassword.isEmpty && appPassword == confirmAppPassword
    }

    private var isAppPasswordStrong: Bool {
        appPassword.count >= 8
    }

    private var canImport: Bool {
        selectedFileData != nil &&
        !backupPassword.isEmpty &&
        appPasswordsMatch &&
        isAppPasswordStrong &&
        !isImporting
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if showSuccess {
                    successSection
                } else {
                    filePickerSection
                    if selectedFileData != nil {
                        passwordSection
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(Color.backgroundPrimary)
        .navigationTitle("Import Backup")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showFilePicker) {
            DocumentPicker(fileData: $selectedFileData, fileName: $selectedFileName, fileError: $fileError)
        }
        .alert("Replace Current Wallet?", isPresented: $showReplaceWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Replace", role: .destructive) {
                Task { await performImport() }
            }
        } message: {
            Text("This will permanently replace your current wallet with the backup. Make sure you have your current recovery phrase backed up. This action cannot be undone.")
        }
    }

    // MARK: - File Picker Section

    private var filePickerSection: some View {
        VStack(spacing: 16) {
            // Info header
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.info)

                Text("Restore from Backup")
                    .font(.title3.bold())
                    .foregroundColor(.textPrimary)

                Text("Select an Anvil Wallet backup file (.anvilbackup) to restore your wallet.")
                    .font(.body)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .background(Color.backgroundCard)
            .cornerRadius(16)

            // File selection
            Button {
                showFilePicker = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selectedFileData != nil ? "doc.fill" : "doc.badge.plus")
                        .font(.title2)
                        .foregroundColor(selectedFileData != nil ? .success : .accentGreen)

                    VStack(alignment: .leading, spacing: 2) {
                        if let fileName = selectedFileName {
                            Text(fileName)
                                .font(.body)
                                .foregroundColor(.textPrimary)
                                .lineLimit(1)
                            Text(formatFileSize(selectedFileData?.count ?? 0))
                                .font(.caption)
                                .foregroundColor(.textSecondary)
                        } else {
                            Text("Select Backup File")
                                .font(.body)
                                .foregroundColor(.textPrimary)
                            Text("Tap to browse for .anvilbackup files")
                                .font(.caption)
                                .foregroundColor(.textSecondary)
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.body)
                        .foregroundColor(.textTertiary)
                }
                .padding(14)
                .background(Color.backgroundCard)
                .cornerRadius(12)
            }

            if let fileError {
                Text(fileError)
                    .font(.caption)
                    .foregroundColor(.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Password Section

    private var passwordSection: some View {
        VStack(spacing: 16) {
            // Warning banner
            if walletService.isWalletCreated {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.error)
                    Text("Importing a backup will replace your current wallet. Make sure you have your current recovery phrase backed up.")
                        .font(.caption)
                        .foregroundColor(.error)
                }
                .padding(12)
                .background(Color.error.opacity(0.1))
                .cornerRadius(10)
            }

            // Backup password
            VStack(alignment: .leading, spacing: 8) {
                Text("Backup Password")
                    .font(.headline)
                    .foregroundColor(.textPrimary)

                Text("Enter the password you used when creating this backup.")
                    .font(.caption)
                    .foregroundColor(.textSecondary)

                SecureField("Backup Password", text: $backupPassword)
                    .padding(14)
                    .background(Color.backgroundCard)
                    .cornerRadius(10)
                    .textContentType(.password)
            }

            Divider()
                .background(Color.border)

            // New app password
            VStack(alignment: .leading, spacing: 8) {
                Text("New App Password")
                    .font(.headline)
                    .foregroundColor(.textPrimary)

                Text("Set a password for your restored wallet on this device.")
                    .font(.caption)
                    .foregroundColor(.textSecondary)

                SecureField("App Password", text: $appPassword)
                    .padding(14)
                    .background(Color.backgroundCard)
                    .cornerRadius(10)
                    .textContentType(.newPassword)

                if !appPassword.isEmpty && !isAppPasswordStrong {
                    Text("Password must be at least 8 characters")
                        .font(.caption)
                        .foregroundColor(.error)
                }

                SecureField("Confirm App Password", text: $confirmAppPassword)
                    .padding(14)
                    .background(Color.backgroundCard)
                    .cornerRadius(10)
                    .textContentType(.newPassword)

                if !confirmAppPassword.isEmpty && !appPasswordsMatch {
                    Text("Passwords do not match")
                        .font(.caption)
                        .foregroundColor(.error)
                }
            }

            if let importError {
                Text(importError)
                    .font(.caption)
                    .foregroundColor(.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Import button
            Button {
                if walletService.isWalletCreated {
                    showReplaceWarning = true
                } else {
                    Task { await performImport() }
                }
            } label: {
                if isImporting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    HStack {
                        Image(systemName: "arrow.down.doc.fill")
                        Text("Restore Wallet")
                    }
                }
            }
            .buttonStyle(.primary)
            .disabled(!canImport)
        }
    }

    // MARK: - Success Section

    private var successSection: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(.success)

            Text("Wallet Restored")
                .font(.title2.bold())
                .foregroundColor(.textPrimary)

            Text("Your wallet has been successfully restored from the backup. All addresses have been re-derived.")
                .font(.body)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                router.navigateToTab(.wallet)
            } label: {
                Text("Go to Wallet")
            }
            .buttonStyle(.primary)
        }
        .padding()
        .background(Color.backgroundCard)
        .cornerRadius(16)
    }

    // MARK: - Actions

    private func performImport() async {
        guard let fileData = selectedFileData else { return }

        isImporting = true
        importError = nil

        do {
            try await walletService.importEncryptedBackup(
                backupData: fileData,
                backupPassword: backupPassword,
                appPassword: appPassword
            )

            await MainActor.run {
                showSuccess = true
                isImporting = false
                // Clear sensitive fields
                backupPassword = ""
                appPassword = ""
                confirmAppPassword = ""
            }
        } catch {
            await MainActor.run {
                importError = error.localizedDescription
                isImporting = false
            }
        }
    }

    private func formatFileSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) bytes"
        } else {
            let kb = Double(bytes) / 1024.0
            return String(format: "%.1f KB", kb)
        }
    }
}

// MARK: - Document Picker

/// UIKit wrapper for UIDocumentPickerViewController to pick .anvilbackup files.
struct DocumentPicker: UIViewControllerRepresentable {
    @Binding var fileData: Data?
    @Binding var fileName: String?
    @Binding var fileError: String?

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Accept both the custom UTType and generic data (for files not registered with the system)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.anvilBackup, .data])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker

        init(_ parent: DocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }

            // Start accessing the security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                parent.fileError = "Unable to access the selected file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            // Validate file extension
            guard url.pathExtension.lowercased() == "anvilbackup" else {
                parent.fileError = "Please select a file with .anvilbackup extension."
                return
            }

            do {
                let data = try Data(contentsOf: url)

                // Quick header validation
                guard data.count > 5,
                      data[0] == 0x41, data[1] == 0x4E,
                      data[2] == 0x56, data[3] == 0x4C else {
                    parent.fileError = "This file is not a valid Anvil Wallet backup."
                    return
                }

                parent.fileData = data
                parent.fileName = url.lastPathComponent
                parent.fileError = nil
            } catch {
                parent.fileError = "Failed to read backup file: \(error.localizedDescription)"
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // No action needed
        }
    }
}

#Preview {
    NavigationStack {
        ImportBackupView()
            .environmentObject(WalletService.shared)
            .environmentObject(AppRouter())
    }
}
