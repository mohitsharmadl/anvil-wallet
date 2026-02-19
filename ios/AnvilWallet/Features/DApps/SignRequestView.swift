import SwiftUI

/// SignRequestView presents a WalletConnect sign request from a connected dApp.
///
/// Supports:
///   - personal_sign (message signing)
///   - eth_signTypedData (EIP-712)
///   - eth_sendTransaction (transaction signing)
struct SignRequestView: View {
    @StateObject private var walletConnect = WalletConnectService.shared
    @EnvironmentObject var walletService: WalletService
    @Environment(\.dismiss) private var dismiss

    let request: WalletConnectService.WCSignRequest

    @State private var isProcessing = false
    @State private var errorMessage: String?

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

                    Text(request.method == "eth_sendTransaction"
                         ? "requests a transaction"
                         : "requests a signature")
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
                        Text(request.method == "eth_sendTransaction" ? "Sign & Send" : "Sign")
                    }
                    .buttonStyle(.primary)
                    .disabled(isProcessing)

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
        }
    }
}

// MARK: - Method-specific data display

extension SignRequestView {

    /// Returns a view appropriate for the request method.
    @ViewBuilder
    var requestDataView: some View {
        switch request.method {
        case "eth_sendTransaction":
            transactionDataView
        case "eth_signTypedData_v4":
            typedDataView
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

    // MARK: - Parsing helpers

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
