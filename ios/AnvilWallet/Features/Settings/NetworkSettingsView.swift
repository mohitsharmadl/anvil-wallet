import SwiftUI

/// NetworkSettingsView allows users to manage blockchain networks,
/// including switching between mainnet and testnet and setting custom RPC URLs.
struct NetworkSettingsView: View {
    @StateObject private var rpcStore = CustomRPCStore.shared
    @State private var showTestnets = false
    @State private var selectedChain: ChainModel?

    private var displayedChains: [ChainModel] {
        if showTestnets {
            return ChainModel.allChains
        }
        return ChainModel.allChains.filter { !$0.isTestnet }
    }

    var body: some View {
        List {
            // Testnet toggle
            Section {
                Toggle(isOn: $showTestnets) {
                    HStack(spacing: 12) {
                        Image(systemName: "testtube.2")
                            .foregroundColor(.warning)

                        VStack(alignment: .leading) {
                            Text("Show Testnets")
                                .foregroundColor(.textPrimary)
                            Text("Enable testnet networks for development")
                                .font(.caption)
                                .foregroundColor(.textSecondary)
                        }
                    }
                }
                .tint(.accentGreen)
            }
            .listRowBackground(Color.backgroundCard)

            // Networks list
            Section("Networks") {
                ForEach(displayedChains) { chain in
                    Button {
                        selectedChain = chain
                    } label: {
                        NetworkRow(chain: chain, rpcStore: rpcStore)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowBackground(Color.backgroundCard)
        }
        .scrollContentBackground(.hidden)
        .background(Color.backgroundPrimary)
        .navigationTitle("Networks")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedChain) { chain in
            EditRPCSheet(chain: chain, rpcStore: rpcStore)
        }
    }
}

// MARK: - Network Row

private struct NetworkRow: View {
    let chain: ChainModel
    @ObservedObject var rpcStore: CustomRPCStore

    private var isCustom: Bool {
        rpcStore.hasCustomUrl(for: chain)
    }

    private var activeUrl: String {
        rpcStore.activeRpcUrl(for: chain)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Chain icon
            Circle()
                .fill(chainColor.opacity(0.2))
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(chain.symbol.prefix(1)))
                        .font(.headline.bold())
                        .foregroundColor(chainColor)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(chain.name)
                        .font(.body)
                        .foregroundColor(.textPrimary)

                    if chain.isTestnet {
                        Text("Testnet")
                            .font(.caption2.bold())
                            .foregroundColor(.warning)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.warning.opacity(0.1))
                            .cornerRadius(4)
                    }

                    if isCustom {
                        Text("Custom")
                            .font(.caption2.bold())
                            .foregroundColor(.info)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.info.opacity(0.1))
                            .cornerRadius(4)
                    }
                }

                Text(activeUrl)
                    .font(.caption)
                    .foregroundColor(.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            // Status indicator
            Circle()
                .fill(Color.success)
                .frame(width: 8, height: 8)
        }
    }

    private var chainColor: Color {
        switch chain.id {
        case "ethereum", "sepolia": return .chainEthereum
        case "polygon", "polygon_amoy": return .chainPolygon
        case "arbitrum": return .chainArbitrum
        case "base": return .chainBase
        case "solana", "solana_devnet": return .chainSolana
        case "bitcoin", "bitcoin_testnet": return .chainBitcoin
        case "zcash", "zcash_testnet": return .chainZcash
        default: return .textTertiary
        }
    }
}

// MARK: - Edit RPC Sheet

private struct EditRPCSheet: View {
    let chain: ChainModel
    @ObservedObject var rpcStore: CustomRPCStore
    @Environment(\.dismiss) private var dismiss

    @State private var customUrl = ""
    @State private var validationError: String?
    @State private var isTesting = false
    @State private var testResult: CustomRPCStore.ConnectivityResult?

    private var isCustom: Bool {
        rpcStore.hasCustomUrl(for: chain)
    }

    private var activeUrl: String {
        rpcStore.activeRpcUrl(for: chain)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Current RPC info
                Section("Current RPC") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(isCustom ? "Custom URL" : "Default URL")
                                .font(.caption.bold())
                                .foregroundColor(isCustom ? .info : .textSecondary)

                            Spacer()

                            if isCustom {
                                Text("Custom")
                                    .font(.caption2.bold())
                                    .foregroundColor(.info)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.info.opacity(0.1))
                                    .cornerRadius(4)
                            }
                        }

                        Text(activeUrl)
                            .font(.callout.monospaced())
                            .foregroundColor(.textPrimary)
                            .lineLimit(2)
                    }

                    if isCustom {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Default URL")
                                .font(.caption.bold())
                                .foregroundColor(.textSecondary)

                            Text(chain.rpcUrl)
                                .font(.callout.monospaced())
                                .foregroundColor(.textTertiary)
                                .lineLimit(2)
                        }
                    }
                }

                // Custom URL input
                Section {
                    TextField("https://your-rpc-endpoint.com", text: $customUrl)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onChange(of: customUrl) {
                            validationError = nil
                            testResult = nil
                        }

                    if let error = validationError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.error)
                    }

                    // Test connectivity button
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .tint(.textSecondary)
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "bolt.fill")
                            }
                            Text(isTesting ? "Testing..." : "Test Connection")
                        }
                        .foregroundColor(customUrl.isEmpty ? .textTertiary : .info)
                    }
                    .disabled(customUrl.isEmpty || isTesting)

                    if let result = testResult {
                        HStack(spacing: 6) {
                            switch result {
                            case .success(let msg):
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.success)
                                Text(msg)
                                    .font(.caption)
                                    .foregroundColor(.success)
                            case .failure(let msg):
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.error)
                                Text(msg)
                                    .font(.caption)
                                    .foregroundColor(.error)
                                    .lineLimit(3)
                            }
                        }
                    }
                } header: {
                    Text("Custom RPC URL")
                } footer: {
                    Text("Only HTTPS URLs are allowed. The custom URL will override the default for all \(chain.name) operations.")
                        .font(.caption)
                }

                // Save button
                Section {
                    Button {
                        saveCustomUrl()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Save Custom RPC")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .foregroundColor(.white)
                    }
                    .disabled(customUrl.isEmpty)
                    .listRowBackground(
                        customUrl.isEmpty
                        ? Color.accentGreen.opacity(0.3)
                        : Color.accentGreen
                    )
                }

                // Reset to default
                if isCustom {
                    Section {
                        Button(role: .destructive) {
                            rpcStore.resetToDefault(for: chain)
                            customUrl = ""
                            testResult = nil
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.counterclockwise")
                                Text("Reset to Default")
                            }
                            .foregroundColor(.error)
                        }
                    } footer: {
                        Text("Removes the custom RPC URL and reverts to the built-in default.")
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(chain.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                // Pre-fill with existing custom URL if there is one
                if let existing = rpcStore.overrides[chain.id] {
                    customUrl = existing
                }
            }
        }
    }

    private func saveCustomUrl() {
        let validation = CustomRPCStore.validateUrl(customUrl)
        guard validation.isValid else {
            validationError = validation.errorMessage
            return
        }

        rpcStore.setCustomUrl(customUrl, for: chain)
        dismiss()
    }

    private func testConnection() async {
        let validation = CustomRPCStore.validateUrl(customUrl)
        guard validation.isValid else {
            validationError = validation.errorMessage
            return
        }

        isTesting = true
        testResult = nil

        let result = await rpcStore.testConnectivity(
            url: customUrl.trimmingCharacters(in: .whitespacesAndNewlines),
            chainType: chain.chainType
        )

        await MainActor.run {
            testResult = result
            isTesting = false
        }
    }
}

#Preview {
    NavigationStack {
        NetworkSettingsView()
    }
}
