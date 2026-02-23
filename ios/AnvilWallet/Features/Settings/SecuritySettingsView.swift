import SwiftUI

/// SecuritySettingsView allows users to manage wallet security settings.
struct SecuritySettingsView: View {
    @EnvironmentObject var walletService: WalletService
    @ObservedObject private var securityService = SecurityService.shared
    @ObservedObject private var lockManager = SessionLockManager.shared

    @State private var showChangePassword = false
    @State private var isApplyingBiometricPolicy = false
    @State private var biometricPolicyError: String?
    @State private var ignoreBiometricToggleChange = false

    private let biometricService = BiometricService()

    var body: some View {
        List {
            // Biometric authentication
            Section("Authentication") {
                Toggle(isOn: $securityService.isBiometricAuthEnabled) {
                    HStack(spacing: 12) {
                        Image(systemName: biometricService.biometricType() == .faceID ? "faceid" : "touchid")
                            .foregroundColor(.accentGreen)

                        VStack(alignment: .leading) {
                            Text(biometricService.biometricName())
                                .foregroundColor(.textPrimary)
                            Text("Use biometrics to unlock signing keys")
                                .font(.caption)
                                .foregroundColor(.textSecondary)
                        }
                    }
                }
                .tint(.accentGreen)
                .disabled(isApplyingBiometricPolicy)

                if let biometricPolicyError {
                    Text(biometricPolicyError)
                        .font(.caption)
                        .foregroundColor(.error)
                }

                Picker("Auto-Lock", selection: Binding(
                    get: { lockManager.autoLockInterval },
                    set: { lockManager.autoLockInterval = $0 }
                )) {
                    ForEach(AutoLockInterval.allCases, id: \.self) { interval in
                        Text(interval.rawValue).tag(interval)
                    }
                }
                .pickerStyle(.menu)
                .foregroundColor(.textPrimary)
            }
            .listRowBackground(Color.backgroundCard)

            // Security features
            Section("Security") {
                Toggle(isOn: $securityService.isAutoClearClipboardEnabled) {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundColor(.accentGreen)

                        VStack(alignment: .leading) {
                            Text("Auto-clear clipboard")
                                .foregroundColor(.textPrimary)
                            Text("Clear copied data after 60 seconds")
                                .font(.caption)
                                .foregroundColor(.textSecondary)
                        }
                    }
                }
                .tint(.accentGreen)

                Toggle(isOn: $securityService.isScreenProtectionEnabled) {
                    HStack(spacing: 12) {
                        Image(systemName: "eye.slash.fill")
                            .foregroundColor(.accentGreen)

                        VStack(alignment: .leading) {
                            Text("Screen protection")
                                .foregroundColor(.textPrimary)
                            Text("Blur app content in app switcher")
                                .font(.caption)
                                .foregroundColor(.textSecondary)
                        }
                    }
                }
                .tint(.accentGreen)
            }
            .listRowBackground(Color.backgroundCard)

            // Password
            Section("Password") {
                Button {
                    showChangePassword = true
                } label: {
                    SettingsRow(icon: "key.fill", title: "Change Password", color: .warning)
                }
            }
            .listRowBackground(Color.backgroundCard)

            // Security status
            Section("Security Status") {
                SecurityStatusRow(
                    label: "Jailbreak Detection",
                    status: !securityService.isJailbroken,
                    description: securityService.isJailbroken
                        ? "Jailbreak indicators detected"
                        : "No jailbreak indicators found"
                )

                SecurityStatusRow(
                    label: "App Integrity",
                    status: !SecurityBootstrap.integrityFailed,
                    description: SecurityBootstrap.integrityFailed
                        ? "Integrity check failed"
                        : "App binary is intact"
                )

                SecurityStatusRow(
                    label: "Secure Enclave",
                    status: true,
                    description: "Hardware key protection active"
                )

                if securityService.isBiometricLockedOut {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.warning)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Biometric Lockout")
                                .font(.body)
                                .foregroundColor(.textPrimary)

                            Text("Too many failed attempts. Try again in \(securityService.lockoutRemainingFormatted)")
                                .font(.caption)
                                .foregroundColor(.warning)
                        }

                        Spacer()

                        Image(systemName: "clock.fill")
                            .foregroundColor(.warning)
                    }
                }
            }
            .listRowBackground(Color.backgroundCard)

            // Encrypted Backup
            Section("Encrypted Backup") {
                NavigationLink {
                    ExportBackupView()
                        .environmentObject(walletService)
                } label: {
                    SettingsRow(icon: "arrow.up.doc.fill", title: "Export Encrypted Backup", color: .info)
                }

                NavigationLink {
                    ImportBackupView()
                        .environmentObject(walletService)
                } label: {
                    SettingsRow(icon: "arrow.down.doc.fill", title: "Import Backup", color: .accentGreen)
                }
            }
            .listRowBackground(Color.backgroundCard)
        }
        .scrollContentBackground(.hidden)
        .background(Color.backgroundPrimary)
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordSheet()
                .environmentObject(walletService)
        }
        .onChange(of: securityService.isBiometricAuthEnabled) { oldValue, newValue in
            guard !ignoreBiometricToggleChange else { return }
            Task { await applyBiometricPolicyChange(from: oldValue, to: newValue) }
        }
    }

    private func applyBiometricPolicyChange(from oldValue: Bool, to newValue: Bool) async {
        await MainActor.run {
            isApplyingBiometricPolicy = true
            biometricPolicyError = nil
        }

        do {
            try walletService.migrateSecureEnclaveProtection(requiresBiometrics: newValue)
            await MainActor.run {
                isApplyingBiometricPolicy = false
            }
        } catch {
            await MainActor.run {
                isApplyingBiometricPolicy = false
                biometricPolicyError = "Could not apply biometric setting. Please authenticate and try again."
                ignoreBiometricToggleChange = true
                securityService.isBiometricAuthEnabled = oldValue
                ignoreBiometricToggleChange = false
            }
        }
    }
}

// MARK: - Security Status Row

private struct SecurityStatusRow: View {
    let label: String
    let status: Bool
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: status ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .foregroundColor(status ? .success : .error)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.body)
                    .foregroundColor(.textPrimary)

                Text(description)
                    .font(.caption)
                    .foregroundColor(status ? .textSecondary : .error)
            }

            Spacer()

            Image(systemName: status ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(status ? .success : .error)
        }
    }
}

// MARK: - Change Password Sheet

private struct ChangePasswordSheet: View {
    @EnvironmentObject var walletService: WalletService
    @Environment(\.dismiss) private var dismiss

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @State private var isProcessing = false

    private var isValid: Bool {
        !currentPassword.isEmpty && !newPassword.isEmpty && newPassword == confirmPassword
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                SecureField("Current Password", text: $currentPassword)
                    .padding(14)
                    .background(Color.backgroundCard)
                    .cornerRadius(10)

                SecureField("New Password", text: $newPassword)
                    .padding(14)
                    .background(Color.backgroundCard)
                    .cornerRadius(10)

                SecureField("Confirm New Password", text: $confirmPassword)
                    .padding(14)
                    .background(Color.backgroundCard)
                    .cornerRadius(10)

                if newPassword != confirmPassword && !confirmPassword.isEmpty {
                    Text("Passwords do not match")
                        .font(.caption)
                        .foregroundColor(.error)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.error)
                }

                Spacer()

                Button {
                    Task {
                        isProcessing = true
                        errorMessage = nil
                        do {
                            try await walletService.changePassword(current: currentPassword, new: newPassword)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                        isProcessing = false
                    }
                } label: {
                    Text("Change Password")
                }
                .buttonStyle(.primary)
                .disabled(!isValid || isProcessing)
            }
            .padding(20)
            .background(Color.backgroundPrimary)
            .navigationTitle("Change Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        SecuritySettingsView()
    }
}
