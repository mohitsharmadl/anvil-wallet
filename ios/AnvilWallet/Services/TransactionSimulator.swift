import Foundation

/// TransactionSimulator performs pre-sign transaction simulation via `eth_call`
/// to estimate gas costs and detect potential errors before the user commits
/// to signing a transaction.
///
/// This helps prevent:
///   - Sending to contracts that will revert
///   - Underestimating gas (leading to stuck transactions)
///   - Sending tokens to addresses that can't receive them
final class TransactionSimulator {

    private let rpcService = RPCService.shared

    struct SimulationResult {
        let success: Bool
        let estimatedGas: UInt64
        let gasPrice: UInt64
        let estimatedFee: Double    // In native token (e.g., ETH)
        let estimatedFeeUsd: Double
        let errorMessage: String?
        let warnings: [String]

        var totalCostDescription: String {
            String(format: "%.6f", estimatedFee)
        }
    }

    enum SimulationError: LocalizedError {
        case simulationFailed(String)
        case unsupportedChain
        case invalidTransaction

        var errorDescription: String? {
            switch self {
            case .simulationFailed(let reason):
                return "Transaction simulation failed: \(reason)"
            case .unsupportedChain:
                return "Transaction simulation is not supported for this chain."
            case .invalidTransaction:
                return "Invalid transaction parameters."
            }
        }
    }

    // MARK: - Simulate

    /// Simulates an EVM transaction and returns the estimated gas and fee.
    ///
    /// - Parameters:
    ///   - chain: The chain to simulate on
    ///   - from: Sender address
    ///   - to: Recipient address
    ///   - value: Value in wei (hex string)
    ///   - data: Optional calldata (hex string) for contract interactions
    ///   - nativeTokenPriceUsd: Current USD price of the native token
    /// - Returns: SimulationResult with gas estimate and fee breakdown
    func simulate(
        chain: ChainModel,
        from: String,
        to: String,
        value: String,
        data: String? = nil,
        nativeTokenPriceUsd: Double = 0.0
    ) async throws -> SimulationResult {
        guard chain.chainType == .evm else {
            throw SimulationError.unsupportedChain
        }

        var warnings: [String] = []

        // Step 1: Simulate via eth_call to check for revert
        do {
            let callData = data ?? "0x"
            _ = try await rpcService.ethCall(
                rpcUrl: chain.activeRpcUrl,
                to: to,
                data: callData
            )
        } catch {
            return SimulationResult(
                success: false,
                estimatedGas: 0,
                gasPrice: 0,
                estimatedFee: 0,
                estimatedFeeUsd: 0,
                errorMessage: "Transaction would revert: \(error.localizedDescription)",
                warnings: []
            )
        }

        // Step 2: Estimate gas
        let gasHex: String
        do {
            gasHex = try await rpcService.estimateGas(
                rpcUrl: chain.activeRpcUrl,
                from: from,
                to: to,
                value: value,
                data: data
            )
        } catch {
            return SimulationResult(
                success: false,
                estimatedGas: 0,
                gasPrice: 0,
                estimatedFee: 0,
                estimatedFeeUsd: 0,
                errorMessage: "Gas estimation failed: \(error.localizedDescription)",
                warnings: []
            )
        }

        // Step 3: Get current gas price
        let gasPriceHex = try await rpcService.gasPrice(rpcUrl: chain.activeRpcUrl)

        // Parse hex values
        let estimatedGas = UInt64(gasHex.dropFirst(2), radix: 16) ?? 21000
        let gasPrice = UInt64(gasPriceHex.dropFirst(2), radix: 16) ?? 0

        // Add 20% buffer to gas estimate for safety
        let bufferedGas = UInt64(Double(estimatedGas) * 1.2)

        // Calculate fee in native token
        let feeWei = Double(bufferedGas) * Double(gasPrice)
        let feeInNativeToken = feeWei / 1e18

        // Check for high gas
        if feeInNativeToken > 0.01 {
            warnings.append("Gas fee is relatively high. Consider waiting for lower gas prices.")
        }

        return SimulationResult(
            success: true,
            estimatedGas: bufferedGas,
            gasPrice: gasPrice,
            estimatedFee: feeInNativeToken,
            estimatedFeeUsd: feeInNativeToken * nativeTokenPriceUsd,
            errorMessage: nil,
            warnings: warnings
        )
    }

    /// Simulates a token transfer (ERC-20) by encoding the transfer function call.
    ///
    /// - Parameters:
    ///   - chain: The chain to simulate on
    ///   - from: Sender address
    ///   - tokenContract: The ERC-20 token contract address
    ///   - to: Recipient address
    ///   - amount: Amount in the token's smallest unit (hex string)
    ///   - nativeTokenPriceUsd: Current USD price of the native token
    /// - Returns: SimulationResult
    func simulateTokenTransfer(
        chain: ChainModel,
        from: String,
        tokenContract: String,
        to: String,
        amount: String,
        nativeTokenPriceUsd: Double = 0.0
    ) async throws -> SimulationResult {
        // Encode ERC-20 transfer(address,uint256) function call
        // Function selector: 0xa9059cbb
        let paddedTo = String(repeating: "0", count: 24) + to.dropFirst(2)
        let paddedAmount = String(repeating: "0", count: max(0, 64 - amount.count)) + amount
        let callData = "0xa9059cbb" + paddedTo + paddedAmount

        return try await simulate(
            chain: chain,
            from: from,
            to: tokenContract,
            value: "0x0",
            data: callData,
            nativeTokenPriceUsd: nativeTokenPriceUsd
        )
    }
}
