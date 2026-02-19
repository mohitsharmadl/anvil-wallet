import Foundation

// MARK: - Risk Types

enum RiskLevel: Comparable {
    case safe
    case warning
    case danger

    var label: String {
        switch self {
        case .safe: return "Safe"
        case .warning: return "Warning"
        case .danger: return "Danger"
        }
    }
}

struct RiskFinding {
    let level: RiskLevel
    let title: String
    let detail: String
}

struct RiskAssessment {
    let overallLevel: RiskLevel
    let findings: [RiskFinding]
}

// MARK: - Transaction Risk Engine

/// Evaluates transaction risk based on heuristic rules:
///   1. First interaction — never sent to this address before
///   2. Large amount — value > 50% of token balance
///   3. Unlimited approval — approve(spender, type(uint256).max)
///   4. Known phishing — recipient in bundled blocklist
///   5. Zero-value transfer — address poisoning pattern
final class TransactionRiskEngine {

    static let shared = TransactionRiskEngine()

    private var blocklist: Set<String> = []

    private init() {
        loadBlocklist()
    }

    // MARK: - Blocklist

    private func loadBlocklist() {
        guard let url = Bundle.main.url(forResource: "PhishingBlocklist", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let addresses = json["addresses"] as? [String] else {
            return
        }
        blocklist = Set(addresses.map { $0.lowercased() })
    }

    // MARK: - Assess In-App Transaction

    /// Assesses risk for a native send/ERC-20 transfer initiated from the app.
    func assess(
        to: String,
        amount: String,
        tokenSymbol: String,
        tokenBalance: Double,
        tokenDecimals: Int,
        contractAddress: String?,
        previousTransactions: [TransactionModel]
    ) -> RiskAssessment {
        var findings: [RiskFinding] = []

        // Rule 1: First interaction
        let normalizedTo = to.lowercased()
        let hasSentBefore = previousTransactions.contains { $0.to.lowercased() == normalizedTo }
        if !hasSentBefore {
            findings.append(RiskFinding(
                level: .warning,
                title: "New Address",
                detail: "You have never sent to this address before. Double-check it is correct."
            ))
        }

        // Rule 2: Large amount (> 50% of balance)
        if let amountValue = Double(amount), tokenBalance > 0 {
            let ratio = amountValue / tokenBalance
            if ratio > 0.5 {
                let pct = Int(ratio * 100)
                findings.append(RiskFinding(
                    level: .warning,
                    title: "Large Transfer",
                    detail: "This sends \(pct)% of your \(tokenSymbol) balance."
                ))
            }
        }

        // Rule 4: Known phishing address
        if blocklist.contains(normalizedTo) {
            findings.append(RiskFinding(
                level: .danger,
                title: "Known Phishing Address",
                detail: "This address has been flagged as a known scam or phishing address."
            ))
        }

        // Rule 5: Zero-value transfer
        if let amountValue = Double(amount), amountValue == 0 {
            findings.append(RiskFinding(
                level: .warning,
                title: "Zero-Value Transfer",
                detail: "Sending zero tokens is a common address-poisoning pattern."
            ))
        }

        let overall = findings.map(\.level).max() ?? .safe
        return RiskAssessment(overallLevel: overall, findings: findings)
    }

    // MARK: - Assess WalletConnect Transaction

    /// Assesses risk for a WalletConnect eth_sendTransaction request.
    func assessWCTransaction(
        to: String?,
        value: String?,
        data: String?,
        previousTransactions: [TransactionModel]
    ) -> RiskAssessment {
        var findings: [RiskFinding] = []

        guard let to = to else {
            // Contract creation — unusual from a dApp
            findings.append(RiskFinding(
                level: .warning,
                title: "Contract Creation",
                detail: "This transaction creates a new contract. Review carefully."
            ))
            let overall = findings.map(\.level).max() ?? .safe
            return RiskAssessment(overallLevel: overall, findings: findings)
        }

        let normalizedTo = to.lowercased()

        // Rule 1: First interaction
        let hasSentBefore = previousTransactions.contains { $0.to.lowercased() == normalizedTo }
        if !hasSentBefore {
            findings.append(RiskFinding(
                level: .warning,
                title: "New Address",
                detail: "You have never interacted with this address before."
            ))
        }

        // Rule 3: Unlimited approval detection
        if let data = data, data.count >= 10 {
            let cleanData = data.hasPrefix("0x") ? String(data.dropFirst(2)) : data
            // approve(address,uint256) selector = 095ea7b3
            if cleanData.hasPrefix("095ea7b3") && cleanData.count >= 136 {
                // Extract uint256 amount (bytes 36-68 = chars 72-136 in hex)
                let amountHex = String(cleanData.suffix(from: cleanData.index(cleanData.startIndex, offsetBy: 72)))
                    .prefix(64)
                // type(uint256).max = fff...f (64 f's)
                let isUnlimited = amountHex.allSatisfy { $0 == "f" || $0 == "F" }
                if isUnlimited {
                    findings.append(RiskFinding(
                        level: .danger,
                        title: "Unlimited Token Approval",
                        detail: "This grants unlimited spending of your tokens to a contract. Consider setting a specific limit."
                    ))
                } else {
                    findings.append(RiskFinding(
                        level: .warning,
                        title: "Token Approval",
                        detail: "This grants a contract permission to spend your tokens."
                    ))
                }
            }
        }

        // Rule 4: Known phishing address
        if blocklist.contains(normalizedTo) {
            findings.append(RiskFinding(
                level: .danger,
                title: "Known Phishing Address",
                detail: "This address has been flagged as a known scam or phishing address."
            ))
        }

        // Rule 5: Zero-value transfer with no calldata
        if let value = value {
            let cleanValue = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
            let isZero = cleanValue.allSatisfy { $0 == "0" } || cleanValue.isEmpty
            let hasNoData = data == nil || data == "0x" || data?.isEmpty == true
            if isZero && hasNoData {
                findings.append(RiskFinding(
                    level: .warning,
                    title: "Zero-Value Transfer",
                    detail: "This sends zero ETH with no data — a common address-poisoning pattern."
                ))
            }
        }

        let overall = findings.map(\.level).max() ?? .safe
        return RiskAssessment(overallLevel: overall, findings: findings)
    }
}
