import SwiftUI

/// ImportWalletView allows users to restore a wallet from an existing mnemonic phrase.
///
/// Accepts 12-word or 24-word mnemonic phrases, then proceeds to SetPasswordView.
struct ImportWalletView: View {
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var walletService: WalletService

    @State private var mnemonicInput = ""
    @State private var errorMessage: String?
    @State private var wordCount = 0

    private var isValidWordCount: Bool {
        wordCount == 12 || wordCount == 24
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.accentGreen)

                    Text("Import Wallet")
                        .font(.title2.bold())
                        .foregroundColor(.textPrimary)

                    Text("Enter your 12 or 24 word recovery phrase to restore your wallet.")
                        .font(.body)
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                // Mnemonic input area
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recovery Phrase")
                        .font(.subheadline.bold())
                        .foregroundColor(.textSecondary)

                    TextEditor(text: $mnemonicInput)
                        .font(.body.monospaced())
                        .foregroundColor(.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 150)
                        .padding(12)
                        .background(Color.backgroundCard)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.border, lineWidth: 1)
                        )
                        .onChange(of: mnemonicInput) { _, newValue in
                            wordCount = newValue
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .split(separator: " ")
                                .filter { !$0.isEmpty }
                                .count
                            errorMessage = nil
                        }

                    HStack {
                        Text("\(wordCount) words")
                            .font(.caption)
                            .foregroundColor(isValidWordCount ? .success : .textTertiary)

                        Spacer()

                        Button("Paste") {
                            if let clipboard = UIPasteboard.general.string {
                                mnemonicInput = clipboard
                            }
                        }
                        .font(.caption.bold())
                        .foregroundColor(.accentGreen)
                    }
                }
                .padding(.horizontal, 24)

                // Security warning
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.warning)

                    Text("Make sure no one is watching your screen. Never share your recovery phrase with anyone.")
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                }
                .padding(12)
                .background(Color.warning.opacity(0.1))
                .cornerRadius(12)
                .padding(.horizontal, 24)

                // Error
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.error)
                        .padding(.horizontal, 24)
                }

                // Continue button
                Button {
                    let trimmed = mnemonicInput
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    let words = trimmed.split(separator: " ").map(String.init)

                    guard words.count == 12 || words.count == 24 else {
                        errorMessage = "Please enter exactly 12 or 24 words."
                        return
                    }

                    let mnemonic = words.joined(separator: " ")
                    router.onboardingPath.append(
                        AppRouter.OnboardingDestination.setPassword(mnemonic: mnemonic)
                    )
                } label: {
                    Text("Continue")
                }
                .buttonStyle(PrimaryButtonStyle(isEnabled: isValidWordCount))
                .disabled(!isValidWordCount)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .background(Color.backgroundPrimary)
        .navigationTitle("Import Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .hideKeyboard()
        .screenshotProtected()
    }
}

#Preview {
    NavigationStack {
        ImportWalletView()
            .environmentObject(AppRouter())
            .environmentObject(WalletService.shared)
    }
}
