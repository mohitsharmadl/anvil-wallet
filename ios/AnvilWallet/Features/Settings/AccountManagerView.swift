import SwiftUI

/// AccountManagerView provides full account management in Settings.
///
/// Features:
///   - List all HD accounts with name editing
///   - Create new accounts
///   - Delete non-primary accounts
///   - Show all chain addresses for each account
struct AccountManagerView: View {
    @EnvironmentObject var walletService: WalletService

    @State private var editingAccountIndex: Int?
    @State private var editedName = ""
    @State private var isCreating = false
    @State private var newAccountName = ""
    @State private var showCreateSheet = false
    @State private var createError: String?
    @State private var showDeleteConfirmation = false
    @State private var accountToDelete: Int?
    @State private var expandedAccount: Int?

    var body: some View {
        List {
            // Accounts
            Section {
                ForEach(walletService.accounts.sorted(by: { $0.accountIndex < $1.accountIndex })) { account in
                    accountRow(account)
                }
            } header: {
                HStack {
                    Text("HD Accounts")
                    Spacer()
                    Text("\(walletService.accounts.count) accounts")
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                }
            } footer: {
                Text("All accounts are derived from the same recovery phrase using different BIP-44 derivation paths. Each account has its own set of addresses.")
                    .font(.caption)
                    .foregroundColor(.textTertiary)
            }

            // Create new
            Section {
                Button {
                    showCreateSheet = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundColor(.accentGreen)

                        Text("Create New Account")
                            .font(.body)
                            .foregroundColor(.accentGreen)
                    }
                }
            }
            .listRowBackground(Color.backgroundCard)
        }
        .scrollContentBackground(.hidden)
        .background(Color.backgroundPrimary)
        .navigationTitle("Manage Accounts")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showCreateSheet) {
            createAccountSheet
                .presentationDetents([.medium])
        }
        .alert("Delete Account", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                accountToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let idx = accountToDelete {
                    Task {
                        try? await walletService.deleteAccount(index: idx)
                        accountToDelete = nil
                    }
                }
            }
        } message: {
            if let idx = accountToDelete,
               let account = walletService.accounts.first(where: { $0.accountIndex == idx }) {
                Text("Delete \"\(account.displayName)\"? This only removes it from the app. Since all accounts share the same recovery phrase, you can always re-create it.")
            }
        }
    }

    // MARK: - Account Row

    @ViewBuilder
    private func accountRow(_ account: WalletModel) -> some View {
        VStack(spacing: 0) {
            // Main row
            HStack(spacing: 12) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(accountColor(for: account.accountIndex).opacity(0.15))
                        .frame(width: 44, height: 44)

                    Text("\(account.accountIndex)")
                        .font(.body.bold())
                        .foregroundColor(accountColor(for: account.accountIndex))
                }

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    if editingAccountIndex == account.accountIndex {
                        TextField("Account name", text: $editedName, onCommit: {
                            saveAccountName(index: account.accountIndex)
                        })
                        .font(.body.weight(.semibold))
                        .foregroundColor(.textPrimary)
                        .textFieldStyle(.roundedBorder)
                    } else {
                        Text(account.displayName)
                            .font(.body.weight(.semibold))
                            .foregroundColor(.textPrimary)
                    }

                    Text(account.shortEthAddress)
                        .font(.caption.monospaced())
                        .foregroundColor(.textTertiary)
                }

                Spacer()

                // Active badge
                if account.accountIndex == walletService.activeAccountIndex {
                    Text("Active")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentGreen)
                        .cornerRadius(6)
                }

                // Expand/collapse
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expandedAccount == account.accountIndex {
                            expandedAccount = nil
                        } else {
                            expandedAccount = account.accountIndex
                        }
                    }
                } label: {
                    Image(systemName: expandedAccount == account.accountIndex ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundColor(.textTertiary)
                        .frame(width: 28, height: 28)
                }
            }

            // Expanded details
            if expandedAccount == account.accountIndex {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                        .padding(.vertical, 8)

                    // Addresses
                    ForEach(addressEntries(for: account), id: \.chain) { entry in
                        HStack(spacing: 8) {
                            Text(entry.chain)
                                .font(.caption.bold())
                                .foregroundColor(.textSecondary)
                                .frame(width: 60, alignment: .leading)

                            Text(entry.address)
                                .font(.caption2.monospaced())
                                .foregroundColor(.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    // Actions
                    HStack(spacing: 16) {
                        // Edit name
                        Button {
                            if editingAccountIndex == account.accountIndex {
                                saveAccountName(index: account.accountIndex)
                            } else {
                                editedName = account.accountName ?? ""
                                editingAccountIndex = account.accountIndex
                            }
                        } label: {
                            Label(
                                editingAccountIndex == account.accountIndex ? "Save" : "Rename",
                                systemImage: editingAccountIndex == account.accountIndex ? "checkmark" : "pencil"
                            )
                            .font(.caption.bold())
                            .foregroundColor(.info)
                        }

                        // Switch to this account
                        if account.accountIndex != walletService.activeAccountIndex {
                            Button {
                                Task {
                                    try? await walletService.switchAccount(index: account.accountIndex)
                                }
                            } label: {
                                Label("Switch", systemImage: "arrow.right.circle")
                                    .font(.caption.bold())
                                    .foregroundColor(.accentGreen)
                            }

                            // Delete (only non-primary)
                            if account.accountIndex != 0 {
                                Button {
                                    accountToDelete = account.accountIndex
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                        .font(.caption.bold())
                                        .foregroundColor(.error)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .listRowBackground(Color.backgroundCard)
    }

    // MARK: - Create Account Sheet

    private var createAccountSheet: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 48))
                    .foregroundColor(.accentGreen)

                Text("Create New Account")
                    .font(.title3.bold())
                    .foregroundColor(.textPrimary)

                Text("A new account will be derived from your existing recovery phrase with a different HD path index.")
                    .font(.body)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

                TextField("Account name (optional)", text: $newAccountName)
                    .font(.body)
                    .padding(14)
                    .background(Color.backgroundCard)
                    .cornerRadius(12)
                    .padding(.horizontal, 20)

                if let createError {
                    Text(createError)
                        .font(.caption)
                        .foregroundColor(.error)
                        .padding(.horizontal, 20)
                }

                Spacer()

                Button {
                    Task { await createAccount() }
                } label: {
                    if isCreating {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Create Account")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(isEnabled: !isCreating))
                .disabled(isCreating)
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .padding(.top, 24)
            .background(Color.backgroundPrimary)
            .navigationTitle("New Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        showCreateSheet = false
                        newAccountName = ""
                        createError = nil
                    }
                    .foregroundColor(.textSecondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private func createAccount() async {
        isCreating = true
        createError = nil

        do {
            let name = newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
            try await walletService.createAccount(name: name.isEmpty ? nil : name)
            await MainActor.run {
                isCreating = false
                showCreateSheet = false
                newAccountName = ""
            }
        } catch {
            await MainActor.run {
                isCreating = false
                createError = error.localizedDescription
            }
        }
    }

    private func saveAccountName(index: Int) {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        try? walletService.renameAccount(index: index, name: trimmed.isEmpty ? "Account \(index)" : trimmed)
        editingAccountIndex = nil
        editedName = ""
    }

    private struct AddressEntry {
        let chain: String
        let address: String
    }

    private func addressEntries(for account: WalletModel) -> [AddressEntry] {
        var entries: [AddressEntry] = []
        if let eth = account.addresses["ethereum"] {
            entries.append(AddressEntry(chain: "ETH", address: eth))
        }
        if let sol = account.addresses["solana"] {
            entries.append(AddressEntry(chain: "SOL", address: sol))
        }
        if let btc = account.addresses["bitcoin"] {
            entries.append(AddressEntry(chain: "BTC", address: btc))
        }
        return entries
    }

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
    NavigationStack {
        AccountManagerView()
            .environmentObject(WalletService.shared)
    }
}
