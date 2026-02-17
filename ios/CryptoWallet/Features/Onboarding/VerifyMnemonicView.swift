import SwiftUI

/// VerifyMnemonicView asks the user to confirm specific words from their mnemonic
/// to prove they actually wrote it down.
///
/// The view randomly selects 4 word positions and asks the user to type or select
/// the correct word for each position.
struct VerifyMnemonicView: View {
    @EnvironmentObject var router: AppRouter

    let mnemonicWords: [String]

    @State private var verificationIndices: [Int] = []
    @State private var userInputs: [Int: String] = [:]
    @State private var errorMessage: String?
    @State private var isVerified = false

    private let numberOfVerifications = 4

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.accentGreen)

                    Text("Verify Your Recovery Phrase")
                        .font(.title3.bold())
                        .foregroundColor(.textPrimary)

                    Text("Enter the correct word for each position to confirm you've saved your recovery phrase.")
                        .font(.body)
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 16)

                // Verification inputs
                VStack(spacing: 16) {
                    ForEach(verificationIndices, id: \.self) { index in
                        VerificationWordInput(
                            wordIndex: index + 1,
                            correctWord: mnemonicWords[index],
                            input: Binding(
                                get: { userInputs[index] ?? "" },
                                set: { userInputs[index] = $0 }
                            ),
                            isCorrect: isWordCorrect(at: index)
                        )
                    }
                }
                .padding(.horizontal, 24)

                // Error
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.error)
                        .padding(.horizontal, 24)
                }

                // Verify button
                Button {
                    verifyWords()
                } label: {
                    Text("Verify & Complete")
                }
                .buttonStyle(PrimaryButtonStyle(isEnabled: allFieldsFilled))
                .disabled(!allFieldsFilled)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .background(Color.backgroundPrimary)
        .navigationTitle("Verify Phrase")
        .navigationBarTitleDisplayMode(.inline)
        .hideKeyboard()
        .onAppear {
            selectRandomIndices()
        }
    }

    // MARK: - Logic

    private var allFieldsFilled: Bool {
        verificationIndices.allSatisfy { index in
            let input = userInputs[index] ?? ""
            return !input.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func isWordCorrect(at index: Int) -> Bool? {
        guard let input = userInputs[index],
              !input.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil // Not yet entered
        }
        return input.trimmingCharacters(in: .whitespaces).lowercased() == mnemonicWords[index].lowercased()
    }

    private func selectRandomIndices() {
        guard !mnemonicWords.isEmpty else { return }
        var indices = Set<Int>()
        while indices.count < min(numberOfVerifications, mnemonicWords.count) {
            indices.insert(Int.random(in: 0..<mnemonicWords.count))
        }
        verificationIndices = indices.sorted()
    }

    private func verifyWords() {
        let allCorrect = verificationIndices.allSatisfy { isWordCorrect(at: $0) == true }

        if allCorrect {
            isVerified = true
            errorMessage = nil
            router.completeOnboarding()
        } else {
            errorMessage = "One or more words are incorrect. Please check and try again."
        }
    }
}

// MARK: - Verification Word Input

private struct VerificationWordInput: View {
    let wordIndex: Int
    let correctWord: String
    @Binding var input: String
    let isCorrect: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Word #\(wordIndex)")
                .font(.subheadline.bold())
                .foregroundColor(.textSecondary)

            HStack {
                TextField("Enter word \(wordIndex)", text: $input)
                    .font(.body.monospaced())
                    .foregroundColor(.textPrimary)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()

                if let isCorrect {
                    Image(systemName: isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(isCorrect ? .success : .error)
                }
            }
            .padding(12)
            .background(Color.backgroundCard)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
    }

    private var borderColor: Color {
        guard let isCorrect else { return Color.border }
        return isCorrect ? Color.success : Color.error
    }
}

#Preview {
    NavigationStack {
        VerifyMnemonicView(
            mnemonicWords: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"
                .split(separator: " ")
                .map(String.init)
        )
        .environmentObject(AppRouter())
    }
}
