import SwiftUI

/// AddTokenView lets users manually add an ERC-20 or SPL token by pasting a contract address.
/// For EVM chains: fetches name, symbol, decimals from the contract via eth_call.
/// For Solana: user must provide name, symbol, decimals manually (no standard on-chain metadata).
struct AddTokenView: View {
    @EnvironmentObject var walletService: WalletService
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var selectedChain: ChainModel = .ethereum
    @State private var contractAddress: String = ""
    @State private var tokenName: String = ""
    @State private var tokenSymbol: String = ""
    @State private var tokenDecimals: String = ""

    @State private var isFetching = false
    @State private var hasFetched = false
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var showSuccess = false

    /// Chains that support custom token addition (EVM + Solana).
    private var supportedChains: [ChainModel] {
        ChainModel.defaults.filter { $0.chainType == .evm || $0.chainType == .solana }
    }

    private var isEVM: Bool {
        selectedChain.chainType == .evm
    }

    private var isSolana: Bool {
        selectedChain.chainType == .solana
    }

    /// Whether the form has enough data to save.
    private var canSave: Bool {
        !contractAddress.isEmpty &&
        !tokenName.isEmpty &&
        !tokenSymbol.isEmpty &&
        !tokenDecimals.isEmpty &&
        Int(tokenDecimals) != nil
    }

    /// Whether the address looks valid enough to attempt a fetch.
    private var canFetch: Bool {
        if isEVM {
            let clean = contractAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.hasPrefix("0x") && clean.count == 42
        }
        if isSolana {
            let clean = contractAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.count >= 32 && clean.count <= 44
        }
        return false
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    // Chain picker
                    chainPickerSection

                    // Contract address input
                    addressSection

                    // Token metadata (auto-fetched for EVM, manual for Solana)
                    if hasFetched || isSolana {
                        metadataSection
                    }

                    // Error
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.error)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                    }

                    // Success checkmark
                    if showSuccess {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.success)
                            Text("Token added successfully")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.success)
                        }
                        .padding(.top, 4)
                    }

                    // Save button
                    if canSave && !showSuccess {
                        Button {
                            saveToken()
                        } label: {
                            if isSaving {
                                ProgressView()
                                    .tint(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                            } else {
                                Text("Add Token")
                                    .font(.body.weight(.semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                            }
                        }
                        .background(Color.accentGreen)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 20)
                        .disabled(isSaving)
                    }

                    Spacer(minLength: 40)
                }
                .padding(.top, 8)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Add Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.accentGreen)
                }
            }
        }
    }

    // MARK: - Chain Picker

    private var chainPickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Network")
                .font(.subheadline.weight(.medium))
                .foregroundColor(.textSecondary)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(supportedChains) { chain in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedChain = chain
                                resetForm()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(chainColor(chain.id).opacity(0.15))
                                    .frame(width: 28, height: 28)
                                    .overlay(
                                        Text(chain.symbol.prefix(2))
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(chainColor(chain.id))
                                    )

                                Text(chain.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(selectedChain.id == chain.id ? .white : .textPrimary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(selectedChain.id == chain.id ? Color.accentGreen : Color.backgroundCard)
                            .clipShape(Capsule())
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Address Input

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Contract Address")
                .font(.subheadline.weight(.medium))
                .foregroundColor(.textSecondary)
                .padding(.horizontal, 20)

            HStack(spacing: 10) {
                TextField(isEVM ? "0x..." : "Token mint address", text: $contractAddress)
                    .font(.subheadline.monospaced())
                    .foregroundColor(.textPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: contractAddress) { _, _ in
                        // Reset fetched state when address changes
                        hasFetched = false
                        errorMessage = nil
                        showSuccess = false
                        if !isSolana {
                            tokenName = ""
                            tokenSymbol = ""
                            tokenDecimals = ""
                        }
                    }

                // Paste button
                Button {
                    if let clip = UIPasteboard.general.string {
                        contractAddress = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.subheadline)
                        .foregroundColor(.accentGreen)
                }

                // Fetch button (EVM only)
                if isEVM {
                    Button {
                        Task { await fetchTokenMetadata() }
                    } label: {
                        if isFetching {
                            ProgressView()
                                .tint(.accentGreen)
                        } else {
                            Image(systemName: "magnifyingglass")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(canFetch ? .accentGreen : .textTertiary)
                        }
                    }
                    .disabled(!canFetch || isFetching)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.backgroundCard)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Metadata Fields

    private var metadataSection: some View {
        VStack(spacing: 0) {
            // Token preview header
            if hasFetched && !tokenName.isEmpty {
                HStack(spacing: 14) {
                    // Token icon preview
                    Circle()
                        .fill(chainColor(selectedChain.id).opacity(0.15))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Text(String(tokenSymbol.prefix(1)))
                                .font(.headline.bold())
                                .foregroundColor(chainColor(selectedChain.id))
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(tokenSymbol)
                            .font(.body.weight(.semibold))
                            .foregroundColor(.textPrimary)
                        Text(tokenName)
                            .font(.caption)
                            .foregroundColor(.textTertiary)
                    }

                    Spacer()

                    Text(selectedChain.name)
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.backgroundSecondary)
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider().foregroundColor(.separator)
            }

            // Editable fields (always editable for Solana, read-only preview for EVM after fetch)
            VStack(spacing: 0) {
                metadataRow(label: "Name", text: $tokenName, editable: isSolana || !hasFetched)
                Divider().foregroundColor(.separator)
                metadataRow(label: "Symbol", text: $tokenSymbol, editable: isSolana || !hasFetched)
                Divider().foregroundColor(.separator)
                metadataRow(label: "Decimals", text: $tokenDecimals, editable: isSolana || !hasFetched, isNumeric: true)
            }
        }
        .background(Color.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20)
    }

    private func metadataRow(label: String, text: Binding<String>, editable: Bool, isNumeric: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.textSecondary)
                .frame(width: 80, alignment: .leading)

            if editable {
                TextField(label, text: text)
                    .font(.subheadline)
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(isNumeric ? .numberPad : .default)
            } else {
                Spacer()
                Text(text.wrappedValue)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.textPrimary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Actions

    private func fetchTokenMetadata() async {
        let address = contractAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.hasPrefix("0x"), address.count == 42 else {
            errorMessage = "Invalid EVM address. Must be 0x followed by 40 hex characters."
            return
        }

        isFetching = true
        errorMessage = nil

        do {
            let metadata = try await ManualTokenService.fetchERC20Metadata(
                rpcUrl: selectedChain.activeRpcUrl,
                contractAddress: address
            )
            await MainActor.run {
                tokenName = metadata.name
                tokenSymbol = metadata.symbol
                tokenDecimals = "\(metadata.decimals)"
                hasFetched = true
                isFetching = false
            }
        } catch {
            await MainActor.run {
                errorMessage = "Could not fetch token info. Check the address and network."
                isFetching = false
            }
        }
    }

    private func saveToken() {
        let address = contractAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decimals = Int(tokenDecimals), decimals >= 0, decimals <= 18 else {
            errorMessage = "Decimals must be between 0 and 18."
            return
        }

        isSaving = true
        errorMessage = nil

        let discovered = TokenDiscoveryService.DiscoveredToken(
            contractAddress: address,
            symbol: tokenSymbol.trimmingCharacters(in: .whitespaces),
            name: tokenName.trimmingCharacters(in: .whitespaces),
            decimals: decimals,
            chain: selectedChain.id
        )

        // Determine the wallet address for scoping persistence
        let walletAddress = walletService.addresses["ethereum"] ?? walletService.addresses["solana"] ?? ""

        Task {
            // Persist to ManualTokenService
            await ManualTokenService.shared.addToken(discovered, for: walletAddress)

            // Merge into live token list
            await walletService.mergeDiscoveredTokens([discovered])

            await MainActor.run {
                isSaving = false
                showSuccess = true
            }

            // Auto-dismiss after brief delay
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                dismiss()
            }
        }
    }

    private func resetForm() {
        contractAddress = ""
        tokenName = ""
        tokenSymbol = ""
        tokenDecimals = ""
        hasFetched = false
        errorMessage = nil
        showSuccess = false
    }

    private func chainColor(_ chainId: String) -> Color {
        switch chainId {
        case "ethereum": return .chainEthereum
        case "polygon": return .chainPolygon
        case "arbitrum": return .chainArbitrum
        case "base": return .chainBase
        case "optimism": return .red
        case "bsc": return .yellow
        case "avalanche": return .red
        case "solana": return .chainSolana
        case "zcash", "zcash_testnet": return .chainZcash
        default: return .accentGreen
        }
    }
}

#Preview {
    AddTokenView()
        .environmentObject(WalletService.shared)
}
