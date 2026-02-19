import Foundation

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

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(
            configuration: config,
            delegate: CertificatePinner(),
            delegateQueue: nil
        )
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
              let txBytes = Data(base64Encoded: swapTxBase64) else {
            throw SwapServiceError.invalidResponse
        }

        // Sign the transaction via WalletService
        let signedTx = try await WalletService.shared.signTransaction(
            request: TransactionRequest(
                chain: solanaChain.id,
                rawTransaction: txBytes
            )
        )

        // Broadcast via RPC
        let txHash = try await RPCService.shared.sendSolanaTransaction(
            rpcUrl: solanaChain.rpcUrl,
            signedTx: signedTx
        )

        return Data(txHash.utf8)
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
              let gas = json["gas"] as? String else {
            throw SwapServiceError.transactionBuildFailed
        }

        // Determine which EVM chain this quote is for
        let chainId = (json["chainId"] as? Int).flatMap(String.init) ?? "ethereum"
        let chain = ChainModel.allChains.first { chain in
            chain.evmChainId.map(String.init) == chainId
        } ?? ChainModel.ethereum

        guard let fromAddress = WalletService.shared.addresses[chain.id] else {
            throw SwapServiceError.transactionBuildFailed
        }

        // Build the EVM transaction from the 0x quote response fields
        let tx = TransactionModel(
            hash: "",
            chain: chain.id,
            from: fromAddress,
            to: to,
            amount: value,
            fee: gas,
            status: .pending,
            timestamp: Date(),
            tokenSymbol: chain.symbol,
            tokenDecimals: 18,
            data: txData
        )

        let signedTx = try await WalletService.shared.signTransaction(
            request: TransactionRequest(
                chain: chain.id,
                to: to,
                value: value,
                data: txData,
                gasLimit: gas
            )
        )

        let txHash = try await RPCService.shared.sendRawTransaction(
            rpcUrl: chain.rpcUrl,
            signedTx: signedTx
        )

        return Data(txHash.utf8)
    }
}
