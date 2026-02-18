import SwiftUI

/// ChainPickerView lets the user select which chain to receive on.
/// Shows all chains that have a derived address in the wallet.
struct ChainPickerView: View {
    @EnvironmentObject var walletService: WalletService
    @EnvironmentObject var router: AppRouter

    private var availableChains: [(chain: ChainModel, address: String)] {
        ChainModel.defaults.compactMap { chain in
            guard let address = walletService.addresses[chain.id] else { return nil }
            return (chain: chain, address: address)
        }
    }

    var body: some View {
        List(availableChains, id: \.chain.id) { item in
            Button {
                router.walletPath.append(
                    AppRouter.WalletDestination.receive(chain: item.chain.id, address: item.address)
                )
            } label: {
                HStack(spacing: 14) {
                    // Chain icon — colored circle with symbol
                    Circle()
                        .fill(chainColor(item.chain.id).opacity(0.15))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Text(item.chain.symbol.prefix(3))
                                .font(.caption.bold())
                                .foregroundColor(chainColor(item.chain.id))
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.chain.name)
                            .font(.body.bold())
                            .foregroundColor(.textPrimary)

                        Text(shortenAddress(item.address))
                            .font(.caption.monospaced())
                            .foregroundColor(.textTertiary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.backgroundPrimary)
            .listRowSeparatorTint(Color.separator)
        }
        .listStyle(.plain)
        .background(Color.backgroundPrimary)
        .navigationTitle("Select Network")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func shortenAddress(_ address: String) -> String {
        guard address.count > 14 else { return address }
        return "\(address.prefix(8))...\(address.suffix(6))"
    }

    private func chainColor(_ chainId: String) -> Color {
        switch chainId {
        case "ethereum": return .blue
        case "polygon": return .purple
        case "arbitrum": return .blue
        case "base": return .blue
        case "optimism": return .red
        case "bsc": return .yellow
        case "avalanche": return .red
        case "solana": return .purple
        case "bitcoin": return .orange
        default: return .accentGreen
        }
    }
}

#Preview {
    NavigationStack {
        ChainPickerView()
            .environmentObject(WalletService.shared)
            .environmentObject(AppRouter())
    }
}
