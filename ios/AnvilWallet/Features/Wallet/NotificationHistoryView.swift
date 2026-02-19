import SwiftUI

/// NotificationHistoryView shows a chronological list of recent in-app notifications
/// (last 50 entries). Each entry can be tapped to mark as read. A "Clear All" button
/// removes all history.
///
/// Wired to the notification bell icon in WalletHomeView.
struct NotificationHistoryView: View {
    @ObservedObject private var notificationService = NotificationService.shared

    var body: some View {
        VStack(spacing: 0) {
            if notificationService.history.isEmpty {
                emptyState
            } else {
                notificationList
            }
        }
        .background(Color.backgroundPrimary)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !notificationService.history.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            notificationService.markAllAsRead()
                        } label: {
                            Label("Mark All as Read", systemImage: "envelope.open")
                        }

                        Button(role: .destructive) {
                            notificationService.clearHistory()
                        } label: {
                            Label("Clear All", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.body.weight(.medium))
                            .foregroundColor(.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "bell.slash")
                .font(.system(size: 56))
                .foregroundColor(.textTertiary)

            Text("No Notifications")
                .font(.title3.bold())
                .foregroundColor(.textPrimary)

            Text("Transaction confirmations, incoming transfers, and approval alerts will appear here.")
                .font(.body)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Notification List

    private var notificationList: some View {
        List {
            ForEach(notificationService.history) { entry in
                NotificationRowView(entry: entry)
                    .listRowBackground(
                        entry.isRead ? Color.backgroundPrimary : Color.backgroundCard
                    )
                    .listRowSeparatorTint(Color.separator)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        notificationService.markAsRead(entry.id)
                    }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Notification Row

private struct NotificationRowView: View {
    let entry: NotificationEntry

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: entry.timestamp, relativeTo: Date())
    }

    private var iconColor: Color {
        switch entry.category.color {
        case "success": return .success
        case "info": return .info
        case "warning": return .warning
        default: return .textSecondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Category icon
            Image(systemName: entry.category.icon)
                .font(.body.bold())
                .foregroundColor(iconColor)
                .frame(width: 40, height: 40)
                .background(iconColor.opacity(0.1))
                .cornerRadius(12)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.title)
                        .font(.subheadline.bold())
                        .foregroundColor(.textPrimary)

                    Spacer()

                    Text(relativeTime)
                        .font(.caption2)
                        .foregroundColor(.textTertiary)
                }

                Text(entry.body)
                    .font(.caption)
                    .foregroundColor(.textSecondary)
                    .lineLimit(2)
            }

            // Unread indicator
            if !entry.isRead {
                Circle()
                    .fill(Color.accentGreen)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        NotificationHistoryView()
    }
}
