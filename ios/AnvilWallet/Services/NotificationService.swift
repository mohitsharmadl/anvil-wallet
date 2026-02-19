import Foundation
import UserNotifications

/// NotificationService manages local push notifications for transaction events.
///
/// Responsibilities:
///   - Request notification permissions via UNUserNotificationCenter
///   - Schedule local notifications for confirmed txs, incoming transfers, unlimited approvals
///   - Deduplicate notifications using a persisted set of "already notified" tx hashes
///   - Maintain an in-app notification history (last 50 entries)
///   - Badge count management
///
/// This is LOCAL notifications only -- no APNs, no server, no push certificates.
final class NotificationService: ObservableObject {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()

    // MARK: - Settings Keys

    private let enabledKey = "notification.enabled"
    private let confirmationsEnabledKey = "notification.confirmations"
    private let incomingEnabledKey = "notification.incoming"
    private let approvalsEnabledKey = "notification.approvals"
    private let notifiedHashesKey = "notification.notifiedHashes"
    private let historyKey = "notification.history"

    // MARK: - Published State

    /// Whether notifications are globally enabled.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: enabledKey) }
    }

    /// Per-category toggles.
    @Published var confirmationsEnabled: Bool {
        didSet { UserDefaults.standard.set(confirmationsEnabled, forKey: confirmationsEnabledKey) }
    }

    @Published var incomingEnabled: Bool {
        didSet { UserDefaults.standard.set(incomingEnabled, forKey: incomingEnabledKey) }
    }

    @Published var approvalsEnabled: Bool {
        didSet { UserDefaults.standard.set(approvalsEnabled, forKey: approvalsEnabledKey) }
    }

    /// In-app notification history (last 50).
    @Published var history: [NotificationEntry] = []

    /// Count of unread notifications.
    var unreadCount: Int {
        history.filter { !$0.isRead }.count
    }

    // MARK: - Private State

    /// Set of tx hashes (or unique identifiers) we have already notified about.
    private var notifiedHashes: Set<String>

    private init() {
        let defaults = UserDefaults.standard

        // Load settings (defaults: all on)
        self.isEnabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        self.confirmationsEnabled = defaults.object(forKey: confirmationsEnabledKey) as? Bool ?? true
        self.incomingEnabled = defaults.object(forKey: incomingEnabledKey) as? Bool ?? true
        self.approvalsEnabled = defaults.object(forKey: approvalsEnabledKey) as? Bool ?? true

        // Load notified hashes
        let savedHashes = defaults.stringArray(forKey: notifiedHashesKey) ?? []
        self.notifiedHashes = Set(savedHashes)

        // Load history
        if let data = defaults.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([NotificationEntry].self, from: data) {
            self.history = decoded
        }
    }

    // MARK: - Permission

    /// Requests notification authorization. Call once after onboarding or on first launch.
    func requestPermission() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                await MainActor.run {
                    self.isEnabled = true
                }
            }
        } catch {
            // Non-fatal -- user denied or error
        }
    }

    /// Checks current authorization status.
    func checkPermissionStatus() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized
    }

    // MARK: - Transaction Confirmed

    /// Called when a previously-pending transaction now appears as confirmed.
    /// - Parameters:
    ///   - txHash: The transaction hash
    ///   - tokenSymbol: e.g. "ETH", "BTC"
    ///   - amount: Human-readable amount string
    ///   - chain: Chain display name
    func notifyTransactionConfirmed(txHash: String, tokenSymbol: String, amount: String, chain: String) {
        guard isEnabled, confirmationsEnabled else { return }
        guard !hasNotified(txHash, suffix: "confirmed") else { return }

        let title = "Transaction Confirmed"
        let body = "\(amount) \(tokenSymbol) on \(chain) has been confirmed."

        scheduleNotification(
            id: "tx-confirmed-\(txHash.prefix(16))",
            title: title,
            body: body,
            category: .transactionConfirmed
        )
        markNotified(txHash, suffix: "confirmed")
    }

    // MARK: - Incoming Transfer

    /// Called when a new inbound transaction is detected that wasn't previously seen.
    /// - Parameters:
    ///   - txHash: The transaction hash
    ///   - tokenSymbol: e.g. "ETH", "SOL"
    ///   - amount: Human-readable amount string
    ///   - from: Sender address (shortened)
    ///   - chain: Chain display name
    func notifyIncomingTransfer(txHash: String, tokenSymbol: String, amount: String, from: String, chain: String) {
        guard isEnabled, incomingEnabled else { return }
        guard !hasNotified(txHash, suffix: "incoming") else { return }

        let shortFrom = shortenAddress(from)
        let title = "Incoming Transfer"
        let body = "Received \(amount) \(tokenSymbol) from \(shortFrom) on \(chain)."

        scheduleNotification(
            id: "tx-incoming-\(txHash.prefix(16))",
            title: title,
            body: body,
            category: .incomingTransfer
        )
        markNotified(txHash, suffix: "incoming")
    }

    // MARK: - Unlimited Approval

    /// Called when a new unlimited ERC-20 approval is detected.
    /// - Parameters:
    ///   - txHash: The approval transaction hash
    ///   - tokenSymbol: The token being approved
    ///   - spender: The spender address
    ///   - chain: Chain display name
    func notifyUnlimitedApproval(txHash: String, tokenSymbol: String, spender: String, chain: String) {
        guard isEnabled, approvalsEnabled else { return }
        guard !hasNotified(txHash, suffix: "approval") else { return }

        let shortSpender = shortenAddress(spender)
        let title = "Unlimited Approval Detected"
        let body = "Unlimited \(tokenSymbol) approval granted to \(shortSpender) on \(chain)."

        scheduleNotification(
            id: "approval-\(txHash.prefix(16))",
            title: title,
            body: body,
            category: .approvalAlert
        )
        markNotified(txHash, suffix: "approval")
    }

    // MARK: - History Management

    /// Marks a single notification entry as read.
    func markAsRead(_ entryId: UUID) {
        if let index = history.firstIndex(where: { $0.id == entryId }) {
            history[index].isRead = true
            persistHistory()
            updateBadge()
        }
    }

    /// Marks all entries as read.
    func markAllAsRead() {
        for index in history.indices {
            history[index].isRead = true
        }
        persistHistory()
        updateBadge()
    }

    /// Clears all notification history.
    func clearHistory() {
        history.removeAll()
        persistHistory()
        updateBadge()
    }

    /// Clears all persisted state (e.g. on wallet deletion).
    func clearAll() {
        history.removeAll()
        notifiedHashes.removeAll()
        persistHistory()
        persistNotifiedHashes()
        updateBadge()
    }

    // MARK: - Private Helpers

    private func scheduleNotification(id: String, title: String, body: String, category: NotificationCategory) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category.rawValue

        // Fire immediately (1 second delay for local notification)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        center.add(request) { _ in
            // Fire and forget -- non-fatal if delivery fails
        }

        // Add to in-app history
        let entry = NotificationEntry(
            id: UUID(),
            title: title,
            body: body,
            category: category,
            timestamp: Date(),
            isRead: false
        )

        Task { @MainActor in
            self.history.insert(entry, at: 0)
            // Keep last 50
            if self.history.count > 50 {
                self.history = Array(self.history.prefix(50))
            }
            self.persistHistory()
            self.updateBadge()
        }
    }

    private func hasNotified(_ hash: String, suffix: String) -> Bool {
        notifiedHashes.contains("\(hash.lowercased())_\(suffix)")
    }

    private func markNotified(_ hash: String, suffix: String) {
        let key = "\(hash.lowercased())_\(suffix)"
        notifiedHashes.insert(key)

        // Prune if set grows too large (keep last 500)
        if notifiedHashes.count > 500 {
            let sorted = notifiedHashes.sorted()
            notifiedHashes = Set(sorted.suffix(500))
        }

        persistNotifiedHashes()
    }

    private func persistNotifiedHashes() {
        UserDefaults.standard.set(Array(notifiedHashes), forKey: notifiedHashesKey)
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    private func updateBadge() {
        let count = unreadCount
        Task {
            try? await center.setBadgeCount(count)
        }
    }

    private func shortenAddress(_ addr: String) -> String {
        guard addr.count > 12 else { return addr }
        return "\(addr.prefix(6))...\(addr.suffix(4))"
    }
}

// MARK: - Notification Category

enum NotificationCategory: String, Codable {
    case transactionConfirmed = "TX_CONFIRMED"
    case incomingTransfer = "INCOMING_TRANSFER"
    case approvalAlert = "APPROVAL_ALERT"

    var icon: String {
        switch self {
        case .transactionConfirmed: return "checkmark.circle.fill"
        case .incomingTransfer: return "arrow.down.left.circle.fill"
        case .approvalAlert: return "exclamationmark.shield.fill"
        }
    }

    var color: String {
        switch self {
        case .transactionConfirmed: return "success"
        case .incomingTransfer: return "info"
        case .approvalAlert: return "warning"
        }
    }
}

// MARK: - Notification Entry

struct NotificationEntry: Identifiable, Codable {
    let id: UUID
    let title: String
    let body: String
    let category: NotificationCategory
    let timestamp: Date
    var isRead: Bool
}
