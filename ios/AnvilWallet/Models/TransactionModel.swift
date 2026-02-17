import Foundation

struct TransactionModel: Identifiable, Codable, Hashable {
    let id: UUID
    let hash: String
    let chain: String
    let from: String
    let to: String
    let amount: Double
    let fee: Double
    let status: TransactionStatus
    let timestamp: Date
    let tokenSymbol: String
    let tokenDecimals: Int
    let contractAddress: String?

    enum TransactionStatus: String, Codable, Hashable {
        case pending
        case confirmed
        case failed

        var displayName: String {
            switch self {
            case .pending: return "Pending"
            case .confirmed: return "Confirmed"
            case .failed: return "Failed"
            }
        }
    }

    init(
        id: UUID = UUID(),
        hash: String,
        chain: String,
        from: String,
        to: String,
        amount: Double,
        fee: Double = 0.0,
        status: TransactionStatus = .pending,
        timestamp: Date = Date(),
        tokenSymbol: String = "ETH",
        tokenDecimals: Int = 18,
        contractAddress: String? = nil
    ) {
        self.id = id
        self.hash = hash
        self.chain = chain
        self.from = from
        self.to = to
        self.amount = amount
        self.fee = fee
        self.status = status
        self.timestamp = timestamp
        self.tokenSymbol = tokenSymbol
        self.tokenDecimals = tokenDecimals
        self.contractAddress = contractAddress
    }

    var formattedAmount: String {
        String(format: "%.4f %@", amount, tokenSymbol)
    }

    var formattedFee: String {
        String(format: "%.6f", fee)
    }

    var shortHash: String {
        guard hash.count > 12 else { return hash }
        let prefix = hash.prefix(6)
        let suffix = hash.suffix(4)
        return "\(prefix)...\(suffix)"
    }

    var shortFrom: String {
        guard from.count > 12 else { return from }
        let prefix = from.prefix(6)
        let suffix = from.suffix(4)
        return "\(prefix)...\(suffix)"
    }

    var shortTo: String {
        guard to.count > 12 else { return to }
        let prefix = to.prefix(6)
        let suffix = to.suffix(4)
        return "\(prefix)...\(suffix)"
    }

    // MARK: - Preview Data

    static let preview = TransactionModel(
        hash: "0xabc123def456789012345678901234567890abcd",
        chain: "ethereum",
        from: "0x1234567890abcdef1234567890abcdef12345678",
        to: "0xabcdef1234567890abcdef1234567890abcdef12",
        amount: 0.5,
        fee: 0.002,
        status: .confirmed,
        timestamp: Date().addingTimeInterval(-3600),
        tokenSymbol: "ETH"
    )
}
