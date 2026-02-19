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

                    Button {
                        // TODO: Open support URL
                    } label: {
                        SettingsRow(icon: "questionmark.circle.fill", title: "Help & Support", color: .warning)
                    }

                    Button {
                        // TODO: Open privacy policy
                    } label: {
                        SettingsRow(icon: "hand.raised.fill", title: "Privacy Policy", color: .textSecondary)
                    }
                }
                .listRowBackground(Color.backgroundCard)

                // Danger zone
                Section {
                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "trash.fill")
                                .foregroundColor(.error)
                            Text("Delete Wallet")
                                .foregroundColor(.error)
                        }
                    }
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
    }
}

#Preview {
    SettingsView()
        .environmentObject(WalletService.shared)
        .environmentObject(AppRouter())
}
