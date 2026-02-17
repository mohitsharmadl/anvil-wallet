import Foundation
import UIKit

/// ClipboardManager provides secure clipboard operations for the wallet.
///
/// Security concerns with clipboard:
///   - Malicious apps can read the clipboard in the background
///   - Clipboard data persists until overwritten
///   - Universal Clipboard syncs across Apple devices (which we want to avoid for keys)
///
/// Our approach:
///   - Auto-clear clipboard after 120 seconds
///   - Set localOnly flag to prevent Universal Clipboard sync
///   - Provide feedback to the user when copying sensitive data
final class ClipboardManager {

    static let shared = ClipboardManager()

    private var clearTimer: Timer?
    private let clearDelay: TimeInterval = 120 // 2 minutes

    private init() {}

    /// Copies text to the clipboard and schedules auto-clear after 120 seconds.
    ///
    /// - Parameters:
    ///   - text: The text to copy
    ///   - sensitive: If true, marks as local-only (no Universal Clipboard sync)
    func copyToClipboard(_ text: String, sensitive: Bool = true) {
        if sensitive {
            // Use expiring pasteboard item that doesn't sync across devices
            let item: [String: Any] = [
                UIPasteboard.typeAutomatic: text,
            ]

            let options: [UIPasteboard.OptionsKey: Any] = [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(clearDelay),
            ]

            UIPasteboard.general.setItems([item], options: options)
        } else {
            UIPasteboard.general.string = text
        }

        // Schedule auto-clear as a backup
        scheduleClear()
    }

    /// Immediately clears the clipboard.
    func clearClipboard() {
        UIPasteboard.general.string = ""
        UIPasteboard.general.items = []
        clearTimer?.invalidate()
        clearTimer = nil
    }

    // MARK: - Private

    private func scheduleClear() {
        clearTimer?.invalidate()
        clearTimer = Timer.scheduledTimer(
            withTimeInterval: clearDelay,
            repeats: false
        ) { [weak self] _ in
            self?.clearClipboard()
        }
    }
}
