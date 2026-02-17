import Foundation
import LocalAuthentication

/// BiometricService wraps the LocalAuthentication framework to provide
/// Face ID and Touch ID authentication for the wallet.
final class BiometricService {

    enum BiometricType {
        case none
        case faceID
        case touchID
        case opticID
    }

    enum BiometricError: LocalizedError {
        case notAvailable
        case notEnrolled
        case authenticationFailed
        case userCancelled
        case systemCancelled
        case unknown(String)

        var errorDescription: String? {
            switch self {
            case .notAvailable:
                return "Biometric authentication is not available on this device."
            case .notEnrolled:
                return "No biometrics are enrolled. Please set up Face ID or Touch ID in Settings."
            case .authenticationFailed:
                return "Biometric authentication failed."
            case .userCancelled:
                return "Authentication was cancelled."
            case .systemCancelled:
                return "Authentication was cancelled by the system."
            case .unknown(let message):
                return "Authentication error: \(message)"
            }
        }
    }

    // MARK: - Availability

    /// Checks whether biometric authentication is available and enrolled.
    func canUseBiometrics() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Returns the type of biometric authentication available on this device.
    func biometricType() -> BiometricType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }

        switch context.biometryType {
        case .faceID:
            return .faceID
        case .touchID:
            return .touchID
        case .opticID:
            return .opticID
        case .none:
            return .none
        @unknown default:
            return .none
        }
    }

    /// Returns a human-readable name for the current biometric type.
    func biometricName() -> String {
        switch biometricType() {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .none: return "Passcode"
        }
    }

    // MARK: - Authentication

    /// Performs biometric authentication with the given reason string.
    ///
    /// - Parameter reason: The reason displayed to the user in the authentication dialog
    /// - Returns: true if authentication succeeded
    func authenticate(reason: String) async throws -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            if let laError = error as? LAError {
                throw mapLAError(laError)
            }
            throw BiometricError.notAvailable
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            return success
        } catch let error as LAError {
            throw mapLAError(error)
        }
    }

    /// Performs device owner authentication (biometric or passcode fallback).
    ///
    /// - Parameter reason: The reason displayed to the user
    /// - Returns: true if authentication succeeded
    func authenticateWithPasscodeFallback(reason: String) async throws -> Bool {
        let context = LAContext()

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            return success
        } catch let error as LAError {
            throw mapLAError(error)
        }
    }

    // MARK: - Private

    private func mapLAError(_ error: LAError) -> BiometricError {
        switch error.code {
        case .biometryNotAvailable:
            return .notAvailable
        case .biometryNotEnrolled:
            return .notEnrolled
        case .authenticationFailed:
            return .authenticationFailed
        case .userCancel, .appCancel:
            return .userCancelled
        case .systemCancel:
            return .systemCancelled
        default:
            return .unknown(error.localizedDescription)
        }
    }
}
