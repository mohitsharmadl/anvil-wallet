import SwiftUI

/// ImportWalletView allows users to restore a wallet from an existing mnemonic phrase.
///
/// Accepts 12-word or 24-word mnemonic phrases, then proceeds to SetPasswordView.
/// Each word is validated against the BIP-39 word list via Rust FFI in real time.
struct ImportWalletView: View {
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var walletService: WalletService

    @State private var mnemonicInput = ""
    @State private var errorMessage: String?
    @State private var wordCount = 0
    @State private var invalidWords: [String] = []
    @State private var isValidating = false

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
                            let words = newValue
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .lowercased()
                                .split(separator: " ")
                                .filter { !$0.isEmpty }
                                .map(String.init)

                            wordCount = words.count
                            errorMessage = nil

                            // Validate each word against BIP-39 word list
                            invalidWords = words.filter { !isValidBip39Word(word: $0) }
                        }

                    HStack {
                        Text("\(wordCount) words")
                            .font(.caption)
                            .foregroundColor(isValidWordCount ? .success : .textTertiary)

                        Spacer()

                        if !invalidWords.isEmpty {
                            Text("Invalid: \(invalidWords.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundColor(.error)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button("Paste") {
                            if let clipboard = UIPasteboard.general.string {
                                mnemonicInput = clipboard
                                // Clear clipboard after pasting sensitive mnemonic
                                ClipboardManager.shared.clearClipboard()
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
                    Task {
                        await validateAndProceed()
                    }
                } label: {
                    if isValidating {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Continue")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(isEnabled: isValidWordCount && invalidWords.isEmpty))
                .disabled(!isValidWordCount || !invalidWords.isEmpty || isValidating)
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

    // MARK: - Validation

    private func validateAndProceed() async {
        isValidating = true
        errorMessage = nil

        let trimmed = mnemonicInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let words = trimmed.split(separator: " ").map(String.init)

        guard words.count == 12 || words.count == 24 else {
            errorMessage = "Please enter exactly 12 or 24 words."
            isValidating = false
            return
        }

        let mnemonic = words.joined(separator: " ")

        do {
            // Full mnemonic validation via Rust (checksum + word list)
            let isValid = try validateMnemonic(phrase: mnemonic)
            guard isValid else {
                errorMessage = "Invalid mnemonic. Please check your words and checksum."
                isValidating = false
                return
            }

            await MainActor.run {
                isValidating = false
                router.onboardingPath.append(
                    AppRouter.OnboardingDestination.setPassword(mnemonic: mnemonic)
                )
            }
        } catch {
            await MainActor.run {
                errorMessage = "Validation failed: \(error.localizedDescription)"
                isValidating = false
            }
        }
    }
}

#Preview {
    NavigationStack {
        ImportWalletView()
            .environmentObject(AppRouter())
            .environmentObject(WalletService.shared)
    }
}
