import Foundation
import os.log

// MARK: - Types

enum SwapProvider: String, Codable {
    case jupiter
    case zeroX
}

struct SwapRoute: Codable, Hashable {
    let provider: SwapProvider
    let path: [String]   // Token symbols along the route
    let label: String    // Human-readable route description
}

struct SwapQuote: Codable {
    let fromToken: String       // Mint address or contract address
    let toToken: String
    let fromAmount: String      // Raw amount (smallest unit)
    let toAmount: String        // Raw amount (smallest unit)
    let priceImpact: Double     // Percentage, e.g. 0.12 means 0.12%
    let route: SwapRoute
    let estimatedGas: String    // Gas or compute units
    let fee: Double             // Anvil fee percentage, e.g. 0.5
    let provider: SwapProvider

    // Raw API response data needed for execution
    let rawQuoteData: Data
}

// MARK: - Errors

enum SwapServiceError: LocalizedError {
    case unsupportedChain(String)
    case quoteUnavailable
    case invalidResponse
    case transactionBuildFailed
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedChain(let chain): return "Swaps not supported on \(chain)"
        case .quoteUnavailable: return "No swap route available for this pair"
        case .invalidResponse: return "Invalid response from swap provider"
        case .transactionBuildFailed: return "Failed to build swap transaction"
        case .networkError(let msg): return msg
        }
    }
}

// MARK: - SwapService

/// Handles token swap quotes and execution via Jupiter (Solana) and 0x (EVM).
final class SwapService {
    static let shared = SwapService()

    // TODO: Set the actual fee collection addresses for each chain
    let solanaFeeAccount = "PLACEHOLDER_SOLANA_FEE_ADDRESS"
    let evmFeeRecipient = "PLACEHOLDER_EVM_FEE_ADDRESS"

    private static let logger = Logger(subsystem: "com.anvilwallet", category: "Swap")
    private let session: URLSession

    private init() {
        // Swap API hosts (jup.ag, 0x.org) are NOT pinned — they rotate certs frequently.
        // Same rationale as WC relay: standard TLS validation is the accepted trade-off.
        // CertificatePinner is fail-closed, so using it here would block all swap requests.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        Self.logger.info("SwapService using standard TLS (no SPKI pinning) for third-party swap APIs")
    }

    // MARK: - Get Quote

    /// Fetches a swap quote for the given token pair and amount.
    /// - Parameters:
    ///   - fromMint: Source token mint/contract address
    ///   - toMint: Destination token mint/contract address
    ///   - amount: Amount in smallest unit (lamports, wei, etc.)
    ///   - chain: The chain to swap on
    func getQuote(
        from fromMint: String,
        to toMint: String,
        amount: String,
        chain: ChainModel
    ) async throws -> SwapQuote {
        switch chain.chainType {
        case .solana:
            return try await getJupiterQuote(fromMint: fromMint, toMint: toMint, amount: amount)
        case .evm:
            return try await getZeroXQuote(
                sellToken: fromMint,
                buyToken: toMint,
                sellAmount: amount,
                chain: chain
            )
        case .bitcoin:
            throw SwapServiceError.unsupportedChain("Bitcoin")
        }
    }

    // MARK: - Execute Swap

    /// Builds, signs, and broadcasts a swap transaction.
    /// - Returns: The signed transaction bytes ready for broadcast, or the tx hash after broadcast.
    func executeSwap(quote: SwapQuote) async throws -> Data {
        switch quote.provider {
        case .jupiter:
            return try await executeJupiterSwap(quote: quote)
        case .zeroX:
            return try await executeZeroXSwap(quote: quote)
        }
    }

    // MARK: - Jupiter (Solana)

    private func getJupiterQuote(fromMint: String, toMint: String, amount: String) async throws -> SwapQuote {
        var components = URLComponents(string: "https://quote-api.jup.ag/v6/quote")!
        components.queryItems = [
            URLQueryItem(name: "inputMint", value: fromMint),
            URLQueryItem(name: "outputMint", value: toMint),
            URLQueryItem(name: "amount", value: amount),
            URLQueryItem(name: "platformFeeBps", value: "50"),  // 0.5% Anvil fee
        ]

        guard let url = components.url else { throw SwapServiceError.invalidResponse }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SwapServiceError.quoteUnavailable
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outAmount = json["outAmount"] as? String,
              let priceImpactPct = json["priceImpactPct"] as? String else {
            throw SwapServiceError.invalidResponse
        }

        let routePlan = json["routePlan"] as? [[String: Any]]
        let routeLabels = routePlan?.compactMap { step -> String? in
            let info = step["swapInfo"] as? [String: Any]
            return info?["label"] as? String
        } ?? []

        return SwapQuote(
            fromToken: fromMint,
            toToken: toMint,
            fromAmount: amount,
            toAmount: outAmount,
            priceImpact: Double(priceImpactPct) ?? 0,
            route: SwapRoute(
                provider: .jupiter,
                path: routeLabels,
                label: routeLabels.joined(separator: " -> ")
            ),
            estimatedGas: "5000",  // Solana compute units, approximate
            fee: 0.5,
            provider: .jupiter,
            rawQuoteData: data
        )
    }

    private func executeJupiterSwap(quote: SwapQuote) async throws -> Data {
        let solanaChain = ChainModel.solana
        guard let userAddress = WalletService.shared.addresses[solanaChain.id] else {
            throw SwapServiceError.transactionBuildFailed
        }

        let url = URL(string: "https://quote-api.jup.ag/v6/swap")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "quoteResponse": try JSONSerialization.jsonObject(with: quote.rawQuoteData),
            "userPublicKey": userAddress,
            "feeAccount": solanaFeeAccount,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SwapServiceError.transactionBuildFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let swapTxBase64 = json["swapTransaction"] as? String,
              let _ = Data(base64Encoded: swapTxBase64) else {
            throw SwapServiceError.invalidResponse
        }

        // TODO: Jupiter returns a versioned transaction that needs raw signing support.
        // The current signTransaction API only supports building SOL transfers from scratch.
        // Implement raw Solana transaction signing (sign pre-built tx bytes) to enable this.
        throw SwapServiceError.transactionBuildFailed
    }

    // MARK: - 0x (EVM)

    private func getZeroXQuote(
        sellToken: String,
        buyToken: String,
        sellAmount: String,
        chain: ChainModel
    ) async throws -> SwapQuote {
        var components = URLComponents(string: "https://api.0x.org/swap/v1/quote")!
        components.queryItems = [
            URLQueryItem(name: "sellToken", value: sellToken),
            URLQueryItem(name: "buyToken", value: buyToken),
            URLQueryItem(name: "sellAmount", value: sellAmount),
            URLQueryItem(name: "feeRecipient", value: evmFeeRecipient),
            URLQueryItem(name: "buyTokenPercentageFee", value: "0.005"),  // 0.5%
        ]

        guard let url = components.url else { throw SwapServiceError.invalidResponse }

        var request = URLRequest(url: url)
        // 0x requires chain ID header for non-Ethereum chains
        if let chainId = chain.evmChainId, chainId != 1 {
            request.setValue(String(chainId), forHTTPHeaderField: "0x-chain-id")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SwapServiceError.quoteUnavailable
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buyAmount = json["buyAmount"] as? String,
              let estimatedPriceImpact = json["estimatedPriceImpact"] as? String,
              let gas = json["gas"] as? String else {
            throw SwapServiceError.invalidResponse
        }

        let sources = json["sources"] as? [[String: Any]]
        let routeLabels = sources?.compactMap { source -> String? in
            guard let proportion = source["proportion"] as? String,
                  proportion != "0" else { return nil }
            return source["name"] as? String
        } ?? []

        return SwapQuote(
            fromToken: sellToken,
            toToken: buyToken,
            fromAmount: sellAmount,
            toAmount: buyAmount,
            priceImpact: Double(estimatedPriceImpact) ?? 0,
            route: SwapRoute(
                provider: .zeroX,
                path: routeLabels,
                label: routeLabels.joined(separator: " + ")
            ),
            estimatedGas: gas,
            fee: 0.5,
            provider: .zeroX,
            rawQuoteData: data
        )
    }

    private func executeZeroXSwap(quote: SwapQuote) async throws -> Data {
        guard let json = try JSONSerialization.jsonObject(with: quote.rawQuoteData) as? [String: Any],
              let to = json["to"] as? String,
              let txData = json["data"] as? String,
              let value = json["value"] as? String,
              let gas = json["gas"] as? String,
              let gasLimit = UInt64(gas) else {
            throw SwapServiceError.transactionBuildFailed
        }

        // Determine which EVM chain this quote is for
        let chainIdNum = json["chainId"] as? Int ?? 1
        let chain = ChainModel.allChains.first { chain in
            chain.evmChainId == UInt64(chainIdNum)
        } ?? ChainModel.ethereum

        guard let evmChainId = chain.evmChainId else {
            throw SwapServiceError.unsupportedChain(chain.id)
        }

        guard let fromAddress = WalletService.shared.addresses[chain.id] else {
            throw SwapServiceError.transactionBuildFailed
        }

        // Fetch nonce and fee params from network
        let rpc = RPCService.shared
        let nonceHex = try await rpc.getTransactionCount(rpcUrl: chain.rpcUrl, address: fromAddress)
        guard let nonce = UInt64(nonceHex.hasPrefix("0x") ? String(nonceHex.dropFirst(2)) : nonceHex, radix: 16) else {
            throw SwapServiceError.networkError("Invalid nonce: \(nonceHex)")
        }

        let fees = try await rpc.feeHistory(rpcUrl: chain.rpcUrl)
        let maxPriorityFeeHex = fees.priorityFeeHex
        let maxFeeHex: String
        if let baseFee = UInt64(fees.baseFeeHex.hasPrefix("0x") ? String(fees.baseFeeHex.dropFirst(2)) : fees.baseFeeHex, radix: 16),
           let priority = UInt64(fees.priorityFeeHex.hasPrefix("0x") ? String(fees.priorityFeeHex.dropFirst(2)) : fees.priorityFeeHex, radix: 16) {
            maxFeeHex = "0x" + String(baseFee * 2 + priority, radix: 16)
        } else {
            maxFeeHex = fees.baseFeeHex
        }

        // Decode calldata hex to bytes — reject invalid hex rather than silently
        // altering the payload, which could change the contract call semantics.
        let calldataCleaned = txData.hasPrefix("0x") ? String(txData.dropFirst(2)) : txData
        guard calldataCleaned.count % 2 == 0 else {
            throw SwapServiceError.transactionBuildFailed
        }
        var calldataBytes = Data()
        calldataBytes.reserveCapacity(calldataCleaned.count / 2)
        var idx = calldataCleaned.startIndex
        while idx < calldataCleaned.endIndex {
            let next = calldataCleaned.index(idx, offsetBy: 2)
            guard let byte = UInt8(String(calldataCleaned[idx..<next]), radix: 16) else {
                throw SwapServiceError.transactionBuildFailed
            }
            calldataBytes.append(byte)
            idx = next
        }

        // Build typed EVM transaction request
        let ethReq = EthTransactionRequest(
            chainId: evmChainId,
            nonce: nonce,
            to: to,
            valueWeiHex: value.hasPrefix("0x") ? value : "0x\(value)",
            data: calldataBytes,
            maxPriorityFeeHex: maxPriorityFeeHex,
            maxFeeHex: maxFeeHex,
            gasLimit: gasLimit + gasLimit / 5  // 20% buffer
        )

        let signedTx = try await WalletService.shared.signTransaction(request: .eth(ethReq))
        let signedTxHex = "0x" + signedTx.map { String(format: "%02x", $0) }.joined()

        let txHash = try await rpc.sendRawTransaction(
            rpcUrl: chain.rpcUrl,
            signedTx: signedTxHex
        )

        return Data(txHash.utf8)
    }
}
