import SwiftUI

/// AccountPickerView presents a compact sheet for switching between HD accounts.
///
/// Shows all derived accounts with their name, index, and truncated ETH address.
/// The active account has a checkmark. Includes a "Create New Account" button.
struct AccountPickerView: View {
    @EnvironmentObject var walletService: WalletService
    @Environment(\.dismiss) private var dismiss

    @State private var isCreating = false
    @State private var newAccountName = ""
    @State private var showNameInput = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    // Account list
                    Section {
                        ForEach(walletService.accounts.sorted(by: { $0.accountIndex < $1.accountIndex })) { account in
                            Button {
                                Task {
                                    try? await walletService.switchAccount(index: account.accountIndex)
                                    dismiss()
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    // Account avatar
                                    ZStack {
                                        Circle()
                                            .fill(accountColor(for: account.accountIndex).opacity(0.15))
                                            .frame(width: 40, height: 40)

                                        Text("\(account.accountIndex)")
                                            .font(.body.bold())
                                            .foregroundColor(accountColor(for: account.accountIndex))
                                    }

                                    // Account info
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(account.displayName)
                                            .font(.body.weight(.semibold))
                                            .foregroundColor(.textPrimary)

                                        Text(account.shortEthAddress)
                                            .font(.caption.monospaced())
                                            .foregroundColor(.textTertiary)
                                    }

                                    Spacer()

                                    // Active indicator
                                    if account.accountIndex == walletService.activeAccountIndex {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.title3)
                                            .foregroundColor(.accentGreen)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .listRowBackground(Color.backgroundCard)
                        }
                    } header: {
                        Text("Accounts")
                    }

                    // Create new account
                    Section {
                        if showNameInput {
                            VStack(spacing: 12) {
                                TextField("Account name (optional)", text: $newAccountName)
                                    .font(.body)
                                    .foregroundColor(.textPrimary)
                                    .padding(12)
                                    .background(Color.backgroundSecondary)
                                    .cornerRadius(10)

                                if let errorMessage {
                                    Text(errorMessage)
                                        .font(.caption)
                                        .foregroundColor(.error)
                                }

                                HStack(spacing: 12) {
                                    Button("Cancel") {
                                        showNameInput = false
                                        newAccountName = ""
                                        errorMessage = nil
                                    }
                                    .font(.body)
                                    .foregroundColor(.textSecondary)

                                    Spacer()

                                    Button {
                                        Task { await createNewAccount() }
                                    } label: {
                                        if isCreating {
                                            ProgressView()
                                                .tint(.white)
                                        } else {
                                            Text("Create")
                                        }
                                    }
                                    .font(.body.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 8)
                                    .background(Color.accentGreen)
                                    .cornerRadius(8)
                                    .disabled(isCreating)
                                }
                            }
                            .listRowBackground(Color.backgroundCard)
                        } else {
                            Button {
                                showNameInput = true
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.accentGreen.opacity(0.15))
                                            .frame(width: 40, height: 40)

                                        Image(systemName: "plus")
                                            .font(.body.bold())
                                            .foregroundColor(.accentGreen)
                                    }

                                    Text("Create New Account")
                                        .font(.body.weight(.semibold))
                                        .foregroundColor(.accentGreen)
                                }
                            }
                            .listRowBackground(Color.backgroundCard)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.backgroundPrimary)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Switch Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.accentGreen)
                }
            }
        }
    }

    private func createNewAccount() async {
        isCreating = true
        errorMessage = nil

        do {
            let name = newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
            try await walletService.createAccount(name: name.isEmpty ? nil : name)
            await MainActor.run {
                isCreating = false
                showNameInput = false
                newAccountName = ""
            }
            dismiss()
        } catch {
            await MainActor.run {
                isCreating = false
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Returns a color for the account avatar based on index.
    private func accountColor(for index: Int) -> Color {
        let colors: [Color] = [
            .accentGreen,
            .chainEthereum,
            .chainSolana,
            .chainBitcoin,
            .chainPolygon,
            .chainArbitrum,
            .chainBase,
            .info,
            .warning,
        ]
        return colors[index % colors.count]
    }
}

#Preview {
    AccountPickerView()
        .environmentObject(WalletService.shared)
}
