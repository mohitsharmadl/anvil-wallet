import SwiftUI

/// NFTDetailView shows full details for a single NFT: large image, metadata, and contract info.
struct NFTDetailView: View {
    let nft: NFTModel

    @State private var loadedNFT: NFTModel?
    @State private var copiedAddress = false

    private var displayNFT: NFTModel {
        loadedNFT ?? nft
    }

    private var chain: ChainModel? {
        ChainModel.defaults.first(where: { $0.id == nft.chain })
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {
                // Full image
                imageSection
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                // Name and collection
                headerSection
                    .padding(.horizontal, 20)

                // Description
                if let description = displayNFT.description, !description.isEmpty {
                    descriptionSection(description)
                        .padding(.horizontal, 20)
                }

                // Details card
                detailsCard
                    .padding(.horizontal, 20)

                // View on Explorer button
                if let chain, let url = displayNFT.explorerUrl(for: chain) {
                    Link(destination: url) {
                        HStack(spacing: 8) {
                            Image(systemName: "safari")
                                .font(.subheadline.weight(.medium))
                            Text("View on \(chain.name) Explorer")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundColor(.accentGreen)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentGreen.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.horizontal, 20)
                }

                Spacer(minLength: 32)
            }
        }
        .background(Color.backgroundPrimary)
        .navigationTitle(displayNFT.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Load metadata if not yet available
            if nft.imageUrl == nil || nft.name == nil {
                let updated = await NFTService.shared.fetchMetadata(for: nft)
                await MainActor.run { loadedNFT = updated }
            }
        }
    }

    // MARK: - Image Section

    private var imageSection: some View {
        ZStack {
            Color.backgroundElevated

            if let imageUrl = displayNFT.resolvedImageUrl {
                AsyncImage(url: imageUrl) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    case .failure:
                        imagePlaceholder
                    case .empty:
                        ProgressView()
                            .tint(.textTertiary)
                    @unknown default:
                        imagePlaceholder
                    }
                }
            } else {
                imagePlaceholder
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var imagePlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo")
                .font(.system(size: 48))
                .foregroundColor(.textTertiary)

            Text("Image unavailable")
                .font(.subheadline)
                .foregroundColor(.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Collection name
            Text(displayNFT.displayCollectionName)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.textSecondary)

            // NFT name
            Text(displayNFT.displayName)
                .font(.title2.bold())
                .foregroundColor(.textPrimary)

            // Chain badge
            HStack(spacing: 6) {
                Circle()
                    .fill(chainColor)
                    .frame(width: 10, height: 10)

                Text(nft.chain.capitalized)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.textSecondary)

                Text(nft.tokenStandard)
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.backgroundElevated)
                    .clipShape(Capsule())
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Description

    private func descriptionSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.headline)
                .foregroundColor(.textPrimary)

            Text(text)
                .font(.subheadline)
                .foregroundColor(.textSecondary)
                .lineLimit(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Details Card

    private var detailsCard: some View {
        VStack(spacing: 0) {
            // Contract Address
            HStack {
                Text("Contract")
                    .font(.subheadline)
                    .foregroundColor(.textSecondary)
                Spacer()
                Text(nft.truncatedContract)
                    .font(.subheadline.monospaced())
                    .foregroundColor(.textPrimary)
                Button {
                    ClipboardManager.shared.copyToClipboard(nft.contractAddress)
                    copiedAddress = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedAddress = false
                    }
                } label: {
                    Image(systemName: copiedAddress ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundColor(.accentGreen)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().foregroundColor(.separator)

            // Token ID
            detailRow(label: "Token ID", value: nft.tokenId.count > 12
                ? String(nft.tokenId.prefix(12)) + "..."
                : nft.tokenId
            )

            Divider().foregroundColor(.separator)

            // Standard
            detailRow(label: "Standard", value: nft.tokenStandard)

            Divider().foregroundColor(.separator)

            // Network
            detailRow(label: "Network", value: nft.chain.capitalized)
        }
        .background(Color.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundColor(.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Helpers

    private var chainColor: Color {
        switch nft.chain {
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
    NavigationStack {
        NFTDetailView(nft: NFTModel(
            id: "0x1234_1_ethereum",
            contractAddress: "0x1234567890abcdef1234567890abcdef12345678",
            tokenId: "1",
            name: "Cool Ape #1234",
            description: "A very cool ape from the Cool Apes collection. This NFT represents membership in an exclusive digital art community.",
            imageUrl: nil,
            collectionName: "Cool Apes",
            chain: "ethereum",
            tokenStandard: "ERC-721"
        ))
    }
}
