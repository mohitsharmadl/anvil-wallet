import SwiftUI

/// CreateWalletView handles the initial wallet creation flow.
///
/// Flow: CreateWalletView -> SetPasswordView -> BackupMnemonicView -> VerifyMnemonicView
///
/// This view collects the user's password, generates a mnemonic,
/// and then sends the user to back up and verify it.
struct CreateWalletView: View {
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var walletService: WalletService

    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Icon
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(.accentGreen)

            // Title
            VStack(spacing: 8) {
                Text("Create New Wallet")
                    .font(.title.bold())
                    .foregroundColor(.textPrimary)

                Text("We'll generate a secure wallet for you.\nYou'll need to set a password and back up your recovery phrase.")
                    .font(.body)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()

            // Security info cards
            VStack(spacing: 12) {
                SecurityInfoCard(
                    icon: "key.fill",
                    text: "Your recovery phrase is the ONLY way to restore your wallet. Keep it safe."
                )
                SecurityInfoCard(
                    icon: "lock.fill",
                    text: "Your password encrypts the wallet on this device. Choose a strong one."
                )
                SecurityInfoCard(
                    icon: "iphone.and.arrow.forward",
                    text: "Keys never leave this device. We can't recover your wallet for you."
                )
            }
            .padding(.horizontal, 24)

            Spacer()

            // Error message
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.error)
                    .padding(.horizontal)
            }

            // Continue button
            Button {
                router.onboardingPath.append(
                    AppRouter.OnboardingDestination.setPassword(mnemonic: "")
                )
            } label: {
                Text("Continue")
            }
            .buttonStyle(.primary)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(Color.backgroundPrimary)
        .navigationTitle("Create Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .loadingOverlay(isLoading: isCreating, message: "Creating wallet...")
    }
}

// MARK: - Security Info Card

private struct SecurityInfoCard: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(.warning)
                .frame(width: 32)

            Text(text)
                .font(.caption)
                .foregroundColor(.textSecondary)

            Spacer()
        }
        .padding(12)
        .background(Color.backgroundCard)
        .cornerRadius(12)
    }
}

#Preview {
    NavigationStack {
        CreateWalletView()
            .environmentObject(AppRouter())
            .environmentObject(WalletService.shared)
    }
}
