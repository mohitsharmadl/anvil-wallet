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

    // 0x-specific fields for quote display
    let price: String?
    let guaranteedPrice: String?
    let sources: [SwapSource]?

    // Raw API response data needed for execution
    let rawQuoteData: Data
}

struct SwapSource: Codable, Hashable {
    let name: String
    let proportion: String
}

// MARK: - Errors

enum SwapServiceError: LocalizedError {
    case unsupportedChain(String)
    case quoteUnavailable
    case invalidResponse
    case transactionBuildFailed
    case networkError(String)
    case missingApiKey
    case invalidHexResponse(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedChain(let chain): return "Swaps not supported on \(chain)"
        case .quoteUnavailable: return "No swap route available for this pair"
        case .invalidResponse: return "Invalid response from swap provider"
        case .transactionBuildFailed: return "Failed to build swap transaction"
        case .networkError(let msg): return msg
        case .missingApiKey: return "0x API key not configured"
        case .invalidHexResponse(let field): return "Invalid hex value for \(field) from RPC"
        }
    }
}

// MARK: - Common Token Addresses

/// Well-known token contract addresses per EVM chain ID.
/// Native ETH/MATIC/etc. is represented by the 0xeee... convention on 0x API.
struct CommonTokens {
    /// Native token placeholder for 0x API.
    static let nativeToken = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

    /// WETH addresses per chain.
    static let weth: [UInt64: String] = [
        1:     "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", // Ethereum
        137:   "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619", // Polygon (WETH)
        42161: "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1", // Arbitrum
        10:    "0x4200000000000000000000000000000000000006", // Optimism
        8453:  "0x4200000000000000000000000000000000000006", // Base
    ]

    /// USDC addresses per chain.
    static let usdc: [UInt64: String] = [
        1:     "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", // Ethereum
        137:   "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359", // Polygon
        42161: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", // Arbitrum
        10:    "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85", // Optimism
        8453:  "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", // Base
    ]

    /// USDT addresses per chain.
    static let usdt: [UInt64: String] = [
        1:     "0xdAC17F958D2ee523a2206206994597C13D831ec7", // Ethereum
        137:   "0xc2132D05D31c914a87C6611C10748AEb04B58e8F", // Polygon
        42161: "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9", // Arbitrum
        10:    "0x94b008aA00579c1307B0EF2c499aD98a8ce58e58", // Optimism
        8453:  "0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2", // Base
    ]

    /// DAI addresses per chain.
    static let dai: [UInt64: String] = [
        1:     "0x6B175474E89094C44Da98b954EedeAC495271d0F", // Ethereum
        137:   "0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063", // Polygon
        42161: "0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1", // Arbitrum
        10:    "0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1", // Optimism
        8453:  "0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb", // Base
    ]
}

// MARK: - SwapService

/// Handles token swap quotes and execution via Jupiter (Solana) and 0x (EVM).
///
/// Uses CertificatePinner for TLS hardening on 0x API requests.
/// API key loaded from Info.plist via Bundle.main ("ZeroExApiKey").
final class SwapService {
    static let shared = SwapService()

    /// Supported EVM chain IDs for 0x swaps.
    static let supportedChainIds: [UInt64] = [1, 137, 42161, 10, 8453]

    /// Supported chains as (name, chainId) tuples for the UI picker.
    static let supportedChains: [(name: String, chainId: UInt64)] = [
        ("Ethereum", 1),
        ("Polygon", 137),
        ("Arbitrum", 42161),
        ("Optimism", 10),
        ("Base", 8453),
    ]

    private static let logger = Logger(subsystem: "com.anvilwallet", category: "Swap")

    private let session: URLSession
    private let apiKey: String

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(
            configuration: config,
            delegate: CertificatePinner(),
            delegateQueue: nil
        )
        self.apiKey = Bundle.main.object(forInfoDictionaryKey: "ZeroExApiKey") as? String ?? ""
    }

    // MARK: - Get Quote

    /// Fetches a swap quote for the given token pair and amount.
    /// - Parameters:
    ///   - fromMint: Source token mint/contract address
    ///   - toMint: Destination token mint/contract address
    ///   - amount: Amount in smallest unit (lamports, wei, etc.)
    ///   - chain: The chain to swap on
    ///   - slippageBps: Slippage tolerance in basis points (e.g. 50 = 0.5%)
    func getQuote(
        from fromMint: String,
        to toMint: String,
        amount: String,
        chain: ChainModel,
        slippageBps: Int = 50
    ) async throws -> SwapQuote {
        switch chain.chainType {
        case .solana:
            return try await getJupiterQuote(
                fromMint: fromMint, toMint: toMint,
                amount: amount, slippageBps: slippageBps
            )
        case .evm:
            return try await getZeroXQuote(
                sellToken: fromMint, buyToken: toMint,
                sellAmount: amount, chain: chain,
                slippageBps: slippageBps
            )
        case .bitcoin:
            throw SwapServiceError.unsupportedChain("Bitcoin")
        case .zcash:
            throw SwapServiceError.unsupportedChain("Zcash")
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

    private func getJupiterQuote(
        fromMint: String, toMint: String,
        amount: String, slippageBps: Int
    ) async throws -> SwapQuote {
        var components = URLComponents(string: "https://quote-api.jup.ag/v6/quote")!
        components.queryItems = [
            URLQueryItem(name: "inputMint", value: fromMint),
            URLQueryItem(name: "outputMint", value: toMint),
            URLQueryItem(name: "amount", value: amount),
            URLQueryItem(name: "slippageBps", value: String(slippageBps)),
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
            fee: 0.0,
            provider: .jupiter,
            price: nil,
            guaranteedPrice: nil,
            sources: nil,
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
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SwapServiceError.transactionBuildFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let swapTxBase64 = json["swapTransaction"] as? String,
              let rawTxData = Data(base64Encoded: swapTxBase64) else {
            throw SwapServiceError.invalidResponse
        }

        // Sign the pre-built versioned transaction with the wallet's Ed25519 key
        let signedTxData = try await WalletService.shared.signSolanaRawTransaction(rawTxData)

        // Broadcast via Solana RPC
        let signedBase64 = signedTxData.base64EncodedString()
        let txSignature = try await RPCService.shared.sendSolanaTransaction(
            rpcUrl: solanaChain.activeRpcUrl,
            signedTx: signedBase64
        )

        return Data(txSignature.utf8)
    }

    // MARK: - 0x (EVM)

    private func getZeroXQuote(
        sellToken: String,
        buyToken: String,
        sellAmount: String,
        chain: ChainModel,
        slippageBps: Int
    ) async throws -> SwapQuote {
        guard !apiKey.isEmpty else {
            throw SwapServiceError.missingApiKey
        }

        guard let evmChainId = chain.evmChainId,
              Self.supportedChainIds.contains(evmChainId) else {
            throw SwapServiceError.unsupportedChain(chain.name)
        }

        guard let takerAddress = WalletService.shared.addresses["ethereum"] else {
            throw SwapServiceError.transactionBuildFailed
        }

        // Convert basis points to a decimal percentage string: 50 bps -> "0.005"
        let slippageDecimal = Double(slippageBps) / 10000.0

        var components = URLComponents(string: "https://api.0x.org/swap/v1/quote")!
        components.queryItems = [
            URLQueryItem(name: "sellToken", value: sellToken),
            URLQueryItem(name: "buyToken", value: buyToken),
            URLQueryItem(name: "sellAmount", value: sellAmount),
            URLQueryItem(name: "takerAddress", value: takerAddress),
            URLQueryItem(name: "slippagePercentage", value: String(slippageDecimal)),
        ]

        guard let url = components.url else { throw SwapServiceError.invalidResponse }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "0x-api-key")

        // 0x requires chain ID header for non-Ethereum chains
        if evmChainId != 1 {
            request.setValue(String(evmChainId), forHTTPHeaderField: "0x-chain-id")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            // Try to parse error message from response body
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let reason = errorJson["reason"] as? String {
                throw SwapServiceError.networkError("0x API: \(reason)")
            }
            throw SwapServiceError.quoteUnavailable
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buyAmount = json["buyAmount"] as? String,
              let gas = json["gas"] as? String else {
            throw SwapServiceError.invalidResponse
        }

        let price = json["price"] as? String
        let guaranteedPrice = json["guaranteedPrice"] as? String
        let estimatedPriceImpact = json["estimatedPriceImpact"] as? String

        // Parse liquidity sources
        let sourcesJson = json["sources"] as? [[String: Any]]
        let activeSources: [SwapSource] = sourcesJson?.compactMap { source -> SwapSource? in
            guard let name = source["name"] as? String,
                  let proportion = source["proportion"] as? String,
                  proportion != "0" else { return nil }
            return SwapSource(name: name, proportion: proportion)
        } ?? []

        let routeLabels = activeSources.map { $0.name }

        return SwapQuote(
            fromToken: sellToken,
            toToken: buyToken,
            fromAmount: sellAmount,
            toAmount: buyAmount,
            priceImpact: Double(estimatedPriceImpact ?? "0") ?? 0,
            route: SwapRoute(
                provider: .zeroX,
                path: routeLabels,
                label: routeLabels.joined(separator: " + ")
            ),
            estimatedGas: gas,
            fee: 0.0,
            provider: .zeroX,
            price: price,
            guaranteedPrice: guaranteedPrice,
            sources: activeSources,
            rawQuoteData: data
        )
    }

    private func executeZeroXSwap(quote: SwapQuote) async throws -> Data {
        guard let json = try JSONSerialization.jsonObject(with: quote.rawQuoteData) as? [String: Any],
              let to = json["to"] as? String,
              let txData = json["data"] as? String,
              let value = json["value"] as? String else {
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

        guard let fromAddress = WalletService.shared.addresses["ethereum"] else {
            throw SwapServiceError.transactionBuildFailed
        }

        // Fetch nonce
        let rpc = RPCService.shared
        let nonceHex = try await rpc.getTransactionCount(rpcUrl: chain.activeRpcUrl, address: fromAddress)
        let nonceClean = nonceHex.hasPrefix("0x") ? String(nonceHex.dropFirst(2)) : nonceHex
        guard let nonce = UInt64(nonceClean, radix: 16) else {
            throw SwapServiceError.invalidHexResponse("nonce")
        }

        // Estimate gas from the quote's calldata
        let dataHex = txData.hasPrefix("0x") ? txData : "0x\(txData)"
        let valueHex = value.hasPrefix("0x") ? value : "0x\(value)"
        let gasHex = try await rpc.estimateGas(
            rpcUrl: chain.activeRpcUrl, from: fromAddress,
            to: to, value: valueHex, data: dataHex
        )
        let gasClean = gasHex.hasPrefix("0x") ? String(gasHex.dropFirst(2)) : gasHex
        guard let gasEstimate = UInt64(gasClean, radix: 16) else {
            throw SwapServiceError.invalidHexResponse("gas estimate")
        }

        // Fetch EIP-1559 fee data
        let fees = try await rpc.feeHistory(rpcUrl: chain.activeRpcUrl)
        let baseFeeClean = fees.baseFeeHex.hasPrefix("0x") ? String(fees.baseFeeHex.dropFirst(2)) : fees.baseFeeHex
        let priorityClean = fees.priorityFeeHex.hasPrefix("0x") ? String(fees.priorityFeeHex.dropFirst(2)) : fees.priorityFeeHex

        guard let baseFee = UInt64(baseFeeClean, radix: 16) else {
            throw SwapServiceError.invalidHexResponse("base fee")
        }
        guard let priorityFee = UInt64(priorityClean, radix: 16) else {
            throw SwapServiceError.invalidHexResponse("priority fee")
        }

        let maxFee = baseFee * 2 + priorityFee
        let maxFeeHex = "0x" + String(maxFee, radix: 16)

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
        let gasLimit = gasEstimate + gasEstimate / 5  // 20% buffer
        let ethReq = EthTransactionRequest(
            chainId: evmChainId,
            nonce: nonce,
            to: to,
            valueWeiHex: valueHex,
            data: calldataBytes,
            maxPriorityFeeHex: fees.priorityFeeHex,
            maxFeeHex: maxFeeHex,
            gasLimit: gasLimit
        )

        let signedTx = try await WalletService.shared.signTransaction(request: .eth(ethReq))
        let signedTxHex = "0x" + signedTx.map { String(format: "%02x", $0) }.joined()

        let txHash = try await rpc.sendRawTransaction(
            rpcUrl: chain.activeRpcUrl,
            signedTx: signedTxHex
        )

        return Data(txHash.utf8)
    }
}
