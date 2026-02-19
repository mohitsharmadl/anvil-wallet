import Foundation

/// Tracks ERC-20 token approvals and builds revoke transactions.
actor ApprovalService {

    static let shared = ApprovalService()

    private init() {}

    // MARK: - Types

    struct TokenApproval: Identifiable {
        let id: String // txHash
        let tokenAddress: String
        let tokenSymbol: String
        let spender: String
        let allowance: String  // hex
        let isUnlimited: Bool
        let blockNumber: String
    }

    // MARK: - Fetch Approvals

    /// Fetches current token approvals for the given address on Ethereum mainnet.
    /// 1. Gets Approval event logs from Etherscan
    /// 2. Deduplicates by (token, spender) — keeps latest block
    /// 3. Checks current on-chain allowance via RPC
    /// 4. Filters out zero (already revoked) approvals
    func fetchApprovals(for address: String) async throws -> [TokenApproval] {
        let logs = try await EtherscanService.shared.fetchApprovalLogs(owner: address)

        guard let ethChain = ChainModel.allChains.first(where: { $0.id == "ethereum" }) else {
            return []
        }

        // Deduplicate: keep latest approval per (token, spender)
        var latestByPair: [String: EtherscanService.ApprovalLog] = [:]
        for log in logs {
            guard log.topics.count >= 3 else { continue }
            let key = "\(log.address.lowercased())_\(log.topics[2].lowercased())"
            if let existing = latestByPair[key] {
                let existingBlock = UInt64(existing.blockNumber.dropFirst(2), radix: 16) ?? 0
                let newBlock = UInt64(log.blockNumber.dropFirst(2), radix: 16) ?? 0
                if newBlock > existingBlock {
                    latestByPair[key] = log
                }
            } else {
                latestByPair[key] = log
            }
        }

        var approvals: [TokenApproval] = []

        for log in latestByPair.values {
            guard log.topics.count >= 3 else { continue }

            let tokenAddress = log.address
            let spenderPadded = log.topics[2]
            let spender = "0x" + spenderPadded.suffix(40)

            // Check current on-chain allowance
            let cleanOwner = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
            let paddedOwner = String(repeating: "0", count: max(0, 64 - cleanOwner.count)) + cleanOwner.lowercased()
            let cleanSpender = spender.hasPrefix("0x") ? String(spender.dropFirst(2)) : spender
            let paddedSpender = String(repeating: "0", count: max(0, 64 - cleanSpender.count)) + cleanSpender.lowercased()

            // allowance(owner, spender) selector = 0xdd62ed3e
            let callData = "0xdd62ed3e" + paddedOwner + paddedSpender

            do {
                let hexAllowance: String = try await RPCService.shared.ethCall(
                    rpcUrl: ethChain.rpcUrl,
                    to: tokenAddress,
                    data: callData
                )

                let cleanHex = hexAllowance.hasPrefix("0x") ? String(hexAllowance.dropFirst(2)) : hexAllowance
                let isZero = cleanHex.isEmpty || cleanHex.allSatisfy { $0 == "0" }
                if isZero { continue } // Already revoked

                // Check if unlimited (all f's after leading zeros stripped)
                let trimmed = cleanHex.drop(while: { $0 == "0" })
                let isUnlimited = !trimmed.isEmpty && trimmed.allSatisfy { $0 == "f" || $0 == "F" }

                // Try to get token symbol via Etherscan transfer data
                let symbol = await resolveTokenSymbol(for: tokenAddress, chain: ethChain)

                approvals.append(TokenApproval(
                    id: log.transactionHash,
                    tokenAddress: tokenAddress,
                    tokenSymbol: symbol,
                    spender: spender,
                    allowance: hexAllowance,
                    isUnlimited: isUnlimited,
                    blockNumber: log.blockNumber
                ))
            } catch {
                continue
            }
        }

        return approvals.sorted { $0.tokenSymbol < $1.tokenSymbol }
    }

    // MARK: - Revoke

    /// Builds an ERC-20 approve(spender, 0) transaction to revoke an approval.
    /// Returns the calldata as hex string (0x-prefixed).
    func buildRevokeCalldata(spender: String) -> String {
        let cleanSpender = spender.hasPrefix("0x") ? String(spender.dropFirst(2)) : spender
        let paddedSpender = String(repeating: "0", count: max(0, 64 - cleanSpender.count)) + cleanSpender.lowercased()
        let zeroAmount = String(repeating: "0", count: 64)
        // approve(address,uint256) selector = 0x095ea7b3
        return "0x095ea7b3" + paddedSpender + zeroAmount
    }

    // MARK: - Helpers

    /// Resolves token symbol by calling symbol() on the contract.
    private func resolveTokenSymbol(for tokenAddress: String, chain: ChainModel) async -> String {
        // symbol() selector = 0x95d89b41
        do {
            let result: String = try await RPCService.shared.ethCall(
                rpcUrl: chain.rpcUrl,
                to: tokenAddress,
                data: "0x95d89b41"
            )
            return decodeStringFromABI(result) ?? shortenAddress(tokenAddress)
        } catch {
            return shortenAddress(tokenAddress)
        }
    }

    /// Decodes a string return value from ABI encoding.
    private func decodeStringFromABI(_ hex: String) -> String? {
        let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        // ABI string: offset (32B) + length (32B) + data
        guard clean.count >= 128 else { return nil }
        let lengthHex = String(clean[clean.index(clean.startIndex, offsetBy: 64)..<clean.index(clean.startIndex, offsetBy: 128)])
        guard let length = UInt64(lengthHex, radix: 16), length > 0, length < 100 else { return nil }
        let dataStart = clean.index(clean.startIndex, offsetBy: 128)
        let dataEnd = clean.index(dataStart, offsetBy: min(Int(length) * 2, clean.count - 128))
        let dataHex = String(clean[dataStart..<dataEnd])

        // Convert hex to ASCII string
        var bytes: [UInt8] = []
        var i = dataHex.startIndex
        while i < dataHex.endIndex {
            let next = dataHex.index(i, offsetBy: 2, limitedBy: dataHex.endIndex) ?? dataHex.endIndex
            if let byte = UInt8(dataHex[i..<next], radix: 16) {
                bytes.append(byte)
            }
            i = next
        }
        let decoded = String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
        return decoded?.isEmpty == true ? nil : decoded
    }

    private func shortenAddress(_ addr: String) -> String {
        guard addr.count > 10 else { return addr }
        return "\(addr.prefix(6))...\(addr.suffix(4))"
    }
}
