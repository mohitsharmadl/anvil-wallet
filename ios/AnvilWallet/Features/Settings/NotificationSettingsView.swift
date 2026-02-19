import SwiftUI

/// NotificationSettingsView lets users toggle notification preferences
/// on a per-category basis. All state is persisted via NotificationService
/// which uses UserDefaults under the hood.
struct NotificationSettingsView: View {
    @ObservedObject private var notificationService = NotificationService.shared

    @State private var systemPermissionGranted = false
    @State private var hasCheckedPermission = false

    var body: some View {
        List {
            // System permission status
            Section {
                HStack(spacing: 12) {
                    Image(systemName: systemPermissionGranted ? "bell.badge.fill" : "bell.slash.fill")
                        .font(.title2)
                        .foregroundColor(systemPermissionGranted ? .accentGreen : .textTertiary)
                        .frame(width: 44, height: 44)
                        .background(
                            (systemPermissionGranted ? Color.accentGreen : Color.textTertiary).opacity(0.1)
                        )
                        .cornerRadius(12)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(systemPermissionGranted ? "Notifications Enabled" : "Notifications Disabled")
                            .font(.headline)
                            .foregroundColor(.textPrimary)

                        Text(systemPermissionGranted
                             ? "You will receive alerts for wallet activity."
                             : "Enable notifications in Settings to receive alerts.")
                            .font(.caption)
                            .foregroundColor(.textSecondary)
                    }
                }

                if !systemPermissionGranted && hasCheckedPermission {
                    Button {
                        openSystemSettings()
                    } label: {
                        HStack {
                            Image(systemName: "gear")
                                .foregroundColor(.accentGreen)
                            Text("Open System Settings")
                                .foregroundColor(.accentGreen)
                        }
                    }
                }
            }
            .listRowBackground(Color.backgroundCard)

            // Master toggle
            Section("General") {
                Toggle(isOn: $notificationService.isEnabled) {
                    SettingsRow(
                        icon: "bell.fill",
                        title: "Enable Notifications",
                        color: .accentGreen
                    )
                }
                .tint(.accentGreen)
            }
            .listRowBackground(Color.backgroundCard)

            // Per-category toggles
            Section("Categories") {
                Toggle(isOn: $notificationService.confirmationsEnabled) {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.body)
                            .foregroundColor(.success)
                            .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Transaction Confirmations")
                                .font(.body)
                                .foregroundColor(.textPrimary)

                            Text("When a pending transaction is confirmed on-chain")
                                .font(.caption)
                                .foregroundColor(.textSecondary)
                        }
                    }
                }
                .tint(.accentGreen)
                .disabled(!notificationService.isEnabled)

                Toggle(isOn: $notificationService.incomingEnabled) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.down.left.circle.fill")
                            .font(.body)
                            .foregroundColor(.info)
                            .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Incoming Transfers")
                                .font(.body)
                                .foregroundColor(.textPrimary)

                            Text("When you receive tokens from another address")
                                .font(.caption)
                                .foregroundColor(.textSecondary)
                        }
                    }
                }
                .tint(.accentGreen)
                .disabled(!notificationService.isEnabled)

                Toggle(isOn: $notificationService.approvalsEnabled) {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.body)
                            .foregroundColor(.warning)
                            .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Approval Alerts")
                                .font(.body)
                                .foregroundColor(.textPrimary)

                            Text("When an unlimited ERC-20 approval is detected")
                                .font(.caption)
                                .foregroundColor(.textSecondary)
                        }
                    }
                }
                .tint(.accentGreen)
                .disabled(!notificationService.isEnabled)
            }
            .listRowBackground(Color.backgroundCard)

            // History management
            Section("History") {
                Button {
                    notificationService.markAllAsRead()
                } label: {
                    SettingsRow(icon: "envelope.open.fill", title: "Mark All as Read", color: .info)
                }
                .disabled(notificationService.unreadCount == 0)

                Button {
                    notificationService.clearHistory()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "trash.fill")
                            .font(.body)
                            .foregroundColor(.error)
                            .frame(width: 28, height: 28)

                        Text("Clear Notification History")
                            .font(.body)
                            .foregroundColor(.error)
                    }
                }
                .disabled(notificationService.history.isEmpty)
            }
            .listRowBackground(Color.backgroundCard)
        }
        .scrollContentBackground(.hidden)
        .background(Color.backgroundPrimary)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            systemPermissionGranted = await notificationService.checkPermissionStatus()
            hasCheckedPermission = true
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

#Preview {
    NavigationStack {
        NotificationSettingsView()
    }
}
