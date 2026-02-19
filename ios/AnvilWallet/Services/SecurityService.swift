import Foundation
import SwiftUI
import UIKit
import os.log

/// SecurityService is the central coordinator for runtime security features.
///
/// Responsibilities:
///   - Biometric rate limiting with exponential backoff
///   - Clipboard auto-clear with configurable timeout
///   - Jailbreak detection status (delegates to JailbreakDetector)
///   - Screen protection blur for app switcher
///
/// Singleton accessed via `SecurityService.shared`. Published properties
/// drive UI updates in SecuritySettingsView and AnvilWalletApp.
final class SecurityService: ObservableObject {

    static let shared = SecurityService()

    private let logger = Logger(subsystem: "com.anvilwallet", category: "SecurityService")

    // MARK: - Published State

    /// Whether the screen protection blur is currently showing (app in background).
    @Published var isScreenProtectionActive = false

    // MARK: - User Preferences (persisted via UserDefaults)

    /// Auto-clear clipboard after copying sensitive data. Default: on.
    @Published var isAutoClearClipboardEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoClearClipboardEnabled, forKey: Keys.autoClearClipboard)
        }
    }

    /// Blur the app content in the app switcher. Default: on.
    @Published var isScreenProtectionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isScreenProtectionEnabled, forKey: Keys.screenProtection)
        }
    }

    // MARK: - Biometric Rate Limiting

    /// Maximum consecutive failed biometric attempts before lockout.
    private let maxFailedAttempts = 5

    /// Base lockout duration in seconds (5 minutes).
    private let baseLockoutDuration: TimeInterval = 300

    /// Current count of consecutive failed biometric attempts.
    private(set) var failedBiometricAttempts: Int {
        get { UserDefaults.standard.integer(forKey: Keys.failedBiometricAttempts) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.failedBiometricAttempts) }
    }

    /// Timestamp when the current lockout expires. Nil if not locked out.
    private(set) var lockoutEndDate: Date? {
        get {
            let interval = UserDefaults.standard.double(forKey: Keys.lockoutEndDate)
            return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
        }
        set {
            if let date = newValue {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Keys.lockoutEndDate)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.lockoutEndDate)
            }
        }
    }

    /// Number of completed lockout cycles (for exponential backoff).
    private(set) var lockoutCycleCount: Int {
        get { UserDefaults.standard.integer(forKey: Keys.lockoutCycleCount) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lockoutCycleCount) }
    }

    // MARK: - Clipboard

    /// Timer for auto-clearing the clipboard.
    private var clipboardClearTimer: Timer?

    /// Duration before clipboard is auto-cleared (60 seconds).
    private let clipboardClearDelay: TimeInterval = 60

    // MARK: - Jailbreak

    /// Cached jailbreak detection result from SecurityBootstrap.
    @MainActor
    var isJailbroken: Bool {
        SecurityBootstrap.jailbreakDetected
    }

    // MARK: - Init

    private init() {
        // Load persisted preferences (default to enabled)
        let defaults = UserDefaults.standard

        // Register defaults so first launch gets "on"
        defaults.register(defaults: [
            Keys.autoClearClipboard: true,
            Keys.screenProtection: true,
        ])

        self.isAutoClearClipboardEnabled = defaults.bool(forKey: Keys.autoClearClipboard)
        self.isScreenProtectionEnabled = defaults.bool(forKey: Keys.screenProtection)
    }

    // MARK: - Biometric Rate Limiting

    /// Whether biometric authentication is currently locked out due to too many failures.
    var isBiometricLockedOut: Bool {
        guard let endDate = lockoutEndDate else { return false }
        if Date() < endDate {
            return true
        }
        // Lockout expired — clear it
        lockoutEndDate = nil
        return false
    }

    /// Remaining seconds until lockout expires. Returns 0 if not locked out.
    var lockoutRemainingSeconds: TimeInterval {
        guard let endDate = lockoutEndDate else { return 0 }
        return max(0, endDate.timeIntervalSinceNow)
    }

    /// Records a failed biometric attempt. If the threshold is reached,
    /// triggers a lockout with exponential backoff.
    func recordBiometricFailure() {
        failedBiometricAttempts += 1
        logger.warning("Biometric failure #\(self.failedBiometricAttempts)")

        if failedBiometricAttempts >= maxFailedAttempts {
            // Exponential backoff: 5 min * 2^cycleCount (5m, 10m, 20m, 40m, ...)
            let multiplier = pow(2.0, Double(lockoutCycleCount))
            let lockoutDuration = baseLockoutDuration * multiplier
            lockoutEndDate = Date().addingTimeInterval(lockoutDuration)
            lockoutCycleCount += 1

            logger.warning("Biometric lockout triggered: \(lockoutDuration)s (cycle \(self.lockoutCycleCount))")
        }
    }

    /// Records a successful biometric authentication. Resets the failure counter
    /// and lockout cycle count.
    func recordBiometricSuccess() {
        failedBiometricAttempts = 0
        lockoutCycleCount = 0
        lockoutEndDate = nil
    }

    /// Formatted lockout remaining time (e.g. "4:32").
    var lockoutRemainingFormatted: String {
        let remaining = lockoutRemainingSeconds
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Clipboard Auto-Clear

    /// Copies a string to the clipboard and schedules auto-clear after 60 seconds.
    ///
    /// If the user copies something new before the timer fires, the timer restarts.
    /// When `isAutoClearClipboardEnabled` is off, copies normally without scheduling.
    ///
    /// - Parameters:
    ///   - string: The text to copy
    ///   - sensitive: If true, marks as local-only (no Universal Clipboard sync)
    func copyWithAutoClear(_ string: String, sensitive: Bool = true) {
        if sensitive {
            // Local-only pasteboard item — no Universal Clipboard sync
            let item: [String: Any] = [
                UIPasteboard.typeAutomatic: string,
            ]
            let options: [UIPasteboard.OptionsKey: Any] = [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(clipboardClearDelay),
            ]
            UIPasteboard.general.setItems([item], options: options)
        } else {
            UIPasteboard.general.string = string
        }

        // Schedule auto-clear (invalidates any existing timer first)
        if isAutoClearClipboardEnabled {
            scheduleClipboardClear()
        }
    }

    /// Immediately clears the clipboard and cancels any pending auto-clear timer.
    func clearClipboard() {
        UIPasteboard.general.string = ""
        UIPasteboard.general.items = []
        clipboardClearTimer?.invalidate()
        clipboardClearTimer = nil
    }

    private func scheduleClipboardClear() {
        // Invalidate existing timer (restart on new copy)
        clipboardClearTimer?.invalidate()
        clipboardClearTimer = Timer.scheduledTimer(
            withTimeInterval: clipboardClearDelay,
            repeats: false
        ) { [weak self] _ in
            self?.clearClipboard()
            self?.logger.info("Clipboard auto-cleared after timeout")
        }
    }

    // MARK: - Screen Protection

    /// Call when the app enters background to activate screen protection blur.
    func activateScreenProtection() {
        guard isScreenProtectionEnabled else { return }
        isScreenProtectionActive = true
    }

    /// Call when the app returns to foreground to remove screen protection blur.
    func deactivateScreenProtection() {
        isScreenProtectionActive = false
    }

    // MARK: - Jailbreak Detection

    /// Performs a fresh jailbreak check and returns the result.
    /// For cached result, use `isJailbroken` property instead.
    func checkJailbreak() -> JailbreakDetector.DetectionResult {
        JailbreakDetector.check()
    }
}

// MARK: - UserDefaults Keys

private extension SecurityService {
    enum Keys {
        static let autoClearClipboard = "security.autoClearClipboard"
        static let screenProtection = "security.screenProtection"
        static let failedBiometricAttempts = "security.failedBiometricAttempts"
        static let lockoutEndDate = "security.lockoutEndDate"
        static let lockoutCycleCount = "security.lockoutCycleCount"
    }
}
