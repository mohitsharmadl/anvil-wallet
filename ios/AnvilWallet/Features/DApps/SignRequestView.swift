import SwiftUI

/// SignRequestView presents a WalletConnect sign request from a connected dApp.
///
/// Supports:
///   - personal_sign (message signing)
///   - eth_signTypedData (EIP-712)
///   - eth_sendTransaction (transaction signing)
///   - solana_signTransaction (Solana transaction signing)
///   - solana_signMessage (Solana message signing)
struct SignRequestView: View {
    @StateObject private var walletConnect = WalletConnectService.shared
    @EnvironmentObject var walletService: WalletService
    @Environment(\.dismiss) private var dismiss

    let request: WalletConnectService.WCSignRequest

    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var riskAssessment: RiskAssessment?
    @State private var balanceChanges: [BalanceChangeSimulator.BalanceChange] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // DApp info
                VStack(spacing: 8) {
                    Circle()
                        .fill(Color.backgroundElevated)
                        .frame(width: 48, height: 48)
                        .overlay(
                            Image(systemName: "signature")
                                .foregroundColor(.textSecondary)
                        )

                    Text(request.peerName)
                        .font(.headline)
                        .foregroundColor(.textPrimary)

                    Text(requestDescription)
                        .font(.body)
                        .foregroundColor(.textSecondary)
                }
                .padding(.top, 24)

                // Request details
                VStack(alignment: .leading, spacing: 12) {
                    DetailItem(label: "Method", value: request.method)
                    DetailItem(label: "Chain", value: request.chain)

                    requestDataView
                }
                .padding()
                .background(Color.backgroundCard)
                .cornerRadius(16)
                .padding(.horizontal, 20)

                // Risk banner (eth_sendTransaction only)
                if let risk = riskAssessment {
                    RiskBannerView(assessment: risk)
                }

                // Balance change preview (eth_sendTransaction only)
                if !balanceChanges.isEmpty {
                    BalanceChangePreviewView(changes: balanceChanges)
                }

                // Security note
                HStack(spacing: 8) {
                    Image(systemName: "faceid")
                        .foregroundColor(.accentGreen)

                    Text("Signing requires biometric authentication.")
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                }
                .padding(12)
                .background(Color.backgroundCard)
                .cornerRadius(12)
                .padding(.horizontal, 20)

                Spacer()

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.error)
                        .padding(.horizontal, 20)
                }

                // Buttons
                VStack(spacing: 12) {
                    Button {
                        Task {
                            isProcessing = true
                            errorMessage = nil
                            do {
                                try await walletConnect.approveRequest(request, walletService: walletService)
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                            isProcessing = false
                        }
                    } label: {
                        Text(approveButtonLabel)
                    }
                    .buttonStyle(.primary)
                    .disabled(isProcessing || riskAssessment?.overallLevel == .danger)

                    Button {
                        Task {
                            isProcessing = true
                            try? await walletConnect.rejectRequest(request)
                            isProcessing = false
                            dismiss()
                        }
                    } label: {
                        Text("Reject")
                            .font(.headline)
                            .foregroundColor(.error)
                    }
                    .disabled(isProcessing)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Sign Request")
            .navigationBarTitleDisplayMode(.inline)
            .loadingOverlay(isLoading: isProcessing, message: "Signing...")
            .task {
                // Risk assessment + balance preview for eth_sendTransaction only
                if request.method == "eth_sendTransaction", let tx = parsedTransaction {
                    riskAssessment = TransactionRiskEngine.shared.assessWCTransaction(
                        to: tx.to,
                        value: tx.value,
                        data: tx.data,
                        previousTransactions: walletService.transactions
                    )

                    // Determine chain symbol from WC chain format ("eip155:1")
                    let chainSymbol: String
                    if let chainIdStr = request.chain.split(separator: ":").last,
                       let chainId = UInt64(chainIdStr),
                       let chain = ChainModel.allChains.first(where: { $0.evmChainId == chainId }) {
                        chainSymbol = chain.symbol
                    } else {
                        chainSymbol = "ETH"
                    }

                    balanceChanges = BalanceChangeSimulator.simulateWC(
                        to: tx.to,
                        value: tx.value,
                        data: tx.data,
                        chainSymbol: chainSymbol
                    )
                }
            }
        }
    }
}

// MARK: - Method-specific data display

extension SignRequestView {

    /// Human-readable description for the request action.
    private var requestDescription: String {
        switch request.method {
        case "eth_sendTransaction":
            return "requests a transaction"
        case "solana_signTransaction":
            return "requests a Solana transaction"
        case "solana_signMessage":
            return "requests a Solana message signature"
        default:
            return "requests a signature"
        }
    }

    /// Approve button label varies by method.
    private var approveButtonLabel: String {
        switch request.method {
        case "eth_sendTransaction":
            return "Sign & Send"
        case "solana_signTransaction":
            return "Sign Transaction"
        default:
            return "Sign"
        }
    }

    /// Returns a view appropriate for the request method.
    @ViewBuilder
    var requestDataView: some View {
        switch request.method {
        case "eth_sendTransaction":
            transactionDataView
        case "eth_signTypedData_v4":
            typedDataView
        case "solana_signTransaction":
            solanaTransactionDataView
        case "solana_signMessage":
            solanaMessageDataView
        default:
            rawDataView
        }
    }

    private var transactionDataView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tx = parsedTransaction {
                DetailItem(label: "To", value: tx.to)
                if let value = tx.value, value != "0x0" {
                    DetailItem(label: "Value", value: value)
                }
                if let data = tx.data, !data.isEmpty, data != "0x" {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Calldata")
                            .font(.subheadline.bold())
                            .foregroundColor(.textSecondary)
                        Text(data.prefix(200) + (data.count > 200 ? "..." : ""))
                            .font(.caption.monospaced())
                            .foregroundColor(.textPrimary)
                    }
                }
                if let gas = tx.gas {
                    DetailItem(label: "Gas Limit", value: gas)
                }
            } else {
                rawDataView
            }
        }
    }

    private var typedDataView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let info = parsedTypedDataInfo {
                if let domain = info.domain {
                    DetailItem(label: "Domain", value: domain)
                }
                DetailItem(label: "Type", value: info.primaryType)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Message")
                        .font(.subheadline.bold())
                        .foregroundColor(.textSecondary)
                    ScrollView {
                        Text(info.messagePreview)
                            .font(.caption.monospaced())
                            .foregroundColor(.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                    .padding(12)
                    .background(Color.backgroundElevated)
                    .cornerRadius(8)
                }
            } else {
                rawDataView
            }
        }
    }

    private var rawDataView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Data")
                .font(.subheadline.bold())
                .foregroundColor(.textSecondary)
            ScrollView {
                if let paramsString = String(data: request.params, encoding: .utf8) {
                    Text(paramsString)
                        .font(.caption.monospaced())
                        .foregroundColor(.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("\(request.params.count) bytes")
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                }
            }
            .frame(maxHeight: 200)
            .padding(12)
            .background(Color.backgroundElevated)
            .cornerRadius(8)
        }
    }

    // MARK: - Solana data display

    private var solanaTransactionDataView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let txBase58 = parsedSolanaTransaction {
                DetailItem(label: "Network", value: solanaNetworkName)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transaction")
                        .font(.subheadline.bold())
                        .foregroundColor(.textSecondary)
                    ScrollView {
                        Text(txBase58.prefix(120) + (txBase58.count > 120 ? "..." : ""))
                            .font(.caption.monospaced())
                            .foregroundColor(.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .padding(12)
                    .background(Color.backgroundElevated)
                    .cornerRadius(8)
                }
                if let rawBytes = Base58.decode(txBase58) {
                    DetailItem(label: "Size", value: "\(rawBytes.count) bytes")
                }
            } else {
                rawDataView
            }
        }
    }

    private var solanaMessageDataView: some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailItem(label: "Network", value: solanaNetworkName)
            if let messageBase58 = parsedSolanaMessage {
                // Try to display the message as UTF-8 text if it decodes cleanly
                if let messageData = Base58.decode(messageBase58),
                   let utf8 = String(data: messageData, encoding: .utf8),
                   utf8.allSatisfy({ !$0.isNewline || $0 == "\n" }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Message")
                            .font(.subheadline.bold())
                            .foregroundColor(.textSecondary)
                        ScrollView {
                            Text(utf8)
                                .font(.body.monospaced())
                                .foregroundColor(.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                        .padding(12)
                        .background(Color.backgroundElevated)
                        .cornerRadius(8)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Message (base58)")
                            .font(.subheadline.bold())
                            .foregroundColor(.textSecondary)
                        Text(messageBase58.prefix(200) + (messageBase58.count > 200 ? "..." : ""))
                            .font(.caption.monospaced())
                            .foregroundColor(.textPrimary)
                    }
                }
            } else {
                rawDataView
            }
        }
    }

    /// Solana network name from the WC chain ID.
    private var solanaNetworkName: String {
        if request.chain.contains("5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp") {
            return "Solana Mainnet"
        } else if request.chain.contains("4uhcVJyU9pJkvQyS88uRDiswHXSCkY3z") {
            return "Solana Testnet"
        } else if request.chain.contains("EtWTRABZaYq6iMfeYKouRu166VU2xqa1") {
            return "Solana Devnet"
        }
        return request.chain
    }

    /// Parses the base58 transaction string from solana_signTransaction params.
    private var parsedSolanaTransaction: String? {
        guard let dict = try? JSONSerialization.jsonObject(with: request.params) as? [String: Any],
              let tx = dict["transaction"] as? String else {
            return nil
        }
        return tx
    }

    /// Parses the base58 message string from solana_signMessage params.
    private var parsedSolanaMessage: String? {
        guard let dict = try? JSONSerialization.jsonObject(with: request.params) as? [String: Any],
              let msg = dict["message"] as? String else {
            return nil
        }
        return msg
    }

    // MARK: - EVM Parsing helpers

    private struct ParsedTransaction {
        let to: String
        let value: String?
        let data: String?
        let gas: String?
    }

    private var parsedTransaction: ParsedTransaction? {
        guard let jsonArray = try? JSONSerialization.jsonObject(with: request.params) as? [[String: Any]],
              let tx = jsonArray.first,
              let to = tx["to"] as? String else {
            return nil
        }
        return ParsedTransaction(
            to: to,
            value: tx["value"] as? String,
            data: tx["data"] as? String,
            gas: (tx["gas"] as? String) ?? (tx["gasLimit"] as? String)
        )
    }

    private struct TypedDataInfo {
        let domain: String?
        let primaryType: String
        let messagePreview: String
    }

    private var parsedTypedDataInfo: TypedDataInfo? {
        // Params: [address, typedDataJSON]
        guard let array = try? JSONDecoder().decode([String].self, from: request.params),
              array.count >= 2,
              let tdData = array[1].data(using: .utf8),
              let td = try? JSONSerialization.jsonObject(with: tdData) as? [String: Any],
              let primaryType = td["primaryType"] as? String else {
            return nil
        }

        var domainStr: String?
        if let domain = td["domain"] as? [String: Any] {
            let parts = [
                domain["name"] as? String,
                domain["version"].map { "v\($0)" },
            ].compactMap { $0 }
            if !parts.isEmpty { domainStr = parts.joined(separator: " ") }
        }

        var messagePreview = ""
        if let message = td["message"] as? [String: Any],
           let msgData = try? JSONSerialization.data(withJSONObject: message, options: [.prettyPrinted, .sortedKeys]),
           let msgStr = String(data: msgData, encoding: .utf8) {
            messagePreview = msgStr
        }

        return TypedDataInfo(
            domain: domainStr,
            primaryType: primaryType,
            messagePreview: messagePreview
        )
    }
}

private struct DetailItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline.bold())
                .foregroundColor(.textSecondary)

            Text(value)
                .font(.body.monospaced())
                .foregroundColor(.textPrimary)
        }
    }
}

#Preview {
    SignRequestView(
        request: WalletConnectService.WCSignRequest(
            id: "test",
            sessionId: "session1",
            chain: "eip155:1",
            method: "personal_sign",
            params: "Hello from Uniswap".data(using: .utf8)!,
            peerName: "Uniswap"
        )
    )
}
