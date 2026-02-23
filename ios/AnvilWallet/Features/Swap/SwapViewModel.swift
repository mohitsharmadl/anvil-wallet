import Foundation
import SwiftUI

@MainActor
final class SwapViewModel: ObservableObject {
    @Published var fromToken: TokenModel?
    @Published var toToken: TokenModel?
    @Published var fromAmount = ""
    @Published var toAmount = ""
    @Published var quoteAmountType: QuoteAmountType = .exactInput
    @Published var quote: SwapQuote?
    @Published var isLoadingQuote = false
    @Published var isExecutingSwap = false
    @Published var error: String?
    @Published var txHash: String?

    /// Selected EVM chain ID, or 0 for Solana.
    @Published var selectedChainId: UInt64 = 1

    /// Slippage tolerance in basis points.
    @Published var slippageBps: Int = 50

    private let swapService = SwapService.shared
    private var autoQuoteTask: Task<Void, Never>?

    // MARK: - Slippage Presets

    /// Available slippage presets in basis points.
    static let slippagePresets: [Int] = [50, 100, 300]

    /// Human-readable label for a slippage preset.
    static func slippageLabel(bps: Int) -> String {
        let pct = Double(bps) / 100.0
        if pct == pct.rounded() {
            return String(format: "%.0f%%", pct)
        }
        return String(format: "%.1f%%", pct)
    }

    // MARK: - Chain Helpers

    /// The display name for the currently selected chain.
    var selectedChainName: String {
        if selectedChainId == 0 { return "Solana" }
        return SwapService.supportedChains.first { $0.chainId == selectedChainId }?.name ?? "Ethereum"
    }

    /// Maps the selected chain ID to a ChainModel.id string for filtering tokens.
    var selectedChainModelId: String {
        if selectedChainId == 0 { return "solana" }
        switch selectedChainId {
        case 1: return "ethereum"
        case 137: return "polygon"
        case 42161: return "arbitrum"
        case 10: return "optimism"
        case 8453: return "base"
        default: return "ethereum"
        }
    }

    // MARK: - Computed

    var canGetQuote: Bool {
        guard fromToken != nil, toToken != nil else { return false }
        let value = quoteAmountType == .exactInput ? fromAmount : toAmount
        guard let decimalValue = Decimal(string: value) else { return false }
        return decimalValue > 0
    }

    var isLoading: Bool {
        isLoadingQuote || isExecutingSwap
    }

    /// The chain for the current swap (determined by selected chain, not fromToken).
    var chain: ChainModel? {
        if selectedChainId == 0 { return ChainModel.solana }
        return ChainModel.allChains.first { $0.evmChainId == selectedChainId }
    }

    /// Checks that from and to tokens are on the same chain.
    var isSameChain: Bool {
        guard let from = fromToken, let to = toToken else { return false }
        return from.chain == to.chain
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
        let amountTemp = fromAmount
        fromAmount = toAmount
        toAmount = amountTemp
        quoteAmountType = quoteAmountType == .exactInput ? .exactOutput : .exactInput
        quote = nil
        error = nil
    }

    func setFromAmount(_ value: String) {
        quoteAmountType = .exactInput
        fromAmount = value
        estimateOppositeAmount()
        quote = nil
        error = nil
    }

    func setToAmount(_ value: String) {
        quoteAmountType = .exactOutput
        toAmount = value
        estimateOppositeAmount()
        quote = nil
        error = nil
    }

    func scheduleAutoQuote() {
        autoQuoteTask?.cancel()
        guard canGetQuote else { return }

        autoQuoteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.fetchQuote()
        }
    }

    func cancelAutoQuote() {
        autoQuoteTask?.cancel()
        autoQuoteTask = nil
    }

    /// Fetches a quote from the appropriate swap provider.
    func fetchQuote() async {
        guard let fromToken, let toToken, let chain else { return }
        guard isSameChain else {
            error = "Cross-chain swaps are not supported. Select tokens on the same chain."
            return
        }
        let typedAmountString = quoteAmountType == .exactInput ? fromAmount : toAmount
        guard let decimalAmount = Decimal(string: typedAmountString), decimalAmount > 0 else {
            error = "Enter a valid amount"
            return
        }

        // Convert human-readable amount to smallest unit based on typed side
        let typedToken = quoteAmountType == .exactInput ? fromToken : toToken
        let multiplier = pow(Decimal(10), typedToken.decimals)
        let rawAmount = decimalAmount * multiplier
        let rawAmountString = NSDecimalNumber(decimal: rawAmount).stringValue

        let fromMint = fromToken.contractAddress ?? nativeTokenAddress(for: chain)
        let toMint = toToken.contractAddress ?? nativeTokenAddress(for: chain)

        isLoadingQuote = true
        error = nil
        quote = nil
        defer { isLoadingQuote = false }

        do {
            quote = try await swapService.getQuote(
                from: fromMint,
                to: toMint,
                amount: rawAmountString,
                amountType: quoteAmountType,
                chain: chain,
                slippageBps: slippageBps
            )
            updateDisplayedAmountsFromQuote()
        } catch is CancellationError {
            // Expected when user edits quickly and previous auto-quote task is canceled.
            return
        } catch {
            let nsError = error as NSError
            let isCancelledURLRequest = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
            if isCancelledURLRequest {
                // Ignore transient URLSession cancellation from superseded quote requests.
                return
            }
            self.error = error.localizedDescription
        }
    }

    /// Whether swap execution is supported for the current quote's provider.
    var canExecuteSwap: Bool {
        quote != nil
    }

    /// Executes the swap: signs the transaction and broadcasts it.
    func executeSwap() async {
        guard let quote else { return }

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

    // MARK: - Native Token Address

    /// Returns the native token placeholder address for swap APIs.
    private func nativeTokenAddress(for chain: ChainModel) -> String {
        switch chain.chainType {
        case .solana:
            return "So11111111111111111111111111111111111111112"
        case .evm:
            return CommonTokens.nativeToken
        default:
            return ""
        }
    }

    // MARK: - Price Estimation

    /// Instantly estimates the opposite amount using cached token prices.
    /// Provides immediate feedback while the precise API quote loads.
    private func estimateOppositeAmount() {
        guard let fromToken, let toToken else { return }
        guard fromToken.priceUsd > 0, toToken.priceUsd > 0 else { return }

        if quoteAmountType == .exactInput {
            guard let amount = Decimal(string: fromAmount), amount > 0 else {
                toAmount = ""
                return
            }
            let usdValue = amount * Decimal(fromToken.priceUsd)
            let estimated = usdValue / Decimal(toToken.priceUsd)
            toAmount = formatEstimate(estimated, maxDecimals: min(toToken.decimals, 8))
        } else {
            guard let amount = Decimal(string: toAmount), amount > 0 else {
                fromAmount = ""
                return
            }
            let usdValue = amount * Decimal(toToken.priceUsd)
            let estimated = usdValue / Decimal(fromToken.priceUsd)
            fromAmount = formatEstimate(estimated, maxDecimals: min(fromToken.decimals, 8))
        }
    }

    private func formatEstimate(_ value: Decimal, maxDecimals: Int) -> String {
        let handler = NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: Int16(maxDecimals),
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )
        return NSDecimalNumber(decimal: value).rounding(accordingToBehavior: handler).stringValue
    }

    // MARK: - Formatting

    private func updateDisplayedAmountsFromQuote() {
        guard let quote, let fromToken, let toToken else { return }

        if quoteAmountType == .exactInput {
            toAmount = formatRawAmount(quote.toAmount, decimals: toToken.decimals)
        } else {
            fromAmount = formatRawAmount(quote.fromAmount, decimals: fromToken.decimals)
        }
    }

    private func formatRawAmount(_ raw: String, decimals: Int) -> String {
        guard let decimalRaw = Decimal(string: raw) else { return "" }
        let divisor = pow(Decimal(10), decimals)
        let human = decimalRaw / divisor
        return NSDecimalNumber(decimal: human).stringValue
    }
}
