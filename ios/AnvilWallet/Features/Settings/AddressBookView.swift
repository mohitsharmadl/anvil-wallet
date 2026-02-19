import SwiftUI

/// Displays all saved addresses grouped by chain type, with search, add, edit, and delete.
struct AddressBookView: View {
    @ObservedObject private var addressBook = AddressBookService.shared

    @State private var searchText = ""
    @State private var showAddSheet = false
    @State private var editingAddress: SavedAddress?

    private var filteredAddresses: [SavedAddress] {
        if searchText.isEmpty {
            return addressBook.addresses
        }
        let query = searchText.lowercased()
        return addressBook.addresses.filter {
            $0.name.lowercased().contains(query)
                || $0.address.lowercased().contains(query)
                || $0.chainDisplayName.lowercased().contains(query)
        }
    }

    /// Groups filtered addresses by chain for display.
    private var groupedAddresses: [(String, [SavedAddress])] {
        let grouped = Dictionary(grouping: filteredAddresses) { $0.chain }
        let order = ["ethereum", "solana", "bitcoin"]
        return order.compactMap { chain in
            guard let items = grouped[chain], !items.isEmpty else { return nil }
            return (chain, items.sorted { $0.name.lowercased() < $1.name.lowercased() })
        }
    }

    var body: some View {
        Group {
            if addressBook.addresses.isEmpty && searchText.isEmpty {
                emptyState
            } else {
                addressList
            }
        }
        .background(Color.backgroundPrimary)
        .navigationTitle("Address Book")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search by name or address")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundColor(.accentGreen)
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddAddressSheet()
        }
        .sheet(item: $editingAddress) { address in
            EditAddressSheet(address: address)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "person.crop.rectangle.stack")
                .font(.system(size: 56))
                .foregroundColor(.textTertiary)

            Text("No Saved Addresses")
                .font(.title3.bold())
                .foregroundColor(.textPrimary)

            Text("Save frequently used addresses to quickly fill them in when sending.")
                .font(.subheadline)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                showAddSheet = true
            } label: {
                Text("Add Address")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 60)
            .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - Address List

    private var addressList: some View {
        List {
            ForEach(groupedAddresses, id: \.0) { chain, items in
                Section(header: chainSectionHeader(chain)) {
                    ForEach(items) { address in
                        AddressRow(address: address)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingAddress = address
                            }
                    }
                    .onDelete { offsets in
                        for offset in offsets {
                            addressBook.removeAddress(id: items[offset].id)
                        }
                    }
                }
                .listRowBackground(Color.backgroundCard)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Section Header

    private func chainSectionHeader(_ chain: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(chainColor(for: chain))
                .frame(width: 8, height: 8)
            Text(chainDisplayName(for: chain))
                .font(.subheadline.bold())
                .foregroundColor(.textSecondary)
        }
    }

    private func chainColor(for chain: String) -> Color {
        switch chain {
        case "ethereum": return .chainEthereum
        case "solana": return .chainSolana
        case "bitcoin": return .chainBitcoin
        default: return .textTertiary
        }
    }

    private func chainDisplayName(for chain: String) -> String {
        switch chain {
        case "ethereum": return "Ethereum & EVM Chains"
        case "solana": return "Solana"
        case "bitcoin": return "Bitcoin"
        default: return chain.capitalized
        }
    }
}

// MARK: - Address Row

private struct AddressRow: View {
    let address: SavedAddress

    var body: some View {
        HStack(spacing: 12) {
            // Avatar circle with initials
            ZStack {
                Circle()
                    .fill(Color.accentGreen.opacity(0.15))
                    .frame(width: 40, height: 40)

                Text(String(address.name.prefix(1)).uppercased())
                    .font(.headline)
                    .foregroundColor(.accentGreen)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(address.name)
                    .font(.body.bold())
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)

                Text(address.shortAddress)
                    .font(.caption.monospaced())
                    .foregroundColor(.textSecondary)
            }

            Spacer()

            ChainBadge(chain: address.chain)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Chain Badge

struct ChainBadge: View {
    let chain: String

    var body: some View {
        Text(badgeLabel)
            .font(.caption2.bold())
            .foregroundColor(badgeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.12))
            .cornerRadius(6)
    }

    private var badgeLabel: String {
        switch chain {
        case "ethereum": return "EVM"
        case "solana": return "SOL"
        case "bitcoin": return "BTC"
        default: return chain.prefix(3).uppercased()
        }
    }

    private var badgeColor: Color {
        switch chain {
        case "ethereum": return .chainEthereum
        case "solana": return .chainSolana
        case "bitcoin": return .chainBitcoin
        default: return .textTertiary
        }
    }
}

// MARK: - Add Address Sheet

struct AddAddressSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var addressBook = AddressBookService.shared

    @State private var name = ""
    @State private var address = ""
    @State private var selectedChain = "ethereum"
    @State private var notes = ""
    @State private var errorMessage: String?

    /// Optional pre-fill values (used from TransactionResultView "Save to Contacts").
    var prefillAddress: String?
    var prefillChain: String?

    private let chainOptions = [
        ("ethereum", "Ethereum & EVM"),
        ("solana", "Solana"),
        ("bitcoin", "Bitcoin"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Contact") {
                    TextField("Name", text: $name)
                        .foregroundColor(.textPrimary)

                    TextField("Address", text: $address)
                        .font(.body.monospaced())
                        .foregroundColor(.textPrimary)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()

                    Picker("Network", selection: $selectedChain) {
                        ForEach(chainOptions, id: \.0) { id, label in
                            Text(label).tag(id)
                        }
                    }
                    .foregroundColor(.textPrimary)
                }
                .listRowBackground(Color.backgroundCard)

                Section("Notes (optional)") {
                    TextField("e.g. Exchange hot wallet", text: $notes)
                        .foregroundColor(.textPrimary)
                }
                .listRowBackground(Color.backgroundCard)

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.error)
                    }
                    .listRowBackground(Color.error.opacity(0.1))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.backgroundPrimary)
            .navigationTitle("Add Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { saveAddress() }
                        .foregroundColor(.accentGreen)
                        .bold()
                        .disabled(name.isEmpty || address.isEmpty)
                }
            }
            .onAppear {
                if let prefillAddress { address = prefillAddress }
                if let prefillChain {
                    let evmChains: Set<String> = ["ethereum", "polygon", "arbitrum", "base", "optimism", "bsc", "avalanche", "sepolia"]
                    selectedChain = evmChains.contains(prefillChain) ? "ethereum" : prefillChain
                }
            }
        }
    }

    private func saveAddress() {
        errorMessage = nil
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            errorMessage = "Please enter a name."
            return
        }
        guard !trimmedAddress.isEmpty else {
            errorMessage = "Please enter an address."
            return
        }

        // Validate address format using Rust FFI
        if let rustChain = rustChainForValidation(selectedChain) {
            let isValid = (try? validateAddress(address: trimmedAddress, chain: rustChain)) ?? false
            if !isValid {
                errorMessage = "Invalid address for \(chainOptions.first { $0.0 == selectedChain }?.1 ?? selectedChain)."
                return
            }
        }

        let added = addressBook.addAddress(
            name: trimmedName,
            address: trimmedAddress,
            chain: selectedChain,
            notes: notes.isEmpty ? nil : notes
        )

        if !added {
            errorMessage = "This address is already saved."
            return
        }

        dismiss()
    }

    /// Maps chain selection to Rust Chain enum for validation.
    private func rustChainForValidation(_ chain: String) -> Chain? {
        switch chain {
        case "ethereum": return .ethereum
        case "solana": return .solana
        case "bitcoin": return .bitcoin
        default: return nil
        }
    }
}

// MARK: - Edit Address Sheet

private struct EditAddressSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var addressBook = AddressBookService.shared

    let address: SavedAddress

    @State private var name: String = ""
    @State private var notes: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Contact") {
                    TextField("Name", text: $name)
                        .foregroundColor(.textPrimary)

                    HStack {
                        Text("Address")
                            .foregroundColor(.textSecondary)
                        Spacer()
                        Text(address.shortAddress)
                            .font(.body.monospaced())
                            .foregroundColor(.textPrimary)

                        Button {
                            ClipboardManager.shared.copyToClipboard(address.address, sensitive: false)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                                .foregroundColor(.accentGreen)
                        }
                    }

                    HStack {
                        Text("Network")
                            .foregroundColor(.textSecondary)
                        Spacer()
                        ChainBadge(chain: address.chain)
                    }
                }
                .listRowBackground(Color.backgroundCard)

                Section("Notes (optional)") {
                    TextField("e.g. Exchange hot wallet", text: $notes)
                        .foregroundColor(.textPrimary)
                }
                .listRowBackground(Color.backgroundCard)

                Section {
                    HStack {
                        Text("Full Address")
                            .foregroundColor(.textSecondary)
                        Spacer()
                    }
                    Text(address.address)
                        .font(.caption.monospaced())
                        .foregroundColor(.textPrimary)
                        .textSelection(.enabled)
                }
                .listRowBackground(Color.backgroundCard)

                Section {
                    Button(role: .destructive) {
                        addressBook.removeAddress(id: address.id)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "trash.fill")
                            Text("Delete Address")
                        }
                        .foregroundColor(.error)
                    }
                }
                .listRowBackground(Color.backgroundCard)
            }
            .scrollContentBackground(.hidden)
            .background(Color.backgroundPrimary)
            .navigationTitle("Edit Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        addressBook.updateAddress(
                            id: address.id,
                            name: name,
                            notes: notes.isEmpty ? nil : notes
                        )
                        dismiss()
                    }
                    .foregroundColor(.accentGreen)
                    .bold()
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                name = address.name
                notes = address.notes ?? ""
            }
        }
    }
}

#Preview {
    NavigationStack {
        AddressBookView()
    }
}
