import SwiftUI

/// SendView allows users to compose a token transfer transaction.
///
/// Flow: SendView -> ConfirmTransactionView -> TransactionResultView
struct SendView: View {
    @EnvironmentObject var walletService: WalletService
    @EnvironmentObject var router: AppRouter

    @State private var recipientAddress = ""
    @State private var amount = ""
    @State private var selectedToken: TokenModel?
    @State private var showTokenPicker = false
    @State private var showQRScanner = false
    @State private var showAddressBookPicker = false
    @State private var errorMessage: String?

    private var isValidInput: Bool {
        !recipientAddress.isEmpty && !amount.isEmpty && selectedToken != nil
    }

    /// Maps our chain ID strings to the Rust Chain enum for address validation.
    static func rustChain(for chainId: String) -> Chain? {
        switch chainId {
        case "ethereum": return .ethereum
        case "polygon": return .polygon
        case "arbitrum": return .arbitrum
        case "base": return .base
        case "optimism": return .optimism
        case "bsc": return .bsc
        case "avalanche": return .avalanche
        case "solana": return .solana
        case "bitcoin": return .bitcoin
        case "sepolia": return .sepolia
        case "zcash": return .zcash
        case "zcash_testnet": return .zcashTestnet
        default: return nil
        }
    }

    /// Chains that don't yet support sending from the UI.
    private static let unsendableChains: Set<String> = ["zcash", "zcash_testnet"]

    var body: some View {
        NavigationStack(path: $router.sendPath) {
            ScrollView {
                VStack(spacing: 20) {
                    // Token selector
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Token")
                            .font(.subheadline.bold())
                            .foregroundColor(.textSecondary)

                        Button {
                            showTokenPicker = true
                        } label: {
                            HStack {
                                if let token = selectedToken {
                                    TokenIconView(symbol: token.symbol, chain: token.chain, size: 32)

                                    Text(token.symbol)
                                        .foregroundColor(.textPrimary)

                                    Spacer()

                                    Text(token.formattedBalance)
                                        .foregroundColor(.textSecondary)
                                        .monospacedDigit()
                                } else {
                                    Text("Select token")
                                        .foregroundColor(.textTertiary)
                                    Spacer()
                                }

                                Image(systemName: "chevron.down")
                                    .foregroundColor(.textTertiary)
                            }
                            .font(.body)
                            .padding(14)
                            .background(Color.backgroundCard)
                            .cornerRadius(12)
                        }
                        .frame(minHeight: 44)
                        .accessibilityLabel(selectedToken != nil
                            ? "Selected token: \(selectedToken!.symbol), balance: \(selectedToken!.formattedBalance)"
                            : "Select token")
                        .accessibilityHint("Double tap to choose a token")
                    }
                    .padding(.horizontal, 20)

                    // Recipient address
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recipient")
                            .font(.subheadline.bold())
                            .foregroundColor(.textSecondary)

                        HStack {
                            TextField("Address or ENS name", text: $recipientAddress)
                                .font(.body)
                                .foregroundColor(.textPrimary)
                                .autocapitalization(.none)
                                .autocorrectionDisabled()
                                .accessibilityLabel("Recipient address")

                            Button {
                                showAddressBookPicker = true
                            } label: {
                                Image(systemName: "person.crop.rectangle.stack")
                                    .foregroundColor(.accentGreen)
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel("Address book")
                            .accessibilityHint("Double tap to select from saved addresses")

                            Button {
                                showQRScanner = true
                            } label: {
                                Image(systemName: "qrcode.viewfinder")
                                    .foregroundColor(.accentGreen)
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel("Scan QR code")
                            .accessibilityHint("Double tap to scan a QR code")

                            Button {
                                if let clipboard = UIPasteboard.general.string {
                                    recipientAddress = clipboard
                                    Haptic.impact(.light)
                                }
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                                    .foregroundColor(.accentGreen)
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel("Paste from clipboard")
                            .accessibilityHint("Double tap to paste address from clipboard")
                        }
                        .padding(14)
                        .background(Color.backgroundCard)
                        .cornerRadius(12)

                        // Address book suggestions (shown when address field is focused and contacts exist)
                        if recipientAddress.isEmpty,
                           let token = selectedToken,
                           !AddressBookService.shared.addresses(for: token.chain).isEmpty {
                            AddressSuggestionList(
                                chain: token.chain,
                                onSelect: { saved in
                                    recipientAddress = saved.address
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 20)

                    // Amount
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Amount")
                            .font(.subheadline.bold())
                            .foregroundColor(.textSecondary)

                        HStack {
                            TextField("0.0", text: $amount)
                                .font(.title2.monospacedDigit())
                                .foregroundColor(.textPrimary)
                                .keyboardType(.decimalPad)

                            if let token = selectedToken {
                                Text(token.symbol)
                                    .foregroundColor(.textSecondary)

                                Button("Max") {
                                    amount = token.formattedBalance
                                    Haptic.impact(.light)
                                }
                                .font(.caption.bold())
                                .foregroundColor(.accentGreen)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentGreen.opacity(0.1))
                                .cornerRadius(8)
                                .frame(minHeight: 44)
                                .accessibilityLabel("Use maximum balance")
                                .accessibilityHint("Double tap to set amount to full \(token.symbol) balance")
                            }
                        }
                        .padding(14)
                        .background(Color.backgroundCard)
                        .cornerRadius(12)

                        if let token = selectedToken {
                            let amountDecimal = Decimal(string: amount) ?? 0
                            let usdValue = amountDecimal * Decimal(token.priceUsd)
                            Text(String(format: "~$%.2f", NSDecimalNumber(decimal: usdValue).doubleValue))
                                .font(.caption)
                                .foregroundColor(.textTertiary)
                        }
                    }
                    .padding(.horizontal, 20)

                    // Error
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.error)
                            .padding(.horizontal, 20)
                            .accessibilityLabel("Error: \(errorMessage)")
                    }

                    Spacer(minLength: 40)

                    // Review button
                    Button {
                        guard let token = selectedToken,
                              !amount.isEmpty,
                              Decimal(string: amount) != nil,
                              !recipientAddress.isEmpty else {
                            errorMessage = "Please fill in all fields with valid values."
                            Haptic.error()
                            return
                        }

                        // Validate address against the chain's format using Rust FFI
                        if let rustChain = Self.rustChain(for: token.chain) {
                            let isValid = (try? validateAddress(address: recipientAddress, chain: rustChain)) ?? false
                            if !isValid {
                                errorMessage = "Invalid address for \(token.chain.capitalized)"
                                Haptic.error()
                                return
                            }
                        }

                        let tx = TransactionModel(
                            hash: "",
                            chain: token.chain,
                            from: walletService.addresses[token.chain] ?? "",
                            to: recipientAddress,
                            amount: amount,
                            tokenSymbol: token.symbol,
                            tokenDecimals: token.decimals,
                            contractAddress: token.contractAddress
                        )
                        Haptic.impact(.medium)
                        router.sendPath.append(
                            AppRouter.SendDestination.confirmTransaction(transaction: tx)
                        )
                    } label: {
                        Text("Review Transaction")
                    }
                    .buttonStyle(PrimaryButtonStyle(isEnabled: isValidInput))
                    .disabled(!isValidInput)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                    .accessibilityLabel("Review transaction")
                    .accessibilityHint(isValidInput ? "Double tap to review and confirm" : "Fill in all fields to enable")
                }
                .padding(.top, 16)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.large)
            .hideKeyboard()
            .sheet(isPresented: $showTokenPicker) {
                TokenPickerSheet(
                    tokens: walletService.tokens.filter { !Self.unsendableChains.contains($0.chain) },
                    selectedToken: $selectedToken
                )
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView { scannedAddress in
                    recipientAddress = scannedAddress
                    showQRScanner = false
                }
            }
            .sheet(isPresented: $showAddressBookPicker) {
                AddressBookPickerSheet(
                    chain: selectedToken?.chain ?? "ethereum"
                ) { savedAddress in
                    recipientAddress = savedAddress.address
                    showAddressBookPicker = false
                }
            }
            .navigationDestination(for: AppRouter.SendDestination.self) { destination in
                switch destination {
                case .confirmTransaction(let tx):
                    ConfirmTransactionView(transaction: tx)
                case .transactionResult(let hash, let success, let chain, let recipientAddress):
                    TransactionResultView(txHash: hash, success: success, chain: chain, recipientAddress: recipientAddress)
                case .qrScanner:
                    QRScannerView { address in
                        recipientAddress = address
                    }
                }
            }
            .onAppear {
                if selectedToken == nil {
                    selectedToken = walletService.tokens.first { !Self.unsendableChains.contains($0.chain) }
                }
            }
        }
    }
}

// MARK: - Token Picker Sheet

private struct TokenPickerSheet: View {
    let tokens: [TokenModel]
    @Binding var selectedToken: TokenModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(tokens) { token in
                Button {
                    selectedToken = token
                    dismiss()
                } label: {
                    HStack {
                        TokenIconView(symbol: token.symbol, chain: token.chain, size: 36)

                        VStack(alignment: .leading) {
                            Text(token.symbol)
                                .font(.body.bold())
                                .foregroundColor(.textPrimary)
                            Text(token.name)
                                .font(.caption)
                                .foregroundColor(.textSecondary)
                        }

                        Spacer()

                        Text(token.formattedBalance)
                            .font(.body.monospacedDigit())
                            .foregroundColor(.textPrimary)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Select Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Address Suggestion List

/// Inline compact list of saved addresses for the current chain, shown below the address field.
private struct AddressSuggestionList: View {
    let chain: String
    let onSelect: (SavedAddress) -> Void

    private var contacts: [SavedAddress] {
        Array(AddressBookService.shared.addresses(for: chain).prefix(3))
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(contacts) { contact in
                Button {
                    onSelect(contact)
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color.accentGreen.opacity(0.15))
                                .frame(width: 28, height: 28)
                            Text(String(contact.name.prefix(1)).uppercased())
                                .font(.caption.bold())
                                .foregroundColor(.accentGreen)
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            Text(contact.name)
                                .font(.subheadline)
                                .foregroundColor(.textPrimary)
                                .lineLimit(1)
                            Text(contact.shortAddress)
                                .font(.caption.monospaced())
                                .foregroundColor(.textTertiary)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                }
            }
        }
        .background(Color.backgroundCard)
        .cornerRadius(10)
    }
}

// MARK: - Address Book Picker Sheet

/// Full-screen picker that shows all saved addresses for the selected chain.
struct AddressBookPickerSheet: View {
    let chain: String
    let onSelect: (SavedAddress) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var contacts: [SavedAddress] {
        let all = AddressBookService.shared.addresses(for: chain)
        if searchText.isEmpty { return all }
        let query = searchText.lowercased()
        return all.filter {
            $0.name.lowercased().contains(query)
                || $0.address.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if AddressBookService.shared.addresses(for: chain).isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.rectangle.stack")
                            .font(.system(size: 40))
                            .foregroundColor(.textTertiary)

                        Text("No Saved Addresses")
                            .font(.headline)
                            .foregroundColor(.textPrimary)

                        Text("You don't have any saved addresses for this network yet.")
                            .font(.subheadline)
                            .foregroundColor(.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(contacts) { contact in
                        Button {
                            onSelect(contact)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.accentGreen.opacity(0.15))
                                        .frame(width: 40, height: 40)
                                    Text(String(contact.name.prefix(1)).uppercased())
                                        .font(.headline)
                                        .foregroundColor(.accentGreen)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contact.name)
                                        .font(.body.bold())
                                        .foregroundColor(.textPrimary)
                                        .lineLimit(1)
                                    Text(contact.shortAddress)
                                        .font(.caption.monospaced())
                                        .foregroundColor(.textSecondary)
                                }

                                Spacer()

                                if let notes = contact.notes, !notes.isEmpty {
                                    Text(notes)
                                        .font(.caption)
                                        .foregroundColor(.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(Color.backgroundCard)
                    }
                    .listStyle(.plain)
                    .searchable(text: $searchText, prompt: "Search contacts")
                }
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Select Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
            }
        }
    }
}

#Preview {
    SendView()
        .environmentObject(WalletService.shared)
        .environmentObject(AppRouter())
}
