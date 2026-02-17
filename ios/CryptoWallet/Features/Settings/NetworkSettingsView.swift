import SwiftUI

/// NetworkSettingsView allows users to manage blockchain networks,
/// including switching between mainnet and testnet and adding custom RPCs.
struct NetworkSettingsView: View {
    @State private var showTestnets = false
    @State private var showAddNetwork = false

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
                    NetworkRow(chain: chain)
                }
            }
            .listRowBackground(Color.backgroundCard)

            // Add custom network
            Section {
                Button {
                    showAddNetwork = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.accentGreen)

                        Text("Add Custom Network")
                            .foregroundColor(.accentGreen)
                    }
                }
            }
            .listRowBackground(Color.backgroundCard)
        }
        .scrollContentBackground(.hidden)
        .background(Color.backgroundPrimary)
        .navigationTitle("Networks")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddNetwork) {
            AddNetworkSheet()
        }
    }
}

// MARK: - Network Row

private struct NetworkRow: View {
    let chain: ChainModel

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
                }

                Text(chain.rpcUrl)
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
        case "polygon": return .chainPolygon
        case "arbitrum": return .chainArbitrum
        case "base": return .chainBase
        case "solana": return .chainSolana
        case "bitcoin": return .chainBitcoin
        default: return .textTertiary
        }
    }
}

// MARK: - Add Network Sheet

private struct AddNetworkSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var networkName = ""
    @State private var rpcUrl = ""
    @State private var chainId = ""
    @State private var symbol = ""
    @State private var explorerUrl = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Network Details") {
                    TextField("Network Name", text: $networkName)
                    TextField("RPC URL", text: $rpcUrl)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    TextField("Chain ID", text: $chainId)
                        .keyboardType(.numberPad)
                    TextField("Currency Symbol", text: $symbol)
                        .autocapitalization(.allCharacters)
                    TextField("Block Explorer URL (optional)", text: $explorerUrl)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Add Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        // TODO: Save custom network
                        dismiss()
                    }
                    .disabled(networkName.isEmpty || rpcUrl.isEmpty || symbol.isEmpty)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        NetworkSettingsView()
    }
}
