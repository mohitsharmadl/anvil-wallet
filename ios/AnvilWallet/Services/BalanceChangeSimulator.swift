import Foundation

/// Simulates balance changes from a transaction by decoding known function selectors.
/// Provides human-readable "+500 USDC" / "-0.15 ETH" display data.
struct BalanceChangeSimulator {

    // MARK: - Types

    struct BalanceChange: Identifiable {
        let id = UUID()
        let tokenSymbol: String
        let amount: String         // human-readable, e.g. "0.15"
        let isOutgoing: Bool
        let isGasFee: Bool
    }

    // MARK: - Known selectors (first 4 bytes of calldata)

    private static let transferSelector = "a9059cbb"      // transfer(address,uint256)
    private static let approveSelector = "095ea7b3"        // approve(address,uint256)
    private static let transferFromSelector = "23b872dd"   // transferFrom(address,address,uint256)

    // MARK: - Simulate In-App Transaction

    /// Simulates balance changes for a native send or ERC-20 transfer from the app.
    static func simulate(
        amount: String,
        tokenSymbol: String,
        isERC20: Bool,
        estimatedFee: String,
        nativeSymbol: String
    ) -> [BalanceChange] {
        var changes: [BalanceChange] = []

        // Token outflow
        if let amountVal = Double(amount), amountVal > 0 {
            changes.append(BalanceChange(
                tokenSymbol: tokenSymbol,
                amount: amount,
                isOutgoing: true,
                isGasFee: false
            ))
        }

        // Gas fee (always in native token)
        if let feeVal = Double(estimatedFee), feeVal > 0 {
            changes.append(BalanceChange(
                tokenSymbol: nativeSymbol,
                amount: estimatedFee,
                isOutgoing: true,
                isGasFee: true
            ))
        }

        return changes
    }

    // MARK: - Simulate WC Transaction

    /// Simulates balance changes for a WalletConnect eth_sendTransaction.
    /// Decodes known selectors; falls back to "unknown contract interaction".
    static func simulateWC(
        to: String?,
        value: String?,
        data: String?,
        chainSymbol: String
    ) -> [BalanceChange] {
        var changes: [BalanceChange] = []

        // Native value transfer
        if let value = value {
            let cleanValue = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
            let isZero = cleanValue.isEmpty || cleanValue.allSatisfy { $0 == "0" }
            if !isZero {
                let weiDouble = hexToDouble(cleanValue)
                let ethAmount = weiDouble / 1e18
                if ethAmount > 0 {
                    changes.append(BalanceChange(
                        tokenSymbol: chainSymbol,
                        amount: formatAmount(ethAmount),
                        isOutgoing: true,
                        isGasFee: false
                    ))
                }
            }
        }

        // Decode calldata
        if let data = data, data.count >= 10 {
            let cleanData = data.hasPrefix("0x") ? String(data.dropFirst(2)) : data
            let selector = String(cleanData.prefix(8)).lowercased()

            switch selector {
            case transferSelector:
                // transfer(address, uint256) — ERC-20 send
                if cleanData.count >= 136 {
                    let amountHex = String(cleanData.suffix(from: cleanData.index(cleanData.startIndex, offsetBy: 72))).prefix(64)
                    let amount = hexToDouble(String(amountHex))
                    // We don't know decimals here — show raw if large, else as-is
                    changes.append(BalanceChange(
                        tokenSymbol: "ERC-20",
                        amount: formatTokenAmount(amount),
                        isOutgoing: true,
                        isGasFee: false
                    ))
                }

            case approveSelector:
                // approve(address, uint256) — no balance change, just approval
                let amountHex: String
                if cleanData.count >= 136 {
                    amountHex = String(cleanData.suffix(from: cleanData.index(cleanData.startIndex, offsetBy: 72))).prefix(64).description
                } else {
                    amountHex = ""
                }
                let isUnlimited = !amountHex.isEmpty && amountHex.allSatisfy { $0 == "f" || $0 == "F" }
                changes.append(BalanceChange(
                    tokenSymbol: isUnlimited ? "Unlimited Approval" : "Token Approval",
                    amount: "0",
                    isOutgoing: false,
                    isGasFee: false
                ))

            case transferFromSelector:
                // transferFrom(from, to, uint256)
                if cleanData.count >= 200 {
                    let amountHex = String(cleanData.suffix(from: cleanData.index(cleanData.startIndex, offsetBy: 136))).prefix(64)
                    let amount = hexToDouble(String(amountHex))
                    changes.append(BalanceChange(
                        tokenSymbol: "ERC-20",
                        amount: formatTokenAmount(amount),
                        isOutgoing: true,
                        isGasFee: false
                    ))
                }

            default:
                // Unknown contract interaction
                changes.append(BalanceChange(
                    tokenSymbol: "Contract Interaction",
                    amount: "",
                    isOutgoing: false,
                    isGasFee: false
                ))
            }
        }

        // Gas fee deduction (always present for EVM transactions)
        changes.append(BalanceChange(
            tokenSymbol: chainSymbol,
            amount: "",
            isOutgoing: true,
            isGasFee: true
        ))

        return changes
    }

    // MARK: - Helpers

    private static func hexToDouble(_ hex: String) -> Double {
        var result: Double = 0
        for char in hex {
            guard let digit = Int(String(char), radix: 16) else { return 0 }
            result = result * 16.0 + Double(digit)
        }
        return result
    }

    private static func formatAmount(_ value: Double) -> String {
        if value == 0 { return "0" }
        if value < 0.0001 { return String(format: "%.18g", value) }
        if value < 1 { return String(format: "%.6f", value) }
        return String(format: "%.4f", value)
    }

    /// Formats a raw token amount (no decimal info) — show in scientific if very large.
    private static func formatTokenAmount(_ rawAmount: Double) -> String {
        if rawAmount == 0 { return "0" }
        if rawAmount > 1e15 {
            // Likely has 18 decimals — divide
            return formatAmount(rawAmount / 1e18)
        }
        if rawAmount > 1e6 {
            return formatAmount(rawAmount / 1e6)
        }
        return formatAmount(rawAmount)
    }
}
