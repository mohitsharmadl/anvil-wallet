import Foundation

/// Represents a single NFT (ERC-721 or ERC-1155) held by the wallet.
struct NFTModel: Identifiable, Codable, Hashable {
    /// Unique identifier: contractAddress_tokenId_chain
    let id: String
    let contractAddress: String
    let tokenId: String
    let name: String?
    let description: String?
    let imageUrl: String?
    let collectionName: String?
    let chain: String
    let tokenStandard: String // "ERC-721" or "ERC-1155"

    /// Display name: falls back to collection + tokenId if name is nil.
    var displayName: String {
        if let name, !name.isEmpty {
            return name
        }
        if let collectionName, !collectionName.isEmpty {
            return "\(collectionName) #\(tokenId)"
        }
        return "#\(tokenId)"
    }

    /// Display collection name with fallback.
    var displayCollectionName: String {
        if let collectionName, !collectionName.isEmpty {
            return collectionName
        }
        return truncatedContract
    }

    /// Truncated contract address for display (0x1234...abcd).
    var truncatedContract: String {
        guard contractAddress.count > 10 else { return contractAddress }
        return String(contractAddress.prefix(6)) + "..." + String(contractAddress.suffix(4))
    }

    /// Resolved image URL: converts IPFS URIs to HTTP gateway URLs.
    var resolvedImageUrl: URL? {
        guard let imageUrl, !imageUrl.isEmpty else { return nil }
        let resolved = Self.resolveIpfsUrl(imageUrl)
        return URL(string: resolved)
    }

    /// Converts IPFS URIs (ipfs://...) to HTTP gateway URLs.
    static func resolveIpfsUrl(_ urlString: String) -> String {
        if urlString.hasPrefix("ipfs://") {
            let path = String(urlString.dropFirst(7))
            return "https://ipfs.io/ipfs/\(path)"
        }
        // Handle ipfs:// inside data URIs or other nested cases
        if urlString.contains("ipfs://") {
            return urlString.replacingOccurrences(of: "ipfs://", with: "https://ipfs.io/ipfs/")
        }
        return urlString
    }

    /// Block explorer URL for the NFT contract + tokenId.
    func explorerUrl(for chainModel: ChainModel) -> URL? {
        URL(string: "\(chainModel.explorerUrl)/nft/\(contractAddress)/\(tokenId)")
    }
}
