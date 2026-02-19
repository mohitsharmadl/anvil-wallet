import Foundation
import SwiftUI

@MainActor
final class SwapViewModel: ObservableObject {
    @Published var fromToken: TokenModel?
    @Published var toToken: TokenModel?
    @Published var amount = ""
    @Published var quote: SwapQuote?
    @Published var isLoadingQuote = false
    @Published var isExecutingSwap = false
    @Published var error: String?
    @Published var txHash: String?

    private let swapService = SwapService.shared

    // MARK: - Computed

    var canGetQuote: Bool {
        fromToken != nil && toToken != nil && !amount.isEmpty && Decimal(string: amount) != nil
    }

    var isLoading: Bool {
        isLoadingQuote || isExecutingSwap
    }

    /// The chain for the current swap (determined by fromToken).
    var chain: ChainModel? {
        guard let chainId = fromToken?.chain else { return nil }
        return ChainModel.allChains.first { $0.id == chainId }
    }

    /// Checks that from and to tokens are on the same chain.
    var isSameChain: Bool {
        guard let from = fromToken, let to = toToken else { return false }
        return from.chain == to.chain
    }

    /// Formatted output amount in human-readable units.
    var formattedOutputAmount: String? {
        guard let quote, let toToken else { return nil }
        let raw = Double(quote.toAmount) ?? 0
        let amount = raw / pow(10.0, Double(toToken.decimals))
        return String(format: "%.\(min(toToken.decimals, 6))f", amount)
    }

    /// Exchange rate string, e.g. "1 ETH = 3200.5 USDC"
    var exchangeRateDisplay: String? {
        guard let quote, let fromToken, let toToken else { return nil }
        let inAmt = Double(quote.fromAmount) ?? 0
        let outAmt = Double(quote.toAmount) ?? 0
        guard inAmt > 0 else { return nil }
        let inHuman = inAmt / pow(10.0, Double(fromToken.decimals))
        let outHuman = outAmt / pow(10.0, Double(toToken.decimals))
        let rate = outHuman / inHuman
        return "1 \(fromToken.symbol) = \(String(format: "%.4f", rate)) \(toToken.symbol)"
    }

    // MARK: - Actions

    /// Swaps the from and to tokens.
    func swapTokens() {
        let temp = fromToken
        fromToken = toToken
        toToken = temp
        quote = nil
        error = nil
    }

    /// Fetches a quote from the appropriate swap provider.
    func fetchQuote() async {
        guard let fromToken, let toToken, let chain else { return }
        guard isSameChain else {
            error = "Cross-chain swaps are not supported. Select tokens on the same chain."
            return
        }
        guard let decimalAmount = Decimal(string: amount), decimalAmount > 0 else {
            error = "Enter a valid amount"
            return
        }

        // Convert human-readable amount to smallest unit
        let multiplier = pow(Decimal(10), fromToken.decimals)
        let rawAmount = decimalAmount * multiplier
        let rawAmountString = NSDecimalNumber(decimal: rawAmount).stringValue

        let fromMint = fromToken.contractAddress ?? fromToken.symbol
        let toMint = toToken.contractAddress ?? toToken.symbol

        isLoadingQuote = true
        error = nil
        quote = nil

        do {
            quote = try await swapService.getQuote(
                from: fromMint,
                to: toMint,
                amount: rawAmountString,
                chain: chain
            )
        } catch {
            self.error = error.localizedDescription
        }

        isLoadingQuote = false
    }

    /// Whether swap execution is supported for the current quote's provider.
    var canExecuteSwap: Bool {
        guard let quote else { return false }
        // Jupiter (Solana) swaps require raw tx signing support — not yet implemented.
        return quote.provider != .jupiter
    }

    /// Executes the swap using the current quote.
    func executeSwap() async {
        guard let quote else { return }
        guard canExecuteSwap else {
            error = "Solana swaps are not yet supported. EVM swaps are available."
            return
        }

        isExecutingSwap = true
        error = nil

        do {
            let result = try await swapService.executeSwap(quote: quote)
            txHash = String(data: result, encoding: .utf8)
        } catch {
            self.error = error.localizedDescription
        }

        isExecutingSwap = false
    }
}
