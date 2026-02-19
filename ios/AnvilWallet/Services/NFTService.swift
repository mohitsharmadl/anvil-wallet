import Foundation

/// Fetches and caches NFTs for EVM chains using Etherscan-family APIs and on-chain tokenURI calls.
///
/// Discovery flow:
///   1. Fetch NFT transfer events from *scan API (tokennfttx)
///   2. Deduplicate to determine current holdings (last transfer TO this address)
///   3. For each held NFT, call tokenURI on-chain to get metadata URI
///   4. Fetch metadata JSON from the URI (IPFS or HTTP)
///   5. Parse name, description, image from the metadata
///   6. Cache results to UserDefaults for fast subsequent loads
actor NFTService {

    static let shared = NFTService()

    private static let persistenceKeyPrefix = "com.anvilwallet.nfts."
    private let rpc = RPCService.shared
    private let etherscan = EtherscanService.shared

    /// In-memory metadata cache to avoid redundant tokenURI + metadata fetches.
    private var metadataCache: [String: NFTMetadata] = [:]

    private init() {}

    // MARK: - Public API

    /// Discovers all NFTs held by the address across all supported EVM chains.
    /// Returns cached data immediately if available, then refreshes in background.
    func discoverNFTs(for addresses: [String: String]) async -> [NFTModel] {
        var allNFTs: [NFTModel] = []

        for chain in ChainModel.defaults where chain.chainType == .evm {
            guard let address = addresses[chain.id],
                  let explorerApiUrl = chain.explorerApiUrl else { continue }

            do {
                let nfts = try await fetchNFTsForChain(
                    chain: chain,
                    address: address,
                    explorerApiUrl: explorerApiUrl
                )
                allNFTs.append(contentsOf: nfts)
            } catch {
                // Non-fatal: skip chains that fail (rate limits, unsupported endpoints)
                continue
            }
        }

        // Persist for fast reload
        if let ethAddress = addresses["ethereum"] {
            persist(allNFTs, for: ethAddress)
        }

        return allNFTs
    }

    /// Fetches metadata for a single NFT lazily (called when the NFT appears on screen).
    /// Returns an updated NFTModel with metadata fields populated.
    func fetchMetadata(for nft: NFTModel) async -> NFTModel {
        let cacheKey = "\(nft.contractAddress)_\(nft.tokenId)_\(nft.chain)"

        // Check in-memory cache first
        if let cached = metadataCache[cacheKey] {
            return nft.withMetadata(cached)
        }

        guard let chain = ChainModel.defaults.first(where: { $0.id == nft.chain }) else {
            return nft
        }

        do {
            // Call tokenURI(tokenId) on the NFT contract
            let tokenUri = try await fetchTokenURI(
                contractAddress: nft.contractAddress,
                tokenId: nft.tokenId,
                rpcUrl: chain.activeRpcUrl
            )

            guard let tokenUri, !tokenUri.isEmpty else { return nft }

            // Fetch and parse the metadata JSON
            let metadata = try await fetchMetadataFromUri(tokenUri)
            metadataCache[cacheKey] = metadata
            return nft.withMetadata(metadata)
        } catch {
            return nft
        }
    }

    // MARK: - Chain-level Fetching

    private func fetchNFTsForChain(
        chain: ChainModel,
        address: String,
        explorerApiUrl: String
    ) async throws -> [NFTModel] {
        let transfers = try await fetchNFTTransfers(
            address: address,
            explorerApiUrl: explorerApiUrl
        )

        // Deduplicate: for each (contract, tokenId), check if the last transfer
        // was TO this address (meaning we still hold it)
        let held = deduplicateHoldings(transfers: transfers, ownerAddress: address)

        return held.map { transfer in
            NFTModel(
                id: "\(transfer.contractAddress.lowercased())_\(transfer.tokenID)_\(chain.id)",
                contractAddress: transfer.contractAddress,
                tokenId: transfer.tokenID,
                name: nil, // Lazy-loaded via fetchMetadata
                description: nil,
                imageUrl: nil,
                collectionName: transfer.tokenName.isEmpty ? nil : transfer.tokenName,
                chain: chain.id,
                tokenStandard: "ERC-721"
            )
        }
    }

    // MARK: - Etherscan NFT Transfers

    private struct NFTTransfer: Decodable {
        let blockNumber: String
        let contractAddress: String
        let tokenID: String
        let tokenName: String
        let tokenSymbol: String
        let from: String
        let to: String
    }

    private func fetchNFTTransfers(
        address: String,
        explorerApiUrl: String
    ) async throws -> [NFTTransfer] {
        // Use the EtherscanService's underlying rate-limited request by building URL manually
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60

        let session = URLSession(
            configuration: config,
            delegate: CertificatePinner(),
            delegateQueue: nil
        )

        let apiKey = Bundle.main.object(forInfoDictionaryKey: "EtherscanApiKey") as? String ?? ""

        var components = URLComponents(string: explorerApiUrl)!
        var queryItems = [
            URLQueryItem(name: "module", value: "account"),
            URLQueryItem(name: "action", value: "tokennfttx"),
            URLQueryItem(name: "address", value: address),
            URLQueryItem(name: "startblock", value: "0"),
            URLQueryItem(name: "endblock", value: "99999999"),
            URLQueryItem(name: "sort", value: "desc"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "offset", value: "200"),
        ]

        if !apiKey.isEmpty, let host = components.host,
           host.hasSuffix("etherscan.io") || host.hasSuffix("etherscan.com") {
            queryItems.append(URLQueryItem(name: "apikey", value: apiKey))
        }

        components.queryItems = queryItems
        guard let url = components.url else { throw NFTError.invalidURL }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NFTError.httpError
        }

        struct Response: Decodable {
            let status: String
            let result: [NFTTransfer]?
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard decoded.status == "1", let transfers = decoded.result else {
            return []
        }

        return transfers
    }

    /// Deduplicates transfer events to determine which NFTs the address currently holds.
    /// For each unique (contract, tokenId), looks at the most recent transfer:
    /// if `to` matches the owner address, the NFT is still held.
    private func deduplicateHoldings(transfers: [NFTTransfer], ownerAddress: String) -> [NFTTransfer] {
        let owner = ownerAddress.lowercased()

        // Group by (contract, tokenId), keep the first (most recent, since sorted desc)
        var seen = Set<String>()
        var held: [NFTTransfer] = []

        for transfer in transfers {
            let key = "\(transfer.contractAddress.lowercased())_\(transfer.tokenID)"
            guard seen.insert(key).inserted else { continue }

            // Most recent transfer for this NFT: if it was TO us, we still hold it
            if transfer.to.lowercased() == owner {
                held.append(transfer)
            }
        }

        return held
    }

    // MARK: - On-chain tokenURI

    /// Calls tokenURI(uint256) on an ERC-721 contract.
    /// Function selector: 0xc87b56dd
    private func fetchTokenURI(
        contractAddress: String,
        tokenId: String,
        rpcUrl: String
    ) async throws -> String? {
        // ABI-encode tokenId as uint256 (left-padded to 32 bytes)
        let tokenIdBigInt = tokenId
        guard let tokenIdValue = UInt64(tokenIdBigInt) else { return nil }
        let tokenIdHex = String(tokenIdValue, radix: 16)
        let paddedTokenId = String(repeating: "0", count: max(0, 64 - tokenIdHex.count)) + tokenIdHex

        let callData = "0xc87b56dd" + paddedTokenId

        let result: String = try await rpc.ethCall(
            rpcUrl: rpcUrl,
            to: contractAddress,
            data: callData
        )

        // Decode ABI-encoded string from the response
        return decodeAbiString(result)
    }

    /// Decodes an ABI-encoded string return value.
    /// Format: offset (32 bytes) + length (32 bytes) + data (length bytes, right-padded)
    private func decodeAbiString(_ hex: String) -> String? {
        let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        // Minimum: 64 hex chars for offset + 64 for length = 128
        guard clean.count >= 128 else { return nil }

        // Read offset (first 32 bytes = 64 hex chars)
        let offsetHex = String(clean.prefix(64))
        guard let offset = UInt64(offsetHex, radix: 16) else { return nil }
        let dataStart = Int(offset * 2) // Convert byte offset to hex char offset

        guard clean.count >= dataStart + 64 else { return nil }

        // Read length at offset
        let lengthHex = String(clean[clean.index(clean.startIndex, offsetBy: dataStart)..<clean.index(clean.startIndex, offsetBy: dataStart + 64)])
        guard let length = UInt64(lengthHex, radix: 16), length > 0, length < 10000 else { return nil }

        let stringStart = dataStart + 64
        let stringEnd = stringStart + Int(length * 2)
        guard clean.count >= stringEnd else { return nil }

        let stringHex = String(clean[clean.index(clean.startIndex, offsetBy: stringStart)..<clean.index(clean.startIndex, offsetBy: stringEnd)])

        // Convert hex to bytes to string
        var bytes: [UInt8] = []
        var i = stringHex.startIndex
        while i < stringHex.endIndex {
            let nextIndex = stringHex.index(i, offsetBy: 2, limitedBy: stringHex.endIndex) ?? stringHex.endIndex
            if let byte = UInt8(stringHex[i..<nextIndex], radix: 16) {
                bytes.append(byte)
            }
            i = nextIndex
        }

        return String(bytes: bytes, encoding: .utf8)
    }

    // MARK: - Metadata Fetching

    struct NFTMetadata {
        let name: String?
        let description: String?
        let imageUrl: String?
    }

    private func fetchMetadataFromUri(_ uri: String) async throws -> NFTMetadata {
        // Resolve IPFS URIs
        let resolvedUrl = NFTModel.resolveIpfsUrl(uri)

        // Handle data URIs (base64-encoded JSON)
        if resolvedUrl.hasPrefix("data:application/json;base64,") {
            let base64Part = String(resolvedUrl.dropFirst("data:application/json;base64,".count))
            guard let data = Data(base64Encoded: base64Part) else {
                throw NFTError.invalidMetadata
            }
            return try parseMetadataJson(data)
        }

        if resolvedUrl.hasPrefix("data:application/json,") {
            let jsonPart = String(resolvedUrl.dropFirst("data:application/json,".count))
            guard let decoded = jsonPart.removingPercentEncoding,
                  let data = decoded.data(using: .utf8) else {
                throw NFTError.invalidMetadata
            }
            return try parseMetadataJson(data)
        }

        guard let url = URL(string: resolvedUrl) else { throw NFTError.invalidURL }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NFTError.httpError
        }

        return try parseMetadataJson(data)
    }

    private func parseMetadataJson(_ data: Data) throws -> NFTMetadata {
        struct MetadataResponse: Decodable {
            let name: String?
            let description: String?
            let image: String?
            let image_url: String?
        }

        let metadata = try JSONDecoder().decode(MetadataResponse.self, from: data)
        let imageUrl = metadata.image ?? metadata.image_url

        return NFTMetadata(
            name: metadata.name,
            description: metadata.description,
            imageUrl: imageUrl
        )
    }

    // MARK: - Persistence

    private func persist(_ nfts: [NFTModel], for address: String) {
        guard let data = try? JSONEncoder().encode(nfts) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey(for: address))
    }

    /// Loads previously cached NFTs from UserDefaults for a specific wallet address.
    nonisolated func loadPersistedNFTs(for address: String) -> [NFTModel] {
        let key = Self.persistenceKeyPrefix + address.lowercased()
        guard let data = UserDefaults.standard.data(forKey: key),
              let nfts = try? JSONDecoder().decode([NFTModel].self, from: data) else {
            return []
        }
        return nfts
    }

    /// Clears persisted NFTs for a specific wallet address.
    nonisolated func clearPersistedNFTs(for address: String) {
        let key = Self.persistenceKeyPrefix + address.lowercased()
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func persistenceKey(for address: String) -> String {
        Self.persistenceKeyPrefix + address.lowercased()
    }

    // MARK: - Errors

    enum NFTError: LocalizedError {
        case invalidURL
        case httpError
        case invalidMetadata

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL for NFT request."
            case .httpError: return "NFT API request failed."
            case .invalidMetadata: return "Failed to parse NFT metadata."
            }
        }
    }
}

// MARK: - NFTModel Metadata Helper

extension NFTModel {
    /// Returns a copy of this NFT with metadata fields populated.
    func withMetadata(_ metadata: NFTService.NFTMetadata) -> NFTModel {
        NFTModel(
            id: id,
            contractAddress: contractAddress,
            tokenId: tokenId,
            name: metadata.name ?? name,
            description: metadata.description ?? description,
            imageUrl: metadata.imageUrl ?? imageUrl,
            collectionName: collectionName,
            chain: chain,
            tokenStandard: tokenStandard
        )
    }
}
