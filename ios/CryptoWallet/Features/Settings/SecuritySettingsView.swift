import SwiftUI

/// SecuritySettingsView allows users to manage wallet security settings.
struct SecuritySettingsView: View {
    @State private var isBiometricEnabled = true
    @State private var autoLockInterval = AutoLockInterval.fiveMinutes
    @State private var showChangePassword = false

    private let biometricService = BiometricService()

    enum AutoLockInterval: String, CaseIterable {
        case immediately = "Immediately"
        case oneMinute = "1 minute"
        case fiveMinutes = "5 minutes"
        case fifteenMinutes = "15 minutes"
        case never = "Never"
    }

    var body: some View {
        List {
            // Biometric authentication
            Section("Authentication") {
                Toggle(isOn: $isBiometricEnabled) {
                    HStack(spacing: 12) {
                        Image(systemName: biometricService.biometricType() == .faceID ? "faceid" : "touchid")
                            .foregroundColor(.accentGreen)

                        VStack(alignment: .leading) {
                            Text(biometricService.biometricName())
                                .foregroundColor(.textPrimary)
                            Text("Require biometric to open wallet and sign transactions")
                                .font(.caption)
                                .foregroundColor(.textSecondary)
                        }
                    }
                }
                .tint(.accentGreen)

                Picker("Auto-Lock", selection: $autoLockInterval) {
                    ForEach(AutoLockInterval.allCases, id: \.self) { interval in
                        Text(interval.rawValue).tag(interval)
                    }
                }
                .foregroundColor(.textPrimary)
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
                    status: !SecurityBootstrap.jailbreakDetected,
                    description: SecurityBootstrap.jailbreakDetected
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
            }
            .listRowBackground(Color.backgroundCard)

            // Advanced
            Section("Advanced") {
                NavigationLink {
                    // TODO: Export encrypted backup
                    Text("Export Backup")
                        .foregroundColor(.textPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.backgroundPrimary)
                } label: {
                    SettingsRow(icon: "arrow.up.doc.fill", title: "Export Encrypted Backup", color: .info)
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
    @Environment(\.dismiss) private var dismiss

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""

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

                Spacer()

                Button {
                    // TODO: Implement password change via Rust FFI
                    // 1. Decrypt seed with current password
                    // 2. Re-encrypt seed with new password
                    // 3. Re-encrypt with SE and store in Keychain
                    dismiss()
                } label: {
                    Text("Change Password")
                }
                .buttonStyle(.primary)
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
