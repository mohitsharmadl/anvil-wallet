import SwiftUI
import CryptoKit

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
    @State private var solAction: SolStakeAction = .stake
    @State private var solStakeAccountAddress = ""

    enum SolStakeAction: String, CaseIterable, Identifiable {
        case stake = "Stake"
        case unstake = "Unstake"
        var id: String { rawValue }
    }

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
            .alert("Confirm Action", isPresented: $showConfirmation) {
                Button(confirmButtonTitle, role: .none) {
                    Task { await executeStake() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let option = selectedOption {
                    if option.id == "native-sol", solAction == .unstake {
                        Text("Deactivate stake account \(shortAddress(solStakeAccountAddress)). Funds become withdrawable after Solana warm-down period.")
                    } else {
                        Text("Stake \(amount) \(option.tokenSymbol) via \(option.protocol_)\nEstimated APY: \(String(format: "%.2f", option.apy))%\nYou will receive \(option.stakedTokenSymbol)")
                    }
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
        guard let option = selectedOption else { return }
        let amountDouble = Double(amount) ?? 0

        isStaking = true

        do {
            if option.id == "lido-eth" {
                guard amountDouble > 0 else { throw StakeError.invalidAmount }
                let txHash = try await stakeLidoETH(amount: amountDouble)
                await MainActor.run {
                    isStaking = false
                    stakeResult = txHash
                    Haptic.success()
                }
            } else {
                let txHash: String
                if solAction == .stake {
                    guard amountDouble > 0 else { throw StakeError.invalidAmount }
                    txHash = try await stakeNativeSol(amount: amountDouble)
                } else {
                    guard !solStakeAccountAddress.isEmpty else {
                        throw StakeError.invalidStakeAccount
                    }
                    txHash = try await deactivateNativeSolStake(stakeAccount: solStakeAccountAddress)
                }
                await MainActor.run {
                    isStaking = false
                    stakeResult = txHash
                    Haptic.success()
                }
            }
        } catch {
            await MainActor.run {
                isStaking = false
                stakeError = error.localizedDescription
                Haptic.error()
            }
        }
    }

    private func stakeNativeSol(amount: Double) async throws -> String {
        guard let walletAddress = walletService.addresses["solana"] else {
            throw StakeError.noWalletAddress
        }
        guard let walletPubkey = Base58.decode(walletAddress), walletPubkey.count == 32 else {
            throw StakeError.invalidAddress
        }
        let chain = ChainModel.solana
        let rpc = RPCService.shared

        let recentBlockhash = try await rpc.getRecentBlockhash(rpcUrl: chain.activeRpcUrl)
        let validatorVote = try await rpc.getTopSolanaValidatorVoteAccount(rpcUrl: chain.activeRpcUrl)
        guard !validatorVote.isEmpty else { throw StakeError.malformedRPCResponse }
        let rentExemptLamports = try await rpc.getSolanaRentExemption(rpcUrl: chain.activeRpcUrl, dataSize: 200)
        let amountLamports = UInt64(amount * 1_000_000_000.0)
        guard amountLamports > 0 else { throw StakeError.invalidAmount }

        // Stake account created with seed so only wallet signature is required.
        let seed = "anvil\(Int(Date().timeIntervalSince1970) % 1_000_000_000)"
        let rawUnsigned = try SolanaStakingBuilder.buildCreateAndDelegateStakeTx(
            walletPubkey: [UInt8](walletPubkey),
            voteAccountBase58: validatorVote,
            seed: seed,
            lamportsToDelegate: amountLamports,
            rentExemptLamports: rentExemptLamports,
            recentBlockhash: [UInt8](recentBlockhash)
        )

        let signedTx = try await walletService.signSolanaRawTransaction(rawUnsigned)
        let signature = try await rpc.sendSolanaTransaction(
            rpcUrl: chain.activeRpcUrl,
            signedTx: signedTx.base64EncodedString()
        )
        return signature
    }

    private func deactivateNativeSolStake(stakeAccount: String) async throws -> String {
        guard let walletAddress = walletService.addresses["solana"] else {
            throw StakeError.noWalletAddress
        }
        guard let walletPubkey = Base58.decode(walletAddress), walletPubkey.count == 32 else {
            throw StakeError.invalidAddress
        }
        let chain = ChainModel.solana
        let recentBlockhash = try await RPCService.shared.getRecentBlockhash(rpcUrl: chain.activeRpcUrl)

        let rawUnsigned = try SolanaStakingBuilder.buildDeactivateStakeTx(
            walletPubkey: [UInt8](walletPubkey),
            stakeAccountBase58: stakeAccount,
            recentBlockhash: [UInt8](recentBlockhash)
        )

        let signedTx = try await walletService.signSolanaRawTransaction(rawUnsigned)
        return try await RPCService.shared.sendSolanaTransaction(
            rpcUrl: chain.activeRpcUrl,
            signedTx: signedTx.base64EncodedString()
        )
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

        let nonceHex = try await RPCService.shared.getTransactionCount(
            rpcUrl: chain.activeRpcUrl,
            address: fromAddress
        )
        guard let nonce = UInt64(nonceHex.dropFirst(2), radix: 16) else {
            throw StakeError.malformedRPCResponse
        }

        let gasHex = try await RPCService.shared.estimateGas(
            rpcUrl: chain.activeRpcUrl,
            from: fromAddress,
            to: StakingService.lidoContractAddress,
            value: weiHex,
            data: "0x" + calldataHex
        )
        guard let gasLimit = UInt64(gasHex.dropFirst(2), radix: 16) else {
            throw StakeError.malformedRPCResponse
        }

        let feeData = try await RPCService.shared.feeHistory(rpcUrl: chain.activeRpcUrl)
        guard let baseFee = UInt64(feeData.baseFeeHex.dropFirst(2), radix: 16) else {
            throw StakeError.malformedRPCResponse
        }
        guard let priorityFee = UInt64(feeData.priorityFeeHex.dropFirst(2), radix: 16) else {
            throw StakeError.malformedRPCResponse
        }
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
        case invalidAddress
        case invalidAmount
        case invalidStakeAccount
        case malformedRPCResponse

        var errorDescription: String? {
            switch self {
            case .noWalletAddress: return "No wallet address available for this chain"
            case .invalidAddress: return "Invalid Solana address format"
            case .invalidAmount: return "Enter a valid staking amount"
            case .invalidStakeAccount: return "Enter a valid stake account address"
            case .malformedRPCResponse: return "Received malformed data from RPC node"
            }
        }
    }

    // MARK: - Amount Section

    private func stakeAmountSection(option: StakingService.StakingOption) -> some View {
        VStack(spacing: 16) {
            if option.id == "native-sol" {
                HStack(spacing: 8) {
                    ForEach(SolStakeAction.allCases) { action in
                        Button {
                            solAction = action
                        } label: {
                            Text(action.rawValue)
                                .font(.caption.bold())
                                .foregroundColor(solAction == action ? .white : .textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(solAction == action ? Color.accentGreen : Color.backgroundCard)
                                .cornerRadius(10)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(solAction == .unstake && option.id == "native-sol" ? "Stake Account" : "Amount to Stake")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.textSecondary)

                if option.id == "native-sol", solAction == .unstake {
                    TextField("Stake account address", text: $solStakeAccountAddress)
                        .font(.subheadline.monospaced())
                        .foregroundColor(.textPrimary)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .padding(14)
                        .background(Color.backgroundCard)
                        .cornerRadius(12)
                } else {
                    HStack {
                        TextField("0.0", text: $amount)
                            .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundColor(.textPrimary)
                            .keyboardType(.decimalPad)
                            .minimumScaleFactor(0.5)

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
            }
            .padding(.horizontal, 20)

            // Estimated yield info
            if let amountDouble = Double(amount), amountDouble > 0, !(option.id == "native-sol" && solAction == .unstake) {
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
                Haptic.impact(.medium)
                showConfirmation = true
            } label: {
                Text(option.id == "native-sol" && solAction == .unstake ? "Deactivate Stake" : "Stake \(option.tokenSymbol)")
            }
            .buttonStyle(.primary)
            .disabled(isStakeActionDisabled(option: option))
            .padding(.horizontal, 20)
            .accessibilityLabel(option.id == "native-sol" && solAction == .unstake ? "Deactivate stake account" : "Stake \(option.tokenSymbol)")
            .accessibilityHint("Double tap to confirm")

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

    private func isStakeActionDisabled(option: StakingService.StakingOption) -> Bool {
        if option.id == "native-sol", solAction == .unstake {
            return solStakeAccountAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return amount.isEmpty || (Double(amount) ?? 0) < option.minAmount
    }

    private var confirmButtonTitle: String {
        guard let option = selectedOption else { return "Confirm" }
        if option.id == "native-sol", solAction == .unstake {
            return "Deactivate"
        }
        return "Stake"
    }

    private func shortAddress(_ addr: String) -> String {
        let trimmed = addr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 14 else { return trimmed }
        return "\(trimmed.prefix(8))...\(trimmed.suffix(6))"
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(option.protocol_) \(option.tokenSymbol) staking, \(String(format: "%.2f", option.apy)) percent APY, balance: \(String(format: "%.4f", balance)) \(option.tokenSymbol)")
        .accessibilityHint("Double tap to select this staking option")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var chainColor: Color {
        switch option.chain {
        case "ethereum": return .chainEthereum
        case "solana": return .chainSolana
        default: return .textTertiary
        }
    }
}

// MARK: - Solana Native Staking Builder

private enum SolanaStakingBuilder {
    private static let stakeAccountSpace: UInt64 = 200
    private static let systemProgram = [UInt8](repeating: 0, count: 32)

    private static var stakeProgram: [UInt8] {
        Array(Base58.decode("Stake11111111111111111111111111111111111111") ?? Data())
    }
    private static var rentSysvar: [UInt8] {
        Array(Base58.decode("SysvarRent111111111111111111111111111111111") ?? Data())
    }
    private static var clockSysvar: [UInt8] {
        Array(Base58.decode("SysvarC1ock11111111111111111111111111111111") ?? Data())
    }
    private static var stakeHistorySysvar: [UInt8] {
        Array(Base58.decode("SysvarStakeHistory1111111111111111111111111") ?? Data())
    }
    private static var stakeConfig: [UInt8] {
        Array(Base58.decode("StakeConfig11111111111111111111111111111111") ?? Data())
    }

    private struct AccountMeta {
        let key: [UInt8]
        let isSigner: Bool
        let isWritable: Bool
    }

    private struct Instruction {
        let programId: [UInt8]
        let accounts: [AccountMeta]
        let data: [UInt8]
    }

    static func buildCreateAndDelegateStakeTx(
        walletPubkey: [UInt8],
        voteAccountBase58: String,
        seed: String,
        lamportsToDelegate: UInt64,
        rentExemptLamports: UInt64,
        recentBlockhash: [UInt8]
    ) throws -> Data {
        guard walletPubkey.count == 32,
              recentBlockhash.count == 32,
              stakeProgram.count == 32,
              rentSysvar.count == 32,
              clockSysvar.count == 32,
              stakeHistorySysvar.count == 32,
              stakeConfig.count == 32,
              let vote = Base58.decode(voteAccountBase58).map(Array.init),
              vote.count == 32 else {
            throw BuildError.invalidInput
        }

        let stakeAccount = deriveCreateWithSeedAddress(
            base: walletPubkey,
            seed: seed,
            owner: stakeProgram
        )

        let createIx = Instruction(
            programId: systemProgram,
            accounts: [
                AccountMeta(key: walletPubkey, isSigner: true, isWritable: true),   // from
                AccountMeta(key: stakeAccount, isSigner: false, isWritable: true), // new account
                AccountMeta(key: walletPubkey, isSigner: true, isWritable: false), // base
            ],
            data: encodeCreateAccountWithSeed(
                base: walletPubkey,
                seed: seed,
                lamports: lamportsToDelegate + rentExemptLamports,
                space: stakeAccountSpace,
                owner: stakeProgram
            )
        )

        let initializeIx = Instruction(
            programId: stakeProgram,
            accounts: [
                AccountMeta(key: stakeAccount, isSigner: false, isWritable: true),
                AccountMeta(key: rentSysvar, isSigner: false, isWritable: false),
            ],
            data: encodeInitializeStake(staker: walletPubkey, withdrawer: walletPubkey)
        )

        let delegateIx = Instruction(
            programId: stakeProgram,
            accounts: [
                AccountMeta(key: stakeAccount, isSigner: false, isWritable: true),
                AccountMeta(key: vote, isSigner: false, isWritable: false),
                AccountMeta(key: clockSysvar, isSigner: false, isWritable: false),
                AccountMeta(key: stakeHistorySysvar, isSigner: false, isWritable: false),
                AccountMeta(key: stakeConfig, isSigner: false, isWritable: false),
                AccountMeta(key: walletPubkey, isSigner: true, isWritable: false),
            ],
            data: encodeDelegateStake()
        )

        return try buildUnsignedTx(
            instructions: [createIx, initializeIx, delegateIx],
            feePayer: walletPubkey,
            recentBlockhash: recentBlockhash
        )
    }

    static func buildDeactivateStakeTx(
        walletPubkey: [UInt8],
        stakeAccountBase58: String,
        recentBlockhash: [UInt8]
    ) throws -> Data {
        guard walletPubkey.count == 32,
              recentBlockhash.count == 32,
              stakeProgram.count == 32,
              clockSysvar.count == 32,
              let stakeAccount = Base58.decode(stakeAccountBase58).map(Array.init),
              stakeAccount.count == 32 else {
            throw BuildError.invalidInput
        }

        let deactivateIx = Instruction(
            programId: stakeProgram,
            accounts: [
                AccountMeta(key: stakeAccount, isSigner: false, isWritable: true),
                AccountMeta(key: clockSysvar, isSigner: false, isWritable: false),
                AccountMeta(key: walletPubkey, isSigner: true, isWritable: false),
            ],
            data: encodeDeactivateStake()
        )

        return try buildUnsignedTx(
            instructions: [deactivateIx],
            feePayer: walletPubkey,
            recentBlockhash: recentBlockhash
        )
    }

    private static func buildUnsignedTx(
        instructions: [Instruction],
        feePayer: [UInt8],
        recentBlockhash: [UInt8]
    ) throws -> Data {
        var keys: [[UInt8]] = []
        func upsert(_ key: [UInt8]) {
            if !keys.contains(where: { $0 == key }) {
                keys.append(key)
            }
        }
        upsert(feePayer)
        for ix in instructions {
            for a in ix.accounts { upsert(a.key) }
            upsert(ix.programId)
        }

        let signersWritable = keys.filter { key in
            key == feePayer
        }
        let nonSignerWritable = keys.filter { key in
            key != feePayer && instructions.flatMap(\.accounts).contains(where: { $0.key == key && $0.isWritable })
        }
        let readonly = keys.filter { key in
            key != feePayer && !nonSignerWritable.contains(where: { $0 == key })
        }

        let ordered = signersWritable + nonSignerWritable + readonly
        let numRequiredSignatures: UInt8 = 1
        let numReadonlySigned: UInt8 = 0
        let numReadonlyUnsigned: UInt8 = UInt8(readonly.count)

        var message: [UInt8] = []
        message.append(numRequiredSignatures)
        message.append(numReadonlySigned)
        message.append(numReadonlyUnsigned)
        message.append(contentsOf: encodeCompactU16(ordered.count))
        ordered.forEach { message.append(contentsOf: $0) }
        message.append(contentsOf: recentBlockhash)

        message.append(contentsOf: encodeCompactU16(instructions.count))
        for ix in instructions {
            guard let programIdx = ordered.firstIndex(where: { $0 == ix.programId }) else {
                throw BuildError.invalidInput
            }
            message.append(UInt8(programIdx))

            let accountIndices = ix.accounts.compactMap { meta in
                ordered.firstIndex(where: { $0 == meta.key }).map(UInt8.init)
            }
            message.append(contentsOf: encodeCompactU16(accountIndices.count))
            message.append(contentsOf: accountIndices)

            message.append(contentsOf: encodeCompactU16(ix.data.count))
            message.append(contentsOf: ix.data)
        }

        var tx: [UInt8] = []
        tx.append(contentsOf: encodeCompactU16(1)) // one signer
        tx.append(contentsOf: [UInt8](repeating: 0, count: 64)) // placeholder signature
        tx.append(contentsOf: message)
        return Data(tx)
    }

    private static func encodeCreateAccountWithSeed(
        base: [UInt8], seed: String, lamports: UInt64, space: UInt64, owner: [UInt8]
    ) -> [UInt8] {
        var out: [UInt8] = []
        out.append(contentsOf: UInt32(3).littleEndianBytes)
        out.append(contentsOf: base)
        let seedBytes = [UInt8](seed.utf8)
        out.append(contentsOf: UInt64(seedBytes.count).littleEndianBytes)
        out.append(contentsOf: seedBytes)
        out.append(contentsOf: lamports.littleEndianBytes)
        out.append(contentsOf: space.littleEndianBytes)
        out.append(contentsOf: owner)
        return out
    }

    private static func encodeInitializeStake(staker: [UInt8], withdrawer: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.append(contentsOf: UInt32(0).littleEndianBytes) // Initialize
        out.append(contentsOf: staker) // Authorized.staker
        out.append(contentsOf: withdrawer) // Authorized.withdrawer
        out.append(contentsOf: Int64(0).littleEndianBytes) // Lockup.unix_timestamp
        out.append(contentsOf: UInt64(0).littleEndianBytes) // Lockup.epoch
        out.append(contentsOf: [UInt8](repeating: 0, count: 32)) // Lockup.custodian
        return out
    }

    private static func encodeDelegateStake() -> [UInt8] {
        UInt32(2).littleEndianBytes // DelegateStake
    }

    private static func encodeDeactivateStake() -> [UInt8] {
        UInt32(5).littleEndianBytes // Deactivate
    }

    private static func deriveCreateWithSeedAddress(base: [UInt8], seed: String, owner: [UInt8]) -> [UInt8] {
        var data = Data()
        data.append(contentsOf: base)
        data.append(contentsOf: seed.utf8)
        data.append(contentsOf: owner)
        let digest = SHA256.hash(data: data)
        return Array(digest)
    }

    private static func encodeCompactU16(_ value: Int) -> [UInt8] {
        var val = UInt32(value)
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(val & 0x7f)
            val >>= 7
            if val > 0 { byte |= 0x80 }
            out.append(byte)
        } while val > 0
        return out
    }

    enum BuildError: Error {
        case invalidInput
    }
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.littleEndian, Array.init)
    }
}

private extension UInt64 {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.littleEndian, Array.init)
    }
}

private extension Int64 {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.littleEndian, Array.init)
    }
}

#Preview {
    StakingView()
        .environmentObject(WalletService.shared)
}
