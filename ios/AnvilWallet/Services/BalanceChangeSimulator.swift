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
                let weiDecimal = hexToDecimal(cleanValue)
                if weiDecimal > 0 {
                    changes.append(BalanceChange(
                        tokenSymbol: chainSymbol,
                        amount: formatWei(weiDecimal),
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
                    let amount = hexToDecimal(String(amountHex))
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
                    let amount = hexToDecimal(String(amountHex))
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

    /// Converts a hex string to a Decimal using digit-by-digit accumulation.
    /// Decimal has ~38 significant digits — sufficient for uint256 display
    /// (uint256.max is 78 digits, but token amounts rarely exceed 30).
    private static func hexToDecimal(_ hex: String) -> Decimal {
        var result = Decimal(0)
        for char in hex {
            guard let digit = Int(String(char), radix: 16) else { return 0 }
            result = result * 16 + Decimal(digit)
        }
        return result
    }

    /// Divides a Decimal by 10^exp for human-readable display.
    private static func divideByDecimals(_ value: Decimal, _ exp: Int) -> Decimal {
        var divisor = Decimal(1)
        for _ in 0..<exp { divisor *= 10 }
        return value / divisor
    }

    private static func formatDecimal(_ value: Decimal) -> String {
        if value == 0 { return "0" }
        let d = NSDecimalNumber(decimal: value).doubleValue
        if d < 0.0001 { return String(format: "%.18g", d) }
        if d < 1 { return String(format: "%.6f", d) }
        return String(format: "%.4f", d)
    }

    /// Formats a raw token amount (no decimal info known).
    /// Heuristic: if value > 10^15, assume 18 decimals; if > 10^6, assume 6.
    private static func formatTokenAmount(_ rawAmount: Decimal) -> String {
        if rawAmount == 0 { return "0" }
        let threshold18 = Decimal(sign: .plus, exponent: 15, significand: 1) // 10^15
        let threshold6 = Decimal(sign: .plus, exponent: 6, significand: 1)   // 10^6
        if rawAmount > threshold18 {
            return formatDecimal(divideByDecimals(rawAmount, 18))
        }
        if rawAmount > threshold6 {
            return formatDecimal(divideByDecimals(rawAmount, 6))
        }
        return formatDecimal(rawAmount)
    }

    /// Formats a wei value to ETH with Decimal precision.
    private static func formatWei(_ weiDecimal: Decimal) -> String {
        let ethAmount = divideByDecimals(weiDecimal, 18)
        return formatDecimal(ethAmount)
    }
}
