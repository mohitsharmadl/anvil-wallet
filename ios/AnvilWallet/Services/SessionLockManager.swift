import Foundation
import SwiftUI

// MARK: - Session Lock Delegate

/// Protocol that the host app implements to integrate session lock with its own
/// password validation and post-unlock logic.
protocol SessionLockDelegate: AnyObject {
    /// Validate a user-entered password. Throw if incorrect.
    func validatePassword(_ password: String) async throws
    /// Called after a successful unlock (biometric or password).
    func didUnlock() async
}

// MARK: - Session Lock Manager

/// Owns all session-lock state and logic: auto-lock timer, Face ID auto-unlock,
/// password fallback, and biometric Keychain storage.
///
/// Usage in the host app:
///   1. Set `delegate` to your service that validates passwords.
///   2. Call `handleScenePhase(_:)` from `.onChange(of: scenePhase)`.
///   3. Show `LockScreenView(manager:)` when `isLocked` is true.
final class SessionLockManager: ObservableObject {
    static let shared = SessionLockManager()

    // MARK: - Published State

    @Published var isLocked = false
    @Published var isUnlocking = false
    @Published var unlockError: String?
    @Published var showPasswordFallback = false
    @Published var unlockPassword = ""

    // MARK: - Settings (persisted via UserDefaults)

    var autoLockInterval: AutoLockInterval {
        get {
            let raw = UserDefaults.standard.string(forKey: "autoLockInterval")
                ?? AutoLockInterval.fiveMinutes.rawValue
            return AutoLockInterval(rawValue: raw) ?? .fiveMinutes
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: "autoLockInterval")
        }
    }

    // MARK: - Delegate

    weak var delegate: SessionLockDelegate?

    // MARK: - Private

    private let keychain = KeychainService()
    private let biometric = BiometricService()
    private let biometricPasswordKey = "com.anvilwallet.biometricPassword"

    private var backgroundedAt: Date?
    private var inactivatedAt: Date?
    private var biometricAttempted = false

    private init() {}

    // MARK: - Lock / Unlock

    /// Locks the session immediately, clearing transient UI state.
    func lock() {
        isLocked = true
        unlockPassword = ""
        unlockError = nil
        showPasswordFallback = false
        biometricAttempted = false
    }

    /// Unlocks using the password entered in `unlockPassword`.
    /// Validates via delegate, saves to biometric Keychain on success.
    func unlockWithPassword() async {
        await MainActor.run {
            isUnlocking = true
            unlockError = nil
        }
        do {
            try await delegate?.validatePassword(unlockPassword)
            savePasswordForBiometrics(unlockPassword)
            await MainActor.run {
                isLocked = false
                isUnlocking = false
                unlockPassword = ""
                unlockError = nil
            }
            await delegate?.didUnlock()
        } catch {
            await MainActor.run {
                isUnlocking = false
                unlockError = error.localizedDescription
            }
        }
    }

    /// Unlocks using Face ID / Touch ID via biometric-protected Keychain.
    func unlockWithBiometrics() async {
        await MainActor.run {
            isUnlocking = true
            unlockError = nil
        }
        do {
            guard let passwordData = try keychain.load(key: biometricPasswordKey),
                  let password = String(data: passwordData, encoding: .utf8) else {
                await MainActor.run {
                    isUnlocking = false
                    showPasswordFallback = true
                }
                return
            }
            try await delegate?.validatePassword(password)
            await MainActor.run {
                isLocked = false
                isUnlocking = false
                unlockPassword = ""
                unlockError = nil
            }
            await delegate?.didUnlock()
        } catch {
            await MainActor.run {
                isUnlocking = false
                showPasswordFallback = true
            }
        }
    }

    /// Auto-triggers Face ID if biometric password is available.
    /// Called from LockScreenView's `.task` modifier.
    func attemptBiometricUnlock() async {
        guard !biometricAttempted else { return }
        await MainActor.run { biometricAttempted = true }

        guard biometric.canUseBiometrics(),
              SecurityService.shared.isBiometricAuthEnabled,
              hasBiometricPassword else {
            await MainActor.run { showPasswordFallback = true }
            return
        }

        await unlockWithBiometrics()
    }

    // MARK: - Scene Phase Handling

    /// Call from `.onChange(of: scenePhase)` to manage auto-lock timing.
    /// Screen protection (blur overlay) is NOT handled here — keep that in the app.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .inactive:
            inactivatedAt = Date()
        case .background:
            backgroundedAt = Date()
        case .active:
            if !isLocked, !isUnlocking,
               let leftAppAt = backgroundedAt ?? inactivatedAt {
                let elapsed = Date().timeIntervalSince(leftAppAt)
                let interval = autoLockInterval.seconds
                if interval >= 0, elapsed >= interval {
                    lock()
                }
            }
            backgroundedAt = nil
            inactivatedAt = nil
        @unknown default:
            break
        }
    }

    // MARK: - Biometric Password Storage

    /// Saves the password to biometric-protected Keychain for Face ID unlock.
    func savePasswordForBiometrics(_ password: String) {
        guard let data = password.data(using: .utf8) else { return }
        try? keychain.saveWithBiometricProtection(key: biometricPasswordKey, data: data)
    }

    /// Whether a biometric-stored password exists.
    var hasBiometricPassword: Bool {
        keychain.exists(key: biometricPasswordKey)
    }

    /// Clears the biometric-protected password.
    func clearBiometricPassword() {
        try? keychain.delete(key: biometricPasswordKey)
    }
}
