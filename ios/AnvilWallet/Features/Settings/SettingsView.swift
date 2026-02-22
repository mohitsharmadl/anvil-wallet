import SwiftUI

/// SettingsView is the main settings screen with navigation to sub-settings.
struct SettingsView: View {
    @EnvironmentObject var walletService: WalletService
    @EnvironmentObject var router: AppRouter
    @AppStorage("appTheme") private var appTheme = AppTheme.system

    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                // Wallet info section
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "wallet.pass.fill")
                            .font(.title2)
                            .foregroundColor(.accentGreen)
                            .frame(width: 44, height: 44)
                            .background(Color.accentGreen.opacity(0.1))
                            .cornerRadius(12)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(walletService.currentWallet?.displayName ?? "Account 0")
                                .font(.headline)
                                .foregroundColor(.textPrimary)

                            Text("\(walletService.accounts.count) accounts \u{2022} \(walletService.addresses.count) chains")
                                .font(.caption)
                                .foregroundColor(.textSecondary)
                        }
                    }
                    .listRowBackground(Color.backgroundCard)

                    NavigationLink(destination: AccountManagerView()) {
                        SettingsRow(icon: "person.2.fill", title: "Manage Accounts", color: .chainSolana)
                    }
                    .listRowBackground(Color.backgroundCard)
                }

                // Security section
                Section("Security") {
                    NavigationLink(destination: SecuritySettingsView()) {
                        SettingsRow(icon: "lock.shield.fill", title: "Security", color: .accentGreen)
                    }

                    NavigationLink(destination: BackupSettingsView()) {
                        SettingsRow(icon: "arrow.counterclockwise", title: "Backup & Recovery", color: .info)
                    }

                    NavigationLink(destination: ApprovalTrackerView()) {
                        SettingsRow(icon: "checkmark.seal.fill", title: "Token Approvals", color: .warning)
                    }

                    NavigationLink(destination: NotificationSettingsView()) {
                        SettingsRow(icon: "bell.badge.fill", title: "Notifications", color: .chainSolana)
                    }
                }
                .listRowBackground(Color.backgroundCard)

                // Address Book
                Section("Contacts") {
                    NavigationLink(destination: AddressBookView()) {
                        SettingsRow(icon: "person.crop.rectangle.stack", title: "Address Book", color: .accentGreen)
                    }

                    NavigationLink(destination: WatchAddressesView()) {
                        SettingsRow(icon: "eye.fill", title: "Watch Addresses", color: .info)
                    }
                }
                .listRowBackground(Color.backgroundCard)

                // Network section
                Section("Network") {
                    NavigationLink(destination: NetworkSettingsView()) {
                        SettingsRow(icon: "network", title: "Networks", color: .chainEthereum)
                    }
                }
                .listRowBackground(Color.backgroundCard)

                // Appearance section
                Section("Appearance") {
                    Picker(selection: $appTheme) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            Text(theme.rawValue).tag(theme)
                        }
                    } label: {
                        SettingsRow(icon: "paintbrush.fill", title: "Theme", color: .info)
                    }
                    .pickerStyle(.menu)
                }
                .listRowBackground(Color.backgroundCard)

                // App section
                Section("App") {
                    HStack {
                        SettingsRow(icon: "info.circle.fill", title: "Version", color: .textTertiary)
                        Spacer()
                        Text("1.0.0 (Phase 1)")
                            .font(.body)
                            .foregroundColor(.textTertiary)
                    }

                    NavigationLink(destination: HelpSupportView()) {
                        SettingsRow(icon: "questionmark.circle.fill", title: "Help & Support", color: .warning)
                    }

                    NavigationLink(destination: PrivacyPolicyView()) {
                        SettingsRow(icon: "hand.raised.fill", title: "Privacy Policy", color: .textSecondary)
                    }
                }
                .listRowBackground(Color.backgroundCard)

                // Danger zone
                Section {
                    Button {
                        Haptic.warning()
                        showDeleteConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "trash.fill")
                                .foregroundColor(.error)
                            Text("Delete Wallet")
                                .foregroundColor(.error)
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityLabel("Delete wallet")
                    .accessibilityHint("Double tap to permanently delete your wallet from this device")
                } footer: {
                    Text("Deleting your wallet removes all data from this device. Make sure you have your recovery phrase backed up.")
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                }
                .listRowBackground(Color.backgroundCard)
            }
            .scrollContentBackground(.hidden)
            .background(Color.backgroundPrimary)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .alert("Delete Wallet", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    try? walletService.deleteWallet()
                    router.resetToOnboarding()
                }
            } message: {
                Text("This will permanently delete your wallet from this device. This action cannot be undone. Make sure you have your recovery phrase.")
            }
        }
    }
}

// MARK: - Settings Row

struct HelpSupportView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section("Get Help") {
                supportLinkRow(
                    icon: "envelope.fill",
                    title: "Email Support",
                    subtitle: "support@anvilwallet.com",
                    urlString: "mailto:support@anvilwallet.com",
                    iconColor: .chainSolana
                )

                supportLinkRow(
                    icon: "globe",
                    title: "Support Center",
                    subtitle: "anvilwallet.com/support",
                    urlString: Bundle.main.object(forInfoDictionaryKey: "SupportURL") as? String ?? "https://anvilwallet.com/support",
                    iconColor: .info
                )
            }
            .listRowBackground(Color.backgroundCard)

            Section("Quick Tips") {
                tipRow(
                    icon: "externaldrive.badge.checkmark",
                    title: "Back up your recovery phrase",
                    body: "Store your recovery phrase offline and never share it with anyone."
                )

                tipRow(
                    icon: "hand.raised.slash.fill",
                    title: "Never share private keys",
                    body: "Anvil support will never ask for your recovery phrase or private keys."
                )

                tipRow(
                    icon: "checkmark.shield.fill",
                    title: "Report suspicious activity",
                    body: "If you see an unknown transaction or token approval, contact support immediately."
                )
            }
            .listRowBackground(Color.backgroundCard)
        }
        .scrollContentBackground(.hidden)
        .background(Color.backgroundPrimary)
        .navigationTitle("Help & Support")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func supportLinkRow(icon: String, title: String, subtitle: String, urlString: String, iconColor: Color) -> some View {
        Button {
            if let url = URL(string: urlString) {
                openURL(url)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundColor(iconColor)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundColor(.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundColor(.textTertiary)
            }
            .frame(minHeight: 44)
        }
    }

    private func tipRow(icon: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(.warning)
                Text(title)
                    .font(.body)
                    .foregroundColor(.textPrimary)
            }
            Text(body)
                .font(.caption)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

struct PrivacyPolicyView: View {
    var body: some View {
        List {
            Section {
                Text("Your privacy and control over your wallet data are core design principles of Anvil Wallet.")
                    .font(.body)
                    .foregroundColor(.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .listRowBackground(Color.backgroundCard)

            Section("Information We Store") {
                policyRow(
                    title: "On-device wallet data",
                    body: "Wallet accounts and related settings are stored locally on your device."
                )
                policyRow(
                    title: "Usage diagnostics",
                    body: "We may collect limited diagnostics to improve reliability and app quality."
                )
            }
            .listRowBackground(Color.backgroundCard)

            Section("How We Use Data") {
                policyRow(
                    title: "App functionality",
                    body: "Data is used to provide wallet features such as account management, signing, and settings."
                )
                policyRow(
                    title: "Security",
                    body: "Security checks may use device-level signals to protect against tampering or abuse."
                )
            }
            .listRowBackground(Color.backgroundCard)

            Section("Your Choices") {
                policyRow(
                    title: "Delete wallet",
                    body: "You can delete your wallet anytime from Settings. Keep your recovery phrase backed up first."
                )
                policyRow(
                    title: "Contact us",
                    body: "For privacy questions, contact support@anvilwallet.com."
                )
            }
            .listRowBackground(Color.backgroundCard)
        }
        .scrollContentBackground(.hidden)
        .background(Color.backgroundPrimary)
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func policyRow(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body)
                .foregroundColor(.textPrimary)
            Text(body)
                .font(.caption)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

struct SettingsRow: View {
    let icon: String
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(color)
                .frame(width: 28, height: 28)

            Text(title)
                .font(.body)
                .foregroundColor(.textPrimary)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

#Preview {
    SettingsView()
        .environmentObject(WalletService.shared)
        .environmentObject(AppRouter())
}
