import SwiftUI

/// Displays token approvals and allows revoking them.
struct ApprovalTrackerView: View {
    @EnvironmentObject var walletService: WalletService

    @State private var approvals: [ApprovalService.TokenApproval] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var revokingIds: Set<String> = []
    @State private var revokeError: String?

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(.accentGreen)
                    Text("Scanning approvals...")
                        .font(.subheadline)
                        .foregroundColor(.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.warning)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await loadApprovals() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentGreen)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if approvals.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.success)
                    Text("No Active Approvals")
                        .font(.headline)
                        .foregroundColor(.textPrimary)
                    Text("You haven't approved any contracts to spend your tokens.")
                        .font(.subheadline)
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if let revokeError {
                        Section {
                            Text(revokeError)
                                .font(.caption)
                                .foregroundColor(.error)
                        }
                        .listRowBackground(Color.error.opacity(0.1))
                    }

                    Section {
                        Text("\(approvals.count) active approval\(approvals.count == 1 ? "" : "s") found on Ethereum")
                            .font(.caption)
                            .foregroundColor(.textSecondary)
                    }
                    .listRowBackground(Color.clear)

                    ForEach(groupedApprovals, id: \.key) { group in
                        Section(group.key) {
                            ForEach(group.value) { approval in
                                ApprovalRow(
                                    approval: approval,
                                    isRevoking: revokingIds.contains(approval.id)
                                ) {
                                    await revokeApproval(approval)
                                }
                            }
                        }
                        .listRowBackground(Color.backgroundCard)
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable {
                    await loadApprovals()
                }
            }
        }
        .background(Color.backgroundPrimary)
        .navigationTitle("Token Approvals")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadApprovals()
        }
    }

    // MARK: - Grouped

    private var groupedApprovals: [(key: String, value: [ApprovalService.TokenApproval])] {
        let grouped = Dictionary(grouping: approvals) { $0.tokenSymbol }
        return grouped.sorted { $0.key < $1.key }
    }

    // MARK: - Load

    private func loadApprovals() async {
        isLoading = true
        errorMessage = nil

        guard let address = walletService.addresses["ethereum"] else {
            errorMessage = "No Ethereum address found."
            isLoading = false
            return
        }

        do {
            approvals = try await ApprovalService.shared.fetchApprovals(for: address)
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    // MARK: - Revoke

    private func revokeApproval(_ approval: ApprovalService.TokenApproval) async {
        revokeError = nil
        revokingIds.insert(approval.id)

        guard let ethChain = ChainModel.allChains.first(where: { $0.id == "ethereum" }),
              let chainId = ethChain.evmChainId,
              let address = walletService.addresses["ethereum"] else {
            revokeError = "Missing chain configuration."
            revokingIds.remove(approval.id)
            return
        }

        do {
            // Get nonce and gas params
            let nonceHex = try await RPCService.shared.getTransactionCount(
                rpcUrl: ethChain.rpcUrl,
                address: address
            )
            let nonce = UInt64(nonceHex.dropFirst(2), radix: 16) ?? 0

            let feeData = try await RPCService.shared.feeHistory(rpcUrl: ethChain.rpcUrl)
            let baseFee = UInt64(feeData.baseFeeHex.dropFirst(2), radix: 16) ?? 0
            let priorityFee = UInt64(feeData.priorityFeeHex.dropFirst(2), radix: 16) ?? 1_500_000_000
            let maxFee = baseFee * 2 + priorityFee
            let maxFeeHex = "0x" + String(maxFee, radix: 16)

            let calldata = await ApprovalService.shared.buildRevokeCalldata(spender: approval.spender)
            let calldataBytes = Data(hexString: calldata)

            // Estimate gas
            let gasHex = try await RPCService.shared.estimateGas(
                rpcUrl: ethChain.rpcUrl,
                from: address,
                to: approval.tokenAddress,
                value: "0x0",
                data: calldata
            )
            let gasLimit = UInt64(gasHex.dropFirst(2), radix: 16) ?? 60000

            let ethReq = EthTransactionRequest(
                chainId: chainId,
                nonce: nonce,
                to: approval.tokenAddress,
                valueWeiHex: "0x0",
                data: calldataBytes,
                maxPriorityFeeHex: feeData.priorityFeeHex,
                maxFeeHex: maxFeeHex,
                gasLimit: gasLimit
            )

            let signedTx = try await walletService.signTransaction(request: .eth(ethReq))
            let signedHex = "0x" + signedTx.map { String(format: "%02x", $0) }.joined()
            _ = try await RPCService.shared.sendRawTransaction(
                rpcUrl: ethChain.rpcUrl,
                signedTx: signedHex
            )

            // Remove from list on success
            approvals.removeAll { $0.id == approval.id }
            revokingIds.remove(approval.id)
        } catch {
            revokeError = "Revoke failed: \(error.localizedDescription)"
            revokingIds.remove(approval.id)
        }
    }
}

// MARK: - Approval Row

private struct ApprovalRow: View {
    let approval: ApprovalService.TokenApproval
    let isRevoking: Bool
    let onRevoke: () async -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Spender")
                    .font(.caption)
                    .foregroundColor(.textSecondary)

                Text(shortAddress(approval.spender))
                    .font(.body.monospaced())
                    .foregroundColor(.textPrimary)

                if approval.isUnlimited {
                    Text("Unlimited")
                        .font(.caption.bold())
                        .foregroundColor(.error)
                } else {
                    Text("Limited")
                        .font(.caption)
                        .foregroundColor(.warning)
                }
            }

            Spacer()

            Button {
                Task { await onRevoke() }
            } label: {
                if isRevoking {
                    ProgressView()
                        .tint(.error)
                } else {
                    Text("Revoke")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.error)
                        .cornerRadius(8)
                }
            }
            .disabled(isRevoking)
        }
        .padding(.vertical, 4)
    }

    private func shortAddress(_ addr: String) -> String {
        guard addr.count > 10 else { return addr }
        return "\(addr.prefix(6))...\(addr.suffix(4))"
    }
}

// MARK: - Data hex helper

private extension Data {
    init(hexString: String) {
        let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        var chars = Array(hex)
        if chars.count % 2 != 0 { chars.insert("0", at: 0) }
        var bytes = Data()
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            if let byte = UInt8(String(chars[i...i+1]), radix: 16) {
                bytes.append(byte)
            }
        }
        self = bytes
    }
}
