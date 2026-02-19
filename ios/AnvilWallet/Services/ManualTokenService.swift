import Foundation

/// Persists manually added custom tokens (ERC-20 / SPL) to UserDefaults.
/// Tokens are scoped per wallet address so multiple wallets don't share custom lists.
///
/// Uses the same DiscoveredToken type from TokenDiscoveryService for consistency --
/// manually added tokens flow through the same merge path as auto-discovered ones.
actor ManualTokenService {

    static let shared = ManualTokenService()

    private static let persistenceKeyPrefix = "com.anvilwallet.manualTokens."

    private init() {}

    // MARK: - Persistence Key

    private func persistenceKey(for address: String) -> String {
        Self.persistenceKeyPrefix + address.lowercased()
    }

    // MARK: - Add Token

    /// Persists a manually added token. Deduplicates by contract address (case-insensitive).
    func addToken(_ token: TokenDiscoveryService.DiscoveredToken, for address: String) {
        var existing = loadPersistedTokens(for: address)
        let isDuplicate = existing.contains { $0.contractAddress.lowercased() == token.contractAddress.lowercased() && $0.chain == token.chain }
        guard !isDuplicate else { return }
        existing.append(token)
        persist(existing, for: address)
    }

    /// Removes a manually added token by contract address and chain.
    func removeToken(contractAddress: String, chain: String, for address: String) {
        var existing = loadPersistedTokens(for: address)
        existing.removeAll { $0.contractAddress.lowercased() == contractAddress.lowercased() && $0.chain == chain }
        persist(existing, for: address)
    }

    // MARK: - Load / Clear

    /// Loads manually added tokens from UserDefaults for a wallet address.
    nonisolated func loadPersistedTokens(for address: String) -> [TokenDiscoveryService.DiscoveredToken] {
        let key = Self.persistenceKeyPrefix + address.lowercased()
        guard let data = UserDefaults.standard.data(forKey: key),
              let tokens = try? JSONDecoder().decode([TokenDiscoveryService.DiscoveredToken].self, from: data) else {
            return []
        }
        return tokens
    }

    /// Clears all manually added tokens for a wallet address.
    nonisolated func clearPersistedTokens(for address: String) {
        let key = Self.persistenceKeyPrefix + address.lowercased()
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Private

    private func persist(_ tokens: [TokenDiscoveryService.DiscoveredToken], for address: String) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey(for: address))
    }

    // MARK: - ERC-20 Metadata Fetching

    /// Fetches ERC-20 token metadata (name, symbol, decimals) via eth_call.
    /// Throws if any of the three calls fail or return unparseable data.
    static func fetchERC20Metadata(rpcUrl: String, contractAddress: String) async throws -> (name: String, symbol: String, decimals: Int) {
        let rpc = RPCService.shared

        // name() selector: 0x06fdde03
        let nameHex: String = try await rpc.ethCall(rpcUrl: rpcUrl, to: contractAddress, data: "0x06fdde03")
        let name = try decodeABIString(nameHex)

        // symbol() selector: 0x95d89b41
        let symbolHex: String = try await rpc.ethCall(rpcUrl: rpcUrl, to: contractAddress, data: "0x95d89b41")
        let symbol = try decodeABIString(symbolHex)

        // decimals() selector: 0x313ce567
        let decimalsHex: String = try await rpc.ethCall(rpcUrl: rpcUrl, to: contractAddress, data: "0x313ce567")
        let decimals = try decodeABIUint(decimalsHex)

        return (name: name, symbol: symbol, decimals: decimals)
    }

    // MARK: - ABI Decoding Helpers

    /// Decodes an ABI-encoded string return value.
    /// Layout: 32 bytes offset + 32 bytes length + N bytes UTF-8 data (right-padded to 32).
    private static func decodeABIString(_ hex: String) throws -> String {
        let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex

        // Must have at least offset (32 bytes = 64 hex chars) + length (32 bytes)
        guard clean.count >= 128 else {
            // Some non-standard tokens return a raw bytes32 string (no offset/length).
            // Try interpreting the first 32 bytes directly as a null-terminated string.
            if clean.count >= 64 {
                return decodeBytes32String(clean)
            }
            throw MetadataError.invalidResponse
        }

        // Read the offset (first 32 bytes). Standard ABI encodes offset = 0x20 (32).
        let offsetHex = String(clean.prefix(64))
        let offset = Int(offsetHex, radix: 16) ?? 32

        // Read length from the offset position
        let lengthStart = offset * 2 // byte offset -> hex char offset
        let lengthEnd = lengthStart + 64
        guard clean.count >= lengthEnd else {
            // Fallback: try bytes32
            return decodeBytes32String(clean)
        }
        let lengthHex = String(clean[clean.index(clean.startIndex, offsetBy: lengthStart)..<clean.index(clean.startIndex, offsetBy: lengthEnd)])
        let length = Int(lengthHex, radix: 16) ?? 0
        guard length > 0, length < 256 else {
            // Fallback: try bytes32
            return decodeBytes32String(String(clean.prefix(64)))
        }

        // Read the actual string bytes
        let dataStart = lengthEnd
        let dataEnd = dataStart + length * 2
        guard clean.count >= dataEnd else {
            throw MetadataError.invalidResponse
        }
        let dataHex = String(clean[clean.index(clean.startIndex, offsetBy: dataStart)..<clean.index(clean.startIndex, offsetBy: dataEnd)])

        guard let data = Data(hexString: dataHex),
              let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) else {
            throw MetadataError.invalidResponse
        }
        return result
    }

    /// Interprets a 32-byte hex string as a null-terminated UTF-8 string.
    /// Used by non-standard tokens (e.g. MKR, SAI) that return bytes32 instead of ABI string.
    private static func decodeBytes32String(_ hex: String) -> String {
        let trimmed = hex.prefix(64)
        // Remove trailing zero bytes
        var cleaned = String(trimmed)
        while cleaned.hasSuffix("00") && cleaned.count > 2 {
            cleaned = String(cleaned.dropLast(2))
        }
        guard let data = Data(hexString: cleaned),
              let str = String(data: data, encoding: .utf8) else {
            return "Unknown"
        }
        return str.trimmingCharacters(in: .controlCharacters)
    }

    /// Decodes an ABI-encoded uint256 return value to Int.
    private static func decodeABIUint(_ hex: String) throws -> Int {
        let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        // Remove leading zeros, parse as integer
        let stripped = String(clean.drop(while: { $0 == "0" }))
        guard !stripped.isEmpty else { return 0 }
        guard let value = Int(stripped, radix: 16) else {
            throw MetadataError.invalidResponse
        }
        return value
    }

    enum MetadataError: LocalizedError {
        case invalidResponse
        case invalidAddress
        case contractNotFound
        case unsupportedChain

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Could not decode token metadata from the contract."
            case .invalidAddress:
                return "Invalid contract address format."
            case .contractNotFound:
                return "No contract found at this address."
            case .unsupportedChain:
                return "Token lookup is not supported on this chain."
            }
        }
    }
}

