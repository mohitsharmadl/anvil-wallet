import SwiftUI

struct WatchAddressesView: View {
    @ObservedObject private var service = WatchAddressService.shared

    @State private var name = ""
    @State private var address = ""
    @State private var chainId = "ethereum"
    @State private var validationError: String?

    private var chains: [ChainModel] {
        ChainModel.defaults
    }

    var body: some View {
        List {
            Section("Add Watch Address") {
                TextField("Label (optional)", text: $name)
                TextField("Address", text: $address)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()

                Picker("Chain", selection: $chainId) {
                    ForEach(chains, id: \.id) { chain in
                        Text(chain.name).tag(chain.id)
                    }
                }

                if let validationError {
                    Text(validationError)
                        .font(.caption)
                        .foregroundColor(.error)
                }

                Button {
                    addWatchAddress()
                } label: {
                    HStack {
                        Spacer()
                        Text("Add")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
            }
            .listRowBackground(Color.backgroundCard)

            Section("Watched") {
                if service.watchAddresses.isEmpty {
                    Text("No watch addresses yet.")
                        .foregroundColor(.textTertiary)
                } else {
                    ForEach(service.watchAddresses) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.name)
                                    .font(.subheadline.bold())
                                    .foregroundColor(.textPrimary)
                                Spacer()
                                Text(chainName(for: item.chainId))
                                    .font(.caption)
                                    .foregroundColor(.textSecondary)
                            }
                            Text(shortAddress(item.address))
                                .font(.caption.monospaced())
                                .foregroundColor(.textTertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete(perform: deleteItems)
                }
            }
            .listRowBackground(Color.backgroundCard)
        }
        .scrollContentBackground(.hidden)
        .background(Color.backgroundPrimary)
        .navigationTitle("Watch Addresses")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addWatchAddress() {
        validationError = nil
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationError = "Address is required"
            return
        }

        if let rustChain = rustChain(for: chainId) {
            let valid = (try? validateAddress(address: trimmed, chain: rustChain)) ?? false
            if !valid {
                validationError = "Invalid address for selected chain"
                return
            }
        }

        service.add(name: name, address: trimmed, chainId: chainId)
        name = ""
        address = ""
    }

    private func deleteItems(offsets: IndexSet) {
        for index in offsets {
            service.remove(id: service.watchAddresses[index].id)
        }
    }

    private func chainName(for chainId: String) -> String {
        ChainModel.allChains.first(where: { $0.id == chainId })?.name ?? chainId
    }

    private func shortAddress(_ addr: String) -> String {
        guard addr.count > 12 else { return addr }
        return "\(addr.prefix(8))...\(addr.suffix(6))"
    }

    private func rustChain(for chainId: String) -> Chain? {
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
        case "zcash": return .zcash
        default: return nil
        }
    }
}

