import SwiftUI

/// BackupMnemonicView displays the 24-word mnemonic phrase for the user to write down.
///
/// This is the most critical screen in the onboarding flow. The mnemonic is the ONLY
/// way to recover the wallet if the device is lost or damaged.
///
/// Security measures on this screen:
///   - Screenshot protection enabled
///   - Background blur when app goes to background
///   - No copy-to-clipboard for the full phrase (only individual words)
///   - Warning text about keeping the phrase safe
struct BackupMnemonicView: View {
    @EnvironmentObject var router: AppRouter

    let mnemonicWords: [String]

    @State private var hasConfirmedWrittenDown = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Warning header
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.warning)

                    Text("Write Down Your Recovery Phrase")
                        .font(.title3.bold())
                        .foregroundColor(.textPrimary)

                    Text("Write these words down on paper and store them in a safe place. Do NOT take a screenshot.")
                        .font(.body)
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 16)

                // Mnemonic word grid
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Array(mnemonicWords.enumerated()), id: \.offset) { index, word in
                        MnemonicWordCard(index: index + 1, word: word)
                    }
                }
                .padding(.horizontal, 16)

                // Security warnings
                VStack(spacing: 8) {
                    WarningRow(text: "Never share your recovery phrase with anyone")
                    WarningRow(text: "Never enter it on a website or app you don't trust")
                    WarningRow(text: "Write it on paper -- do not store it digitally")
                    WarningRow(text: "Anyone with this phrase can steal your funds")
                }
                .padding(.horizontal, 24)

                // Confirmation checkbox
                Button {
                    hasConfirmedWrittenDown.toggle()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: hasConfirmedWrittenDown ? "checkmark.square.fill" : "square")
                            .foregroundColor(hasConfirmedWrittenDown ? .accentGreen : .textTertiary)
                            .font(.title3)

                        Text("I have written down my recovery phrase and stored it safely")
                            .font(.subheadline)
                            .foregroundColor(.textPrimary)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(.horizontal, 24)

                // Continue button
                Button {
                    router.onboardingPath.append(
                        AppRouter.OnboardingDestination.verifyMnemonic(words: mnemonicWords)
                    )
                } label: {
                    Text("Continue to Verification")
                }
                .buttonStyle(PrimaryButtonStyle(isEnabled: hasConfirmedWrittenDown))
                .disabled(!hasConfirmedWrittenDown)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .background(Color.backgroundPrimary)
        .navigationTitle("Recovery Phrase")
        .navigationBarTitleDisplayMode(.inline)
        .screenshotProtected()
        .blurOnBackground()
    }
}

// MARK: - Mnemonic Word Card

private struct MnemonicWordCard: View {
    let index: Int
    let word: String

    var body: some View {
        HStack(spacing: 6) {
            Text("\(index)")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.textTertiary)
                .frame(width: 20, alignment: .trailing)

            Text(word)
                .font(.subheadline.monospaced())
                .foregroundColor(.textPrimary)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color.backgroundCard)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.border, lineWidth: 1)
        )
    }
}

// MARK: - Warning Row

private struct WarningRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundColor(.error)

            Text(text)
                .font(.caption)
                .foregroundColor(.textSecondary)

            Spacer()
        }
    }
}

#Preview {
    NavigationStack {
        BackupMnemonicView(
            mnemonicWords: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"
                .split(separator: " ")
                .map(String.init)
        )
        .environmentObject(AppRouter())
    }
}
