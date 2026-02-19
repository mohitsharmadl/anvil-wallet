import SwiftUI

/// NFTListView displays all NFTs across EVM chains in a 2-column grid layout.
/// Metadata (name, image) is lazy-loaded as each NFT card appears on screen.
struct NFTListView: View {
    @EnvironmentObject var walletService: WalletService
    @EnvironmentObject var router: AppRouter

    @State private var nfts: [NFTModel] = []
    @State private var isLoading = true
    @State private var searchText = ""

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    private var filteredNFTs: [NFTModel] {
        if searchText.isEmpty { return nfts }
        return nfts.filter { nft in
            (nft.name ?? "").localizedCaseInsensitiveContains(searchText) ||
            (nft.collectionName ?? "").localizedCaseInsensitiveContains(searchText) ||
            nft.contractAddress.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section header
            HStack {
                Text("NFTs")
                    .font(.title3.bold())
                    .foregroundColor(.textPrimary)

                Spacer()

                if !nfts.isEmpty {
                    Text("\(nfts.count)")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.textSecondary)
                }
            }
            .padding(.horizontal, 20)

            // Search bar
            if nfts.count > 4 {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline)
                        .foregroundColor(.textTertiary)

                    TextField("Search NFTs", text: $searchText)
                        .font(.subheadline)
                        .foregroundColor(.textPrimary)

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.subheadline)
                                .foregroundColor(.textTertiary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.backgroundCard)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)
            }

            // Content
            if isLoading {
                loadingView
            } else if filteredNFTs.isEmpty {
                emptyView
            } else {
                nftGrid
            }
        }
        .task {
            await loadNFTs()
        }
    }

    // MARK: - Grid

    private var nftGrid: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(filteredNFTs) { nft in
                Button {
                    router.walletPath.append(AppRouter.WalletDestination.nftDetail(nft: nft))
                } label: {
                    NFTCardView(nft: nft)
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(.accentGreen)

            Text("Discovering NFTs...")
                .font(.subheadline)
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Empty State

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.largeTitle)
                .foregroundColor(.textTertiary)

            Text(searchText.isEmpty ? "No NFTs found" : "No matching NFTs")
                .font(.subheadline)
                .foregroundColor(.textSecondary)

            if searchText.isEmpty {
                Text("NFTs you own on EVM chains will appear here")
                    .font(.caption)
                    .foregroundColor(.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Data Loading

    private func loadNFTs() async {
        // Load cached NFTs first for instant display
        if let ethAddress = walletService.addresses["ethereum"] {
            let cached = NFTService.shared.loadPersistedNFTs(for: ethAddress)
            if !cached.isEmpty {
                await MainActor.run { nfts = cached; isLoading = false }
            }
        }

        // Then refresh from network
        let discovered = await NFTService.shared.discoverNFTs(for: walletService.addresses)
        await MainActor.run {
            nfts = discovered
            isLoading = false
        }
    }
}

// MARK: - NFT Card

private struct NFTCardView: View {
    let nft: NFTModel

    @State private var loadedNFT: NFTModel?

    private var displayNFT: NFTModel {
        loadedNFT ?? nft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Image area
            ZStack {
                Color.backgroundElevated

                if let imageUrl = displayNFT.resolvedImageUrl {
                    AsyncImage(url: imageUrl) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure:
                            placeholderIcon
                        case .empty:
                            ProgressView()
                                .tint(.textTertiary)
                        @unknown default:
                            placeholderIcon
                        }
                    }
                } else {
                    placeholderIcon
                }
            }
            .frame(height: 160)
            .clipped()

            // Info area
            VStack(alignment: .leading, spacing: 4) {
                Text(displayNFT.displayCollectionName)
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.textTertiary)
                    .lineLimit(1)

                Text(displayNFT.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)

                // Chain badge
                HStack(spacing: 4) {
                    Circle()
                        .fill(chainColor(for: displayNFT.chain))
                        .frame(width: 8, height: 8)

                    Text(displayNFT.chain.capitalized)
                        .font(.caption2)
                        .foregroundColor(.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .background(Color.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .task {
            // Lazy-load metadata when card appears
            if nft.imageUrl == nil || nft.name == nil {
                let updated = await NFTService.shared.fetchMetadata(for: nft)
                await MainActor.run { loadedNFT = updated }
            }
        }
    }

    private var placeholderIcon: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.title2)
                .foregroundColor(.textTertiary)
            Text(nft.displayName)
                .font(.caption2)
                .foregroundColor(.textTertiary)
                .lineLimit(1)
                .padding(.horizontal, 8)
        }
    }

    private func chainColor(for chain: String) -> Color {
        switch chain {
        case "ethereum": return .chainEthereum
        case "polygon": return .chainPolygon
        case "arbitrum": return .chainArbitrum
        case "base": return .chainBase
        case "optimism": return .info
        case "bsc": return .warning
        case "avalanche": return .error
        default: return .textTertiary
        }
    }
}

#Preview {
    ScrollView {
        NFTListView()
            .environmentObject(WalletService.shared)
            .environmentObject(AppRouter())
    }
    .background(Color.backgroundPrimary)
}
