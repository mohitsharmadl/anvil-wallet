import SwiftUI

/// Self-contained lock screen that shows biometric prompt, spinner, or password fallback.
/// Driven entirely by `SessionLockManager` state.
struct LockScreenView: View {
    @ObservedObject var manager: SessionLockManager

    private let biometricService = BiometricService()

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.backgroundPrimary)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "lock.circle.fill")
                    .font(.system(size: 52))
                    .foregroundColor(.accentGreen)

                Text("Session Locked")
                    .font(.title3.bold())
                    .foregroundColor(.textPrimary)

                if manager.showPasswordFallback {
                    passwordFallbackContent
                } else if manager.isUnlocking {
                    authenticatingContent
                } else {
                    biometricContent
                }
            }
            .padding(24)
            .background(Color.backgroundCard)
            .cornerRadius(16)
            .padding(24)
        }
        .task {
            await manager.attemptBiometricUnlock()
        }
    }

    // MARK: - Substates

    private var passwordFallbackContent: some View {
        VStack(spacing: 20) {
            Text("Enter your wallet password to continue.")
                .font(.body)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)

            SecureField("Password", text: $manager.unlockPassword)
                .font(.body)
                .padding(12)
                .background(Color.backgroundCard)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(manager.unlockError != nil ? Color.error : Color.border, lineWidth: 1)
                )

            if let errorMessage = manager.unlockError {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.error)
            }

            Button {
                Task { await manager.unlockWithPassword() }
            } label: {
                if manager.isUnlocking {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Unlock")
                }
            }
            .buttonStyle(PrimaryButtonStyle(isEnabled: !manager.unlockPassword.isEmpty))
            .disabled(manager.unlockPassword.isEmpty || manager.isUnlocking)
        }
    }

    private var authenticatingContent: some View {
        VStack(spacing: 20) {
            Text("Authenticating...")
                .font(.body)
                .foregroundColor(.textSecondary)

            ProgressView()
                .tint(.accentGreen)
        }
    }

    private var biometricContent: some View {
        VStack(spacing: 20) {
            Text("Unlock with \(biometricService.biometricName())")
                .font(.body)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await manager.unlockWithBiometrics() }
            } label: {
                Image(systemName: biometricService.biometricType() == .faceID ? "faceid" : "touchid")
                    .font(.system(size: 36))
                    .foregroundColor(.accentGreen)
            }

            Button("Use Password Instead") {
                manager.showPasswordFallback = true
            }
            .font(.caption)
            .foregroundColor(.textSecondary)
        }
    }
}
