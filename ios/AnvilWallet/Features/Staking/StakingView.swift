import SwiftUI

/// StakingView shows available staking options and lets users stake ETH or SOL.
///
/// Displays current APY rates fetched from on-chain sources (Lido API for ETH,
/// Solana RPC for SOL) and provides an amount input + confirmation flow.
struct StakingView: View {
    @EnvironmentObject var walletService: WalletService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var stakingService = StakingService.shared

    @State private var selectedOption: StakingService.StakingOption?
    @State private var amount = ""
    @State private var showConfirmation = false
    @State private var isStaking = false
    @State private var stakeResult: String?
    @State private var stakeError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.accentGreen)

                        Text("Earn Yield")
                            .font(.title2.bold())
                            .foregroundColor(.textPrimary)

                        Text("Stake your tokens to earn passive rewards")
                            .font(.subheadline)
                            .foregroundColor(.textSecondary)
                    }
                    .padding(.top, 16)

                    if stakingService.isLoading {
                        ProgressView("Loading rates...")
                            .padding(.vertical, 40)
                    } else if stakingService.availableOptions.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title)
                                .foregroundColor(.textTertiary)
                            Text("Could not load staking rates")
                                .font(.subheadline)
                                .foregroundColor(.textSecondary)
                            Button("Retry") {
                                Task { await stakingService.fetchAPYs() }
                            }
                            .font(.subheadline.bold())
                            .foregroundColor(.accentGreen)
                        }
                        .padding(.vertical, 40)
                    } else {
                        // Staking options
                        ForEach(stakingService.availableOptions) { option in
                            StakingOptionCard(
                                option: option,
                                balance: balanceFor(option: option),
                                isSelected: selectedOption?.id == option.id,
                                onTap: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        selectedOption = option
                                    }
                                }
                            )
                        }
                        .padding(.horizontal, 20)

                        // Amount input (shown when option is selected)
                        if let option = selectedOption {
                            stakeAmountSection(option: option)
                        }
                    }
                }
                .padding(.bottom, 32)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Staking")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
            }
            .task {
                await stakingService.fetchAPYs()
            }
            .alert("Confirm Staking", isPresented: $showConfirmation) {
                Button("Stake", role: .none) {
                    Task { await executeStake() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let option = selectedOption {
                    Text("Stake \(amount) \(option.tokenSymbol) via \(option.protocol_)\nEstimated APY: \(String(format: "%.2f", option.apy))%\nYou will receive \(option.stakedTokenSymbol)")
                }
            }
            .alert("Staking Submitted", isPresented: .init(
                get: { stakeResult != nil },
                set: { if !$0 { stakeResult = nil; dismiss() } }
            )) {
                Button("OK") { dismiss() }
            } message: {
                if let txHash = stakeResult {
                    Text("Transaction: \(txHash.prefix(10))...\(txHash.suffix(6))")
                }
            }
            .alert("Staking Failed", isPresented: .init(
                get: { stakeError != nil },
                set: { if !$0 { stakeError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(stakeError ?? "Unknown error")
            }
            .loadingOverlay(isLoading: isStaking, message: "Staking...")
        }
    }

    // MARK: - Execute Staking

    private func executeStake() async {
        guard let option = selectedOption,
              let amountDouble = Double(amount), amountDouble > 0 else { return }

        isStaking = true

        do {
            if option.id == "lido-eth" {
                let txHash = try await stakeLidoETH(amount: amountDouble)
                await MainActor.run {
                    isStaking = false
                    stakeResult = txHash
                }
            } else {
                // SOL native staking requires stake account creation + delegation
                // which needs a dedicated Rust FFI function (not yet implemented).
                await MainActor.run {
                    isStaking = false
                    stakeError = "Solana native staking requires a future update. Use a Solana staking dApp via the browser for now."
                }
            }
        } catch {
            await MainActor.run {
                isStaking = false
                stakeError = error.localizedDescription
            }
        }
    }

    /// Stakes ETH via Lido by calling submit(address) on the stETH contract.
    /// Uses the same biometric + seed decryption flow as normal sends.
    private func stakeLidoETH(amount: Double) async throws -> String {
        guard let fromAddress = walletService.addresses["ethereum"] else {
            throw StakeError.noWalletAddress
        }

        let chain = ChainModel.allChains.first { $0.evmChainId == 1 }!
        let weiHex = "0x" + String(UInt64(amount * 1e18), radix: 16)

        // submit(address _referral) — referral = zero address
        let calldataHex = StakingService.lidoSubmitSelector
            + "000000000000000000000000"
            + "0000000000000000000000000000000000000000"
        let calldataBytes = Data(hexString: calldataHex) ?? Data()

        let nonce = try await RPCService.shared.getTransactionCount(
            address: fromAddress,
            rpcUrl: chain.activeRpcUrl
        )

        let gasLimit = try await RPCService.shared.estimateGas(
            from: fromAddress,
            to: StakingService.lidoContractAddress,
            value: weiHex,
            data: "0x" + calldataHex,
            rpcUrl: chain.activeRpcUrl
        )

        let feeData = try await RPCService.shared.feeHistory(rpcUrl: chain.activeRpcUrl)
        let baseFee = UInt64(feeData.baseFeeHex.dropFirst(2), radix: 16) ?? 0
        let priorityFee = UInt64(feeData.priorityFeeHex.dropFirst(2), radix: 16) ?? 1_500_000_000
        let maxFee = baseFee * 2 + priorityFee
        let maxFeeHex = "0x" + String(maxFee, radix: 16)

        // Sign via WalletService (handles biometric auth + seed decryption)
        let ethReq = EthTransactionRequest(
            chainId: 1,
            nonce: nonce,
            to: StakingService.lidoContractAddress,
            valueWeiHex: weiHex,
            data: calldataBytes,
            maxPriorityFeeHex: feeData.priorityFeeHex,
            maxFeeHex: maxFeeHex,
            gasLimit: UInt64(Double(gasLimit) * 1.2)
        )
        let signedTx = try await walletService.signTransaction(request: .eth(ethReq))
        let signedHex = "0x" + signedTx.map { String(format: "%02x", $0) }.joined()

        return try await RPCService.shared.sendRawTransaction(
            rpcUrl: chain.activeRpcUrl,
            signedTx: signedHex
        )
    }

    private enum StakeError: LocalizedError {
        case noWalletAddress

        var errorDescription: String? {
            switch self {
            case .noWalletAddress: return "No Ethereum address available"
            }
        }
    }

    // MARK: - Amount Section

    private func stakeAmountSection(option: StakingService.StakingOption) -> some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Amount to Stake")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.textSecondary)

                HStack {
                    TextField("0.0", text: $amount)
                        .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundColor(.textPrimary)
                        .keyboardType(.decimalPad)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(option.tokenSymbol)
                            .font(.subheadline.bold())
                            .foregroundColor(.textPrimary)

                        let balance = balanceFor(option: option)
                        Button {
                            amount = String(format: "%.6f", balance)
                        } label: {
                            Text("Max: \(String(format: "%.4f", balance))")
                                .font(.caption)
                                .foregroundColor(.accentGreen)
                        }
                    }
                }
                .padding(14)
                .background(Color.backgroundCard)
                .cornerRadius(12)
            }
            .padding(.horizontal, 20)

            // Estimated yield info
            if let amountDouble = Double(amount), amountDouble > 0 {
                VStack(spacing: 8) {
                    HStack {
                        Text("Estimated yearly yield")
                            .font(.caption)
                            .foregroundColor(.textSecondary)
                        Spacer()
                        Text("\(String(format: "%.4f", amountDouble * option.apy / 100)) \(option.tokenSymbol)")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundColor(.accentGreen)
                    }
                    HStack {
                        Text("You will receive")
                            .font(.caption)
                            .foregroundColor(.textSecondary)
                        Spacer()
                        Text("\(String(format: "%.4f", amountDouble)) \(option.stakedTokenSymbol)")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundColor(.textPrimary)
                    }
                }
                .padding(14)
                .background(Color.backgroundCard)
                .cornerRadius(12)
                .padding(.horizontal, 20)
            }

            Button {
                showConfirmation = true
            } label: {
                Text("Stake \(option.tokenSymbol)")
            }
            .buttonStyle(.primary)
            .disabled(amount.isEmpty || (Double(amount) ?? 0) < option.minAmount)
            .padding(.horizontal, 20)

            Text(option.description)
                .font(.caption)
                .foregroundColor(.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Helpers

    private func balanceFor(option: StakingService.StakingOption) -> Double {
        walletService.tokens.first(where: {
            $0.symbol == option.tokenSymbol && $0.chain == option.chain
        })?.balance ?? 0
    }
}

// MARK: - Staking Option Card

private struct StakingOptionCard: View {
    let option: StakingService.StakingOption
    let balance: Double
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // Chain icon
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(chainColor.opacity(0.15))
                        .frame(width: 48, height: 48)

                    Text(option.tokenSymbol)
                        .font(.subheadline.bold())
                        .foregroundColor(chainColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(option.protocol_) \(option.tokenSymbol) Staking")
                        .font(.body.bold())
                        .foregroundColor(.textPrimary)

                    Text("Balance: \(String(format: "%.4f", balance)) \(option.tokenSymbol)")
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(String(format: "%.2f", option.apy))%")
                        .font(.title3.bold().monospacedDigit())
                        .foregroundColor(.accentGreen)

                    Text("APY")
                        .font(.caption2.bold())
                        .foregroundColor(.textTertiary)
                }
            }
            .padding(16)
            .background(Color.backgroundCard)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.accentGreen : Color.clear, lineWidth: 2)
            )
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }

    private var chainColor: Color {
        switch option.chain {
        case "ethereum": return .chainEthereum
        case "solana": return .chainSolana
        default: return .textTertiary
        }
    }
}

#Preview {
    StakingView()
        .environmentObject(WalletService.shared)
}
