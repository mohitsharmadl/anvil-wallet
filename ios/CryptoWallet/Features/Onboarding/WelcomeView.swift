import SwiftUI

/// WelcomeView is the first screen users see when they open the app
/// for the first time (before any wallet exists).
///
/// Provides two paths:
///   1. Create New Wallet -- generates a fresh mnemonic
///   2. Import Existing Wallet -- restore from a mnemonic backup
struct WelcomeView: View {
    @EnvironmentObject var router: AppRouter

    var body: some View {
        NavigationStack(path: $router.onboardingPath) {
            VStack(spacing: 0) {
                Spacer()

                // Logo and tagline
                VStack(spacing: 16) {
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 80))
                        .foregroundColor(.accentGreen)

                    Text("CryptoWallet")
                        .font(.largeTitle.bold())
                        .foregroundColor(.textPrimary)

                    Text("Secure. Private. Self-custodial.")
                        .font(.title3)
                        .foregroundColor(.textSecondary)
                }

                Spacer()

                // Feature highlights
                VStack(spacing: 16) {
                    FeatureRow(
                        icon: "lock.shield.fill",
                        title: "Secure Enclave Protection",
                        subtitle: "Keys never leave your device's secure hardware"
                    )
                    FeatureRow(
                        icon: "network",
                        title: "Multi-Chain Support",
                        subtitle: "Ethereum, Solana, Bitcoin, and more"
                    )
                    FeatureRow(
                        icon: "faceid",
                        title: "Biometric Security",
                        subtitle: "Face ID and Touch ID for every transaction"
                    )
                }
                .padding(.horizontal, 24)

                Spacer()

                // Action buttons
                VStack(spacing: 12) {
                    NavigationLink(value: AppRouter.OnboardingDestination.createWallet) {
                        Text("Create New Wallet")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.accentGreen)
                            .cornerRadius(12)
                    }

                    NavigationLink(value: AppRouter.OnboardingDestination.importWallet) {
                        Text("Import Existing Wallet")
                            .font(.headline)
                            .foregroundColor(.accentGreen)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.accentGreen.opacity(0.1))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.accentGreen.opacity(0.3), lineWidth: 1)
                            )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .background(Color.backgroundPrimary)
            .navigationDestination(for: AppRouter.OnboardingDestination.self) { destination in
                switch destination {
                case .createWallet:
                    CreateWalletView()
                case .importWallet:
                    ImportWalletView()
                case .backupMnemonic(let words):
                    BackupMnemonicView(mnemonicWords: words)
                case .verifyMnemonic(let words):
                    VerifyMnemonicView(mnemonicWords: words)
                case .setPassword(let mnemonic):
                    SetPasswordView(mnemonic: mnemonic)
                }
            }
        }
    }
}

// MARK: - Feature Row

private struct FeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentGreen)
                .frame(width: 44, height: 44)
                .background(Color.accentGreen.opacity(0.1))
                .cornerRadius(12)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundColor(.textPrimary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.textSecondary)
            }

            Spacer()
        }
    }
}

#Preview {
    WelcomeView()
        .environmentObject(AppRouter())
        .environmentObject(WalletService.shared)
}
