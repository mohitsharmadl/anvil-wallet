import SwiftUI

/// SetPasswordView collects the user's encryption password during wallet creation or import.
///
/// Password requirements:
///   - Minimum 8 characters
///   - Must contain at least one uppercase letter
///   - Must contain at least one number
///   - Must contain at least one special character
///
/// The password is used by the Rust core's Argon2id KDF to derive an encryption key
/// for the wallet seed. It is never stored anywhere -- only its derived key is used.
struct SetPasswordView: View {
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var walletService: WalletService

    let mnemonic: String // Empty for new wallet, populated for import

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var passphrase = ""
    @State private var isPassphraseVisible = false
    @State private var isPasswordVisible = false
    @State private var isConfirmVisible = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var isNewWallet: Bool { mnemonic.isEmpty }

    private var passwordStrength: PasswordStrength {
        PasswordStrength.evaluate(password)
    }

    private var passwordsMatch: Bool {
        !confirmPassword.isEmpty && password == confirmPassword
    }

    private var canProceed: Bool {
        passwordStrength.meetsMinimum && passwordsMatch
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.accentGreen)

                    Text("Set Your Password")
                        .font(.title3.bold())
                        .foregroundColor(.textPrimary)

                    Text("This password encrypts your wallet on this device. Choose something strong and memorable.")
                        .font(.body)
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 16)

                // Password input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Password")
                        .font(.subheadline.bold())
                        .foregroundColor(.textSecondary)

                    HStack {
                        Group {
                            if isPasswordVisible {
                                TextField("Enter password", text: $password)
                            } else {
                                SecureField("Enter password", text: $password)
                            }
                        }
                        .font(.body)
                        .foregroundColor(.textPrimary)

                        Button {
                            isPasswordVisible.toggle()
                        } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                                .foregroundColor(.textTertiary)
                        }
                    }
                    .padding(12)
                    .background(Color.backgroundCard)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.border, lineWidth: 1)
                    )

                    // Password strength indicator
                    PasswordStrengthView(strength: passwordStrength)
                }
                .padding(.horizontal, 24)

                // Confirm password
                VStack(alignment: .leading, spacing: 8) {
                    Text("Confirm Password")
                        .font(.subheadline.bold())
                        .foregroundColor(.textSecondary)

                    HStack {
                        Group {
                            if isConfirmVisible {
                                TextField("Confirm password", text: $confirmPassword)
                            } else {
                                SecureField("Confirm password", text: $confirmPassword)
                            }
                        }
                        .font(.body)
                        .foregroundColor(.textPrimary)

                        Button {
                            isConfirmVisible.toggle()
                        } label: {
                            Image(systemName: isConfirmVisible ? "eye.slash.fill" : "eye.fill")
                                .foregroundColor(.textTertiary)
                        }
                    }
                    .padding(12)
                    .background(Color.backgroundCard)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                confirmPassword.isEmpty ? Color.border : (passwordsMatch ? Color.success : Color.error),
                                lineWidth: 1
                            )
                    )

                    if !confirmPassword.isEmpty && !passwordsMatch {
                        Text("Passwords do not match")
                            .font(.caption)
                            .foregroundColor(.error)
                    }
                }
                .padding(.horizontal, 24)

                // Optional BIP-39 passphrase (25th word)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recovery Passphrase (Optional)")
                        .font(.subheadline.bold())
                        .foregroundColor(.textSecondary)

                    HStack {
                        Group {
                            if isPassphraseVisible {
                                TextField("Optional 25th word", text: $passphrase)
                            } else {
                                SecureField("Optional 25th word", text: $passphrase)
                            }
                        }
                        .font(.body)
                        .foregroundColor(.textPrimary)

                        Button {
                            isPassphraseVisible.toggle()
                        } label: {
                            Image(systemName: isPassphraseVisible ? "eye.slash.fill" : "eye.fill")
                                .foregroundColor(.textTertiary)
                        }
                    }
                    .padding(12)
                    .background(Color.backgroundCard)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.border, lineWidth: 1)
                    )

                    Text("If set, this creates a different wallet from the same recovery phrase. Losing it means losing access.")
                        .font(.caption)
                        .foregroundColor(.warning)
                }
                .padding(.horizontal, 24)

                // Error
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.error)
                        .padding(.horizontal, 24)
                }

                // Action button
                Button {
                    Task {
                        await createOrImportWallet()
                    }
                } label: {
                    Text(isNewWallet ? "Create Wallet" : "Import Wallet")
                }
                .buttonStyle(PrimaryButtonStyle(isEnabled: canProceed))
                .disabled(!canProceed || isCreating)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .background(Color.backgroundPrimary)
        .navigationTitle("Set Password")
        .navigationBarTitleDisplayMode(.inline)
        .hideKeyboard()
        .loadingOverlay(isLoading: isCreating, message: isNewWallet ? "Creating wallet..." : "Importing wallet...")
    }

    // MARK: - Wallet Creation/Import

    private func createOrImportWallet() async {
        isCreating = true
        errorMessage = nil

        do {
            let normalizedPassphrase = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
            if isNewWallet {
                let words = try await walletService.createWallet(
                    password: password,
                    passphrase: normalizedPassphrase
                )
                await MainActor.run {
                    isCreating = false
                    router.onboardingPath.append(
                        AppRouter.OnboardingDestination.backupMnemonic(words: words)
                    )
                }
            } else {
                try await walletService.importWallet(
                    mnemonic: mnemonic,
                    password: password,
                    passphrase: normalizedPassphrase
                )
                await MainActor.run {
                    isCreating = false
                    router.completeOnboarding()
                }
            }
        } catch {
            await MainActor.run {
                isCreating = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Password Strength

enum PasswordStrength {
    case empty
    case weak
    case fair
    case strong
    case veryStrong

    var meetsMinimum: Bool {
        switch self {
        case .empty, .weak, .fair: return false
        case .strong, .veryStrong: return true
        }
    }

    var label: String {
        switch self {
        case .empty: return ""
        case .weak: return "Weak"
        case .fair: return "Fair"
        case .strong: return "Strong"
        case .veryStrong: return "Very Strong"
        }
    }

    var color: Color {
        switch self {
        case .empty: return .clear
        case .weak: return .error
        case .fair: return .warning
        case .strong: return .success
        case .veryStrong: return .accentGreen
        }
    }

    var progress: Double {
        switch self {
        case .empty: return 0
        case .weak: return 0.25
        case .fair: return 0.5
        case .strong: return 0.75
        case .veryStrong: return 1.0
        }
    }

    static func evaluate(_ password: String) -> PasswordStrength {
        guard !password.isEmpty else { return .empty }

        // All four criteria must be met for minimum acceptance
        let hasLength = password.count >= 8
        let hasUppercase = password.range(of: "[A-Z]", options: .regularExpression) != nil
        let hasDigit = password.range(of: "[0-9]", options: .regularExpression) != nil
        let hasSpecial = password.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil

        let criteriaCount = [hasLength, hasUppercase, hasDigit, hasSpecial].filter { $0 }.count

        switch criteriaCount {
        case 0...1: return .weak
        case 2...3: return .fair
        case 4 where password.count >= 12: return .veryStrong
        case 4: return .strong
        default: return .weak
        }
    }
}

// MARK: - Password Strength View

private struct PasswordStrengthView: View {
    let strength: PasswordStrength

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.backgroundElevated)
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(strength.color)
                        .frame(width: geometry.size.width * strength.progress, height: 4)
                        .animation(.easeInOut, value: strength.progress)
                }
            }
            .frame(height: 4)

            if !strength.label.isEmpty {
                HStack {
                    Spacer()
                    Text(strength.label)
                        .font(.caption2)
                        .foregroundColor(strength.color)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        SetPasswordView(mnemonic: "")
            .environmentObject(AppRouter())
            .environmentObject(WalletService.shared)
    }
}
