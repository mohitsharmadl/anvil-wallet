import SwiftUI

/// ConfirmTransactionView shows transaction details for user confirmation before signing.
///
/// Displays:
///   - Sender and recipient addresses
///   - Amount and token
///   - Estimated gas fee
///   - Total cost
///
/// On confirmation, triggers biometric auth -> signing -> broadcast.
struct ConfirmTransactionView: View {
    @EnvironmentObject var walletService: WalletService
    @EnvironmentObject var router: AppRouter

    let transaction: TransactionModel

    @State private var estimatedFee: String = "0"
    @State private var estimatedFeeUsd: Double = 0
    @State private var isSimulating = true
    @State private var simulationError: String?
    @State private var isSigning = false

    // Password re-entry (after app returns from background)
    @State private var showPasswordPrompt = false
    @State private var reenteredPassword = ""
    @State private var passwordError: String?
    @State private var isVerifyingPassword = false
    // Pending sign request to retry after password re-entry
    @State private var pendingSignRetry = false

    // Fetched gas params for EVM signing
    @State private var fetchedNonce: UInt64 = 0
    @State private var fetchedGasLimit: UInt64 = 21000
    @State private var fetchedMaxFeeHex: String = "0x0"
    @State private var fetchedMaxPriorityFeeHex: String = "0x0"

    // Fetched params for BTC signing
    @State private var fetchedBtcFeeRate: UInt64 = 0
    @State private var fetchedBtcUtxos: [UtxoData] = []
    @State private var fetchedBtcAmountSat: UInt64 = 0
    @State private var fetchedBtcFeeRates: RPCService.BitcoinFeeRates?
    @State private var selectedBtcFeeSpeed: BtcFeeSpeed = .medium
    @State private var btcFeeSat: UInt64 = 0

    enum BtcFeeSpeed: String, CaseIterable, Identifiable {
        case fast, medium, slow
        var id: String { rawValue }

        var label: String {
            switch self {
            case .fast: return RPCService.BitcoinFeeRates.fastLabel
            case .medium: return RPCService.BitcoinFeeRates.mediumLabel
            case .slow: return RPCService.BitcoinFeeRates.slowLabel
            }
        }

        func rate(from rates: RPCService.BitcoinFeeRates) -> UInt64 {
            switch self {
            case .fast: return rates.fast
            case .medium: return rates.medium
            case .slow: return rates.slow
            }
        }
    }

    // Risk assessment
    @State private var riskAssessment: RiskAssessment?

    // Balance change preview
    @State private var balanceChanges: [BalanceChangeSimulator.BalanceChange] = []

    /// Whether this transaction is an ERC-20 token transfer (vs native coin transfer).
    private var isERC20: Bool {
        transaction.contractAddress != nil
    }

    /// Converts a human-readable amount string to the smallest unit as a decimal string
    /// using Decimal arithmetic — no UInt64 intermediate, so no overflow at ~18.4 ETH.
    ///
    /// Example: amountToDecimalString("1.5", decimals: 18) → "1500000000000000000"
    private func amountToDecimalString(_ amountStr: String, decimals: Int) -> String {
        guard let decimalAmount = Decimal(string: amountStr) else { return "0" }
        var multiplier = Decimal(1)
        for _ in 0..<decimals { multiplier *= 10 }
        let result = decimalAmount * multiplier
        // Round to integer (truncate fractional dust from Decimal math)
        let rounded = NSDecimalNumber(decimal: result).rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .down,
                scale: 0,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            )
        )
        return rounded.stringValue
    }

    /// Converts a human-readable amount string to a 0x-prefixed hex string of the smallest unit.
    /// Uses string-based conversion — safe for any amount (no UInt64 overflow).
    private func amountToHex(_ amountStr: String, decimals: Int) -> String {
        let decStr = amountToDecimalString(amountStr, decimals: decimals)
        return "0x" + decimalStringToHex(decStr)
    }

    /// Converts a human-readable amount string to UInt64 smallest units.
    /// Only safe for chains where total supply fits in UInt64 (e.g. SOL with 9 decimals).
    private func amountToSmallestUnit(_ amountStr: String, decimals: Int) -> UInt64 {
        guard let decimalAmount = Decimal(string: amountStr) else { return 0 }
        var multiplier = Decimal(1)
        for _ in 0..<decimals { multiplier *= 10 }
        let result = decimalAmount * multiplier
        return NSDecimalNumber(decimal: result).uint64Value
    }

    /// Converts a decimal integer string (e.g. "100000000000000000000") to hex (e.g. "56bc75e2d63100000").
    /// Handles arbitrarily large values via long division by 16.
    private func decimalStringToHex(_ decStr: String) -> String {
        var digits = decStr.compactMap { $0.wholeNumberValue }
        guard !digits.isEmpty else { return "0" }

        var hex = ""
        while !(digits.count == 1 && digits[0] == 0) {
            var remainder = 0
            var newDigits: [Int] = []
            for digit in digits {
                let current = remainder * 10 + digit
                let quotient = current / 16
                remainder = current % 16
                if !newDigits.isEmpty || quotient > 0 {
                    newDigits.append(quotient)
                }
            }
            hex = String(remainder, radix: 16) + hex
            digits = newDigits.isEmpty ? [0] : newDigits
        }
        return hex.isEmpty ? "0" : hex
    }

    // MARK: - ERC-20 Calldata

    /// Builds ERC-20 `transfer(address,uint256)` calldata.
    ///
    /// Layout: 0xa9059cbb (4-byte selector) + address (32 bytes, left-padded) + amount (32 bytes, left-padded)
    /// Total: 68 bytes. Returns nil if hex encoding fails.
    private func encodeERC20Transfer(to recipient: String, amountHex: String) -> Data? {
        // Function selector: keccak256("transfer(address,uint256)")[0:4] = 0xa9059cbb
        let selector = Data([0xa9, 0x05, 0x9c, 0xbb])

        // ABI-encode address: strip 0x, lowercase, left-pad to 64 hex chars (32 bytes)
        let cleanAddress = recipient.hasPrefix("0x") ? String(recipient.dropFirst(2)) : recipient
        let paddedAddress = String(repeating: "0", count: max(0, 64 - cleanAddress.count)) + cleanAddress.lowercased()

        // ABI-encode uint256: strip 0x from hex amount, left-pad to 64 hex chars
        let cleanAmount = amountHex.hasPrefix("0x") ? String(amountHex.dropFirst(2)) : amountHex
        let paddedAmount = String(repeating: "0", count: max(0, 64 - cleanAmount.count)) + cleanAmount

        // Convert hex strings to Data — strict parsing rejects invalid hex
        guard let addressData = Data(strictHexString: paddedAddress),
              let amountData = Data(strictHexString: paddedAmount) else {
            return nil
        }

        return selector + addressData + amountData
    }

    /// Finds the ChainModel for the transaction's chain string
    private var chainModel: ChainModel? {
        ChainModel.allChains.first { $0.id == transaction.chain }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "paperplane.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.accentGreen)

                        Text("Confirm Transaction")
                            .font(.title3.bold())
                            .foregroundColor(.textPrimary)
                    }
                    .padding(.top, 16)

                    // Risk assessment banner
                    if let risk = riskAssessment {
                        RiskBannerView(assessment: risk)
                    }

                    // Transaction details
                    VStack(spacing: 16) {
                        DetailRow(label: "From", value: transaction.shortFrom)
                        Divider().background(Color.separator)

                        DetailRow(label: "To", value: transaction.shortTo)
                        Divider().background(Color.separator)

                        DetailRow(
                            label: "Amount",
                            value: transaction.formattedAmount,
                            valueColor: .textPrimary
                        )
                        Divider().background(Color.separator)

                        DetailRow(label: "Network", value: transaction.chain.capitalized)
                        Divider().background(Color.separator)

                        if isSimulating {
                            HStack {
                                Text("Estimated Fee")
                                    .foregroundColor(.textSecondary)
                                Spacer()
                                ProgressView()
                                    .tint(.textSecondary)
                            }
                        } else if let error = simulationError {
                            DetailRow(label: "Fee Error", value: error, valueColor: .error)
                        } else if chainModel?.chainType == .bitcoin {
                            // BTC: show fee in sats and BTC
                            VStack(spacing: 4) {
                                HStack {
                                    Text("Fee")
                                        .foregroundColor(.textSecondary)
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("\(estimatedFee) BTC")
                                            .foregroundColor(.textPrimary)
                                            .monospacedDigit()
                                        Text("\(btcFeeSat) sats (\(fetchedBtcFeeRate) sat/vB)")
                                            .font(.caption)
                                            .foregroundColor(.textTertiary)
                                            .monospacedDigit()
                                    }
                                }
                            }
                        } else {
                            DetailRow(
                                label: "Estimated Fee",
                                value: "\(estimatedFee) (~$\(String(format: "%.2f", estimatedFeeUsd)))"
                            )
                        }
                    }
                    .font(.body)
                    .padding()
                    .background(Color.backgroundCard)
                    .cornerRadius(16)
                    .padding(.horizontal, 20)

                    // BTC fee speed picker
                    if chainModel?.chainType == .bitcoin && !isSimulating && simulationError == nil,
                       let rates = fetchedBtcFeeRates {
                        BtcFeeSpeedPicker(
                            selectedSpeed: $selectedBtcFeeSpeed,
                            feeRates: rates
                        )
                        .padding(.horizontal, 20)
                        .onChange(of: selectedBtcFeeSpeed) {
                            // Recalculate fee when speed changes
                            Task { await recalculateBtcFee() }
                        }
                    }

                    // Total
                    if !isSimulating && simulationError == nil {
                        HStack {
                            Text("Total")
                                .font(.headline)
                                .foregroundColor(.textSecondary)

                            Spacer()

                            VStack(alignment: .trailing) {
                                if chainModel?.chainType == .bitcoin {
                                    // BTC: amount + fee are both in BTC
                                    let total = (Decimal(string: transaction.amount) ?? 0) + (Decimal(string: estimatedFee) ?? 0)
                                    Text("\(NSDecimalNumber(decimal: total).stringValue) BTC")
                                        .font(.headline.monospacedDigit())
                                        .foregroundColor(.textPrimary)
                                } else {
                                    let total = (Decimal(string: transaction.amount) ?? 0) + (Decimal(string: estimatedFee) ?? 0)
                                    Text("\(NSDecimalNumber(decimal: total).stringValue) \(transaction.tokenSymbol)")
                                        .font(.headline.monospacedDigit())
                                        .foregroundColor(.textPrimary)
                                }
                            }
                        }
                        .padding()
                        .background(Color.backgroundCard)
                        .cornerRadius(16)
                        .padding(.horizontal, 20)
                    }

                    // Balance change preview
                    if !balanceChanges.isEmpty {
                        BalanceChangePreviewView(changes: balanceChanges)
                    }

                    // Security note
                    HStack(spacing: 8) {
                        Image(systemName: "faceid")
                            .foregroundColor(.accentGreen)

                        Text("You'll need to authenticate with biometrics to sign this transaction.")
                            .font(.caption)
                            .foregroundColor(.textSecondary)
                    }
                    .padding(12)
                    .background(Color.backgroundCard)
                    .cornerRadius(12)
                    .padding(.horizontal, 20)
                }
            }

            // Bottom buttons
            VStack(spacing: 12) {
                Button {
                    Task {
                        await signAndSend()
                    }
                } label: {
                    Text("Confirm & Send")
                }
                .buttonStyle(PrimaryButtonStyle(isEnabled: !isSimulating && simulationError == nil && riskAssessment?.overallLevel != .danger))
                .disabled(isSimulating || simulationError != nil || isSigning || riskAssessment?.overallLevel == .danger)

                Button {
                    router.sendPath.removeLast()
                } label: {
                    Text("Cancel")
                        .font(.headline)
                        .foregroundColor(.textSecondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .padding(.top, 12)
            .background(Color.backgroundPrimary)
        }
        .background(Color.backgroundPrimary)
        .navigationTitle("Confirm")
        .navigationBarTitleDisplayMode(.inline)
        .loadingOverlay(isLoading: isSigning, message: "Signing transaction...")
        .task {
            // Run risk assessment
            let token = walletService.tokens.first {
                if let ca = transaction.contractAddress {
                    return $0.contractAddress?.lowercased() == ca.lowercased()
                } else {
                    return $0.chain == transaction.chain && $0.isNativeToken
                }
            }
            riskAssessment = TransactionRiskEngine.shared.assess(
                to: transaction.to,
                amount: transaction.amount,
                tokenSymbol: transaction.tokenSymbol,
                tokenBalance: token?.balance ?? 0,
                tokenDecimals: transaction.tokenDecimals,
                contractAddress: transaction.contractAddress,
                previousTransactions: walletService.transactions
            )

            await simulateTransaction()

            // Compute balance changes after fee estimation
            if simulationError == nil {
                let nativeSymbol = chainModel?.symbol ?? transaction.tokenSymbol
                balanceChanges = BalanceChangeSimulator.simulate(
                    amount: transaction.amount,
                    tokenSymbol: transaction.tokenSymbol,
                    isERC20: isERC20,
                    estimatedFee: estimatedFee,
                    nativeSymbol: nativeSymbol
                )
            }
        }
        .sheet(isPresented: $showPasswordPrompt) {
            PasswordReentrySheet(
                password: $reenteredPassword,
                errorMessage: $passwordError,
                isVerifying: $isVerifyingPassword
            ) {
                await verifyAndRetrySign()
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: - Logic

    private func simulateTransaction() async {
        isSimulating = true

        guard let chain = chainModel else {
            simulationError = "Unknown chain"
            isSimulating = false
            return
        }

        do {
            switch chain.chainType {
            case .evm:
                // Fetch nonce and EIP-1559 fee data
                let nonceHex: String = try await RPCService.shared.getTransactionCount(
                    rpcUrl: chain.activeRpcUrl,
                    address: transaction.from
                )
                fetchedNonce = UInt64(nonceHex.dropFirst(2), radix: 16) ?? 0

                // Use eth_feeHistory for robust EIP-1559 fee estimation
                let feeData = try await RPCService.shared.feeHistory(rpcUrl: chain.activeRpcUrl)
                let baseFee = UInt64(feeData.baseFeeHex.dropFirst(2), radix: 16) ?? 0
                let priorityFee = UInt64(feeData.priorityFeeHex.dropFirst(2), radix: 16) ?? 1_500_000_000

                fetchedMaxPriorityFeeHex = feeData.priorityFeeHex

                // maxFeePerGas = 2 * baseFee + priorityFee (2x multiplier absorbs 1 block of base fee increase)
                // Use checked arithmetic to guard against adversarial/buggy RPC values.
                let (doubled, mulOverflow) = baseFee.multipliedReportingOverflow(by: 2)
                let (maxFee, addOverflow) = doubled.addingReportingOverflow(priorityFee)
                guard !mulOverflow && !addOverflow else {
                    simulationError = "Fee estimate overflow — RPC returned unreasonable values"
                    isSimulating = false
                    return
                }
                fetchedMaxFeeHex = "0x" + String(maxFee, radix: 16)

                // For ERC-20: gas estimation must target the contract with transfer calldata
                // For native: gas estimation targets the recipient with the value
                let estimateTo: String
                let estimateValue: String
                let estimateData: String?

                if let contractAddress = transaction.contractAddress {
                    let tokenAmountHex = amountToHex(transaction.amount, decimals: transaction.tokenDecimals)
                    guard let calldata = encodeERC20Transfer(to: transaction.to, amountHex: tokenAmountHex) else {
                        simulationError = "Failed to encode ERC-20 transfer data"
                        isSimulating = false
                        return
                    }
                    estimateTo = contractAddress
                    estimateValue = "0x0"
                    estimateData = "0x" + calldata.map { String(format: "%02x", $0) }.joined()
                } else {
                    estimateTo = transaction.to
                    estimateValue = amountToHex(transaction.amount, decimals: 18)
                    estimateData = nil
                }

                let gasEstimateHex: String = try await RPCService.shared.estimateGas(
                    rpcUrl: chain.activeRpcUrl,
                    from: transaction.from,
                    to: estimateTo,
                    value: estimateValue,
                    data: estimateData
                )
                fetchedGasLimit = UInt64(gasEstimateHex.dropFirst(2), radix: 16) ?? 21000

                // Fee estimate uses maxFee (worst-case), actual cost may be lower.
                // Double has 53-bit mantissa — sufficient precision for display purposes.
                let feeWei = Double(maxFee) * Double(fetchedGasLimit)
                guard feeWei.isFinite else {
                    simulationError = "Fee estimate overflow"
                    isSimulating = false
                    return
                }
                estimatedFee = String(format: "%.18g", feeWei / 1e18)

            case .solana:
                // Solana fees are fixed (~5000 lamports)
                estimatedFee = "0.000005"

            case .bitcoin:
                // Fetch UTXOs and fee rates for estimation
                let allUtxos = try await RPCService.shared.getBitcoinUtxos(
                    apiUrl: chain.activeRpcUrl,
                    address: transaction.from
                )
                let feeRates = try await RPCService.shared.getBitcoinFeeRates(apiUrl: chain.activeRpcUrl)
                let amountSat = amountToSmallestUnit(transaction.amount, decimals: 8)
                let feeRate = selectedBtcFeeSpeed.rate(from: feeRates)

                // Greedy UTXO selection: sort by value descending, pick until amount + estimated fee is covered
                let sorted = allUtxos.sorted { $0.amountSat > $1.amountSat }
                var selected: [UtxoData] = []
                var totalSelected: UInt64 = 0

                // Initial fee estimate with 1 input to bootstrap selection
                var currentInputCount = 1
                var estimatedVsize = UInt64(currentInputCount * 68 + 2 * 31 + 10)
                var feeSat = feeRate * estimatedVsize

                for utxo in sorted {
                    selected.append(utxo)
                    totalSelected += utxo.amountSat

                    // Recalculate fee with actual input count
                    // P2WPKH vsize: ~110 + 68*inputs + 31*outputs (2 outputs: recipient + change)
                    currentInputCount = selected.count
                    estimatedVsize = UInt64(currentInputCount * 68 + 2 * 31 + 10)
                    feeSat = feeRate * estimatedVsize

                    if totalSelected >= amountSat + feeSat {
                        break
                    }
                }

                // Check if we have enough funds
                guard totalSelected >= amountSat + feeSat else {
                    let totalAvailable = allUtxos.reduce(UInt64(0)) { $0 + $1.amountSat }
                    let availableBtc = String(format: "%.8f", Double(totalAvailable) / 1e8)
                    let neededBtc = String(format: "%.8f", Double(amountSat + feeSat) / 1e8)
                    simulationError = "Insufficient funds. Available: \(availableBtc) BTC, needed: \(neededBtc) BTC (including fee)"
                    isSimulating = false
                    return
                }

                btcFeeSat = feeSat
                estimatedFee = String(format: "%.8g", Double(feeSat) / 1e8)

                // Store for signing
                fetchedBtcFeeRate = feeRate
                fetchedBtcFeeRates = feeRates
                fetchedBtcUtxos = selected
                fetchedBtcAmountSat = amountSat
            }

            isSimulating = false
        } catch {
            simulationError = error.localizedDescription
            isSimulating = false
        }
    }

    /// Recalculates BTC fee after user changes the fee speed picker.
    /// Re-runs UTXO selection with the new fee rate since different rates
    /// may require different numbers of inputs.
    private func recalculateBtcFee() async {
        guard let rates = fetchedBtcFeeRates,
              let chain = chainModel,
              chain.chainType == .bitcoin else { return }

        let newRate = selectedBtcFeeSpeed.rate(from: rates)

        // Re-fetch UTXOs to re-run selection (use stored amount)
        do {
            let allUtxos = try await RPCService.shared.getBitcoinUtxos(
                apiUrl: chain.activeRpcUrl,
                address: transaction.from
            )

            let sorted = allUtxos.sorted { $0.amountSat > $1.amountSat }
            var selected: [UtxoData] = []
            var totalSelected: UInt64 = 0
            var feeSat: UInt64 = 0

            for utxo in sorted {
                selected.append(utxo)
                totalSelected += utxo.amountSat

                let estimatedVsize = UInt64(selected.count * 68 + 2 * 31 + 10)
                feeSat = newRate * estimatedVsize

                if totalSelected >= fetchedBtcAmountSat + feeSat {
                    break
                }
            }

            guard totalSelected >= fetchedBtcAmountSat + feeSat else {
                let totalAvailable = allUtxos.reduce(UInt64(0)) { $0 + $1.amountSat }
                let availableBtc = String(format: "%.8f", Double(totalAvailable) / 1e8)
                let neededBtc = String(format: "%.8f", Double(fetchedBtcAmountSat + feeSat) / 1e8)
                await MainActor.run {
                    simulationError = "Insufficient funds at this fee rate. Available: \(availableBtc) BTC, needed: \(neededBtc) BTC"
                }
                return
            }

            await MainActor.run {
                simulationError = nil
                btcFeeSat = feeSat
                estimatedFee = String(format: "%.8g", Double(feeSat) / 1e8)
                fetchedBtcFeeRate = newRate
                fetchedBtcUtxos = selected
            }
        } catch {
            await MainActor.run {
                simulationError = error.localizedDescription
            }
        }
    }

    private func signAndSend() async {
        isSigning = true

        guard let chain = chainModel else {
            simulationError = "Unknown chain"
            isSigning = false
            return
        }

        do {
            let signedTx: Data
            let txHash: String

            switch chain.chainType {
            case .evm:
                guard let chainId = chain.evmChainId else {
                    simulationError = "Unknown EVM chain"
                    isSigning = false
                    return
                }

                // ERC-20: send to contract with transfer calldata, value = 0
                // Native: send to recipient with value in wei
                let txTo: String
                let txValueHex: String
                let txData: Data

                if let contractAddress = transaction.contractAddress {
                    let tokenAmountHex = amountToHex(transaction.amount, decimals: transaction.tokenDecimals)
                    guard let calldata = encodeERC20Transfer(to: transaction.to, amountHex: tokenAmountHex) else {
                        throw AppWalletError.signingFailed
                    }
                    txTo = contractAddress
                    txValueHex = "0x0"
                    txData = calldata
                } else {
                    txTo = transaction.to
                    txValueHex = amountToHex(transaction.amount, decimals: 18)
                    txData = Data()
                }

                let ethReq = EthTransactionRequest(
                    chainId: chainId,
                    nonce: fetchedNonce,
                    to: txTo,
                    valueWeiHex: txValueHex,
                    data: txData,
                    maxPriorityFeeHex: fetchedMaxPriorityFeeHex,
                    maxFeeHex: fetchedMaxFeeHex,
                    gasLimit: fetchedGasLimit
                )

                signedTx = try await walletService.signTransaction(request: .eth(ethReq))
                let signedHex = "0x" + signedTx.map { String(format: "%02x", $0) }.joined()
                txHash = try await RPCService.shared.sendRawTransaction(
                    rpcUrl: chain.activeRpcUrl,
                    signedTx: signedHex
                )

            case .solana:
                let lamports = amountToSmallestUnit(transaction.amount, decimals: 9)
                let blockhash = try await RPCService.shared.getRecentBlockhash(rpcUrl: chain.activeRpcUrl)

                let solReq = SolTransactionRequest(
                    to: transaction.to,
                    lamports: lamports,
                    recentBlockhash: blockhash
                )

                signedTx = try await walletService.signTransaction(request: .sol(solReq))
                txHash = try await RPCService.shared.sendSolanaTransaction(
                    rpcUrl: chain.activeRpcUrl,
                    signedTx: signedTx.base64EncodedString()
                )

            case .bitcoin:
                let changeAddr = walletService.addresses["bitcoin"] ?? transaction.from
                let isTestnet = chain.isTestnet

                let btcReq = BtcTransactionRequest(
                    utxos: fetchedBtcUtxos,
                    recipientAddress: transaction.to,
                    amountSat: fetchedBtcAmountSat,
                    changeAddress: changeAddr,
                    feeRateSatVbyte: fetchedBtcFeeRate,
                    isTestnet: isTestnet
                )

                signedTx = try await walletService.signTransaction(request: .btc(btcReq))
                let txHexStr = signedTx.map { String(format: "%02x", $0) }.joined()
                txHash = try await RPCService.shared.broadcastBitcoinTransaction(
                    apiUrl: chain.activeRpcUrl,
                    txHex: txHexStr
                )
            }

            // Record the transaction locally so it appears immediately in ActivityView
            let sentTx = TransactionModel(
                hash: txHash,
                chain: transaction.chain,
                from: transaction.from,
                to: transaction.to,
                amount: transaction.amount,
                fee: estimatedFee,
                status: .pending,
                timestamp: Date(),
                tokenSymbol: transaction.tokenSymbol,
                tokenDecimals: transaction.tokenDecimals,
                contractAddress: transaction.contractAddress
            )
            walletService.recordLocalTransaction(sentTx)

            // Invalidate cache for this chain so next refresh fetches fresh data
            TransactionHistoryService.shared.invalidateCache(for: transaction.chain)

            await MainActor.run {
                isSigning = false
                router.sendPath.append(
                    AppRouter.SendDestination.transactionResult(txHash: txHash, success: true, chain: transaction.chain)
                )
            }
        } catch let error as AppWalletError where error == .passwordRequired {
            // Session password was cleared (app was backgrounded) — prompt re-entry
            await MainActor.run {
                isSigning = false
                reenteredPassword = ""
                passwordError = nil
                showPasswordPrompt = true
                pendingSignRetry = true
            }
        } catch {
            await MainActor.run {
                isSigning = false
                simulationError = error.localizedDescription
            }
        }
    }

    /// Called after user re-enters password in the sheet.
    private func verifyAndRetrySign() async {
        isVerifyingPassword = true
        passwordError = nil

        do {
            try await walletService.setSessionPassword(reenteredPassword)
            await MainActor.run {
                isVerifyingPassword = false
                showPasswordPrompt = false
                reenteredPassword = ""
            }
            // Retry the sign
            if pendingSignRetry {
                pendingSignRetry = false
                await signAndSend()
            }
        } catch {
            await MainActor.run {
                isVerifyingPassword = false
                passwordError = "Incorrect password. Please try again."
            }
        }
    }
}

// MARK: - Password Re-entry Sheet

private struct PasswordReentrySheet: View {
    @Binding var password: String
    @Binding var errorMessage: String?
    @Binding var isVerifying: Bool
    let onSubmit: () async -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentGreen)

            Text("Re-enter Password")
                .font(.title3.bold())
                .foregroundColor(.textPrimary)

            Text("Your session expired. Please re-enter your wallet password to sign this transaction.")
                .font(.body)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)

            SecureField("Password", text: $password)
                .font(.body)
                .padding(12)
                .background(Color.backgroundCard)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(errorMessage != nil ? Color.error : Color.border, lineWidth: 1)
                )

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.error)
            }

            Button {
                Task { await onSubmit() }
            } label: {
                if isVerifying {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Unlock & Sign")
                }
            }
            .buttonStyle(PrimaryButtonStyle(isEnabled: !password.isEmpty))
            .disabled(password.isEmpty || isVerifying)
        }
        .padding(24)
    }
}

// MARK: - AppWalletError Equatable for pattern matching

extension AppWalletError: Equatable {
    static func == (lhs: AppWalletError, rhs: AppWalletError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidMnemonic, .invalidMnemonic),
             (.seedNotFound, .seedNotFound),
             (.encryptionFailed, .encryptionFailed),
             (.decryptionFailed, .decryptionFailed),
             (.authenticationFailed, .authenticationFailed),
             (.keyDerivationFailed, .keyDerivationFailed),
             (.signingFailed, .signingFailed),
             (.passwordRequired, .passwordRequired):
            return true
        case (.networkError(let a), .networkError(let b)),
             (.rustFFIError(let a), .rustFFIError(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - BTC Fee Speed Picker

private struct BtcFeeSpeedPicker: View {
    @Binding var selectedSpeed: ConfirmTransactionView.BtcFeeSpeed
    let feeRates: RPCService.BitcoinFeeRates

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fee Priority")
                .font(.subheadline.bold())
                .foregroundColor(.textSecondary)

            HStack(spacing: 8) {
                ForEach(ConfirmTransactionView.BtcFeeSpeed.allCases) { speed in
                    let rate = speed.rate(from: feeRates)
                    let isSelected = selectedSpeed == speed

                    Button {
                        selectedSpeed = speed
                    } label: {
                        VStack(spacing: 4) {
                            Text(speed.rawValue.capitalized)
                                .font(.subheadline.bold())
                                .foregroundColor(isSelected ? .white : .textPrimary)

                            Text("\(rate) sat/vB")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(isSelected ? .white.opacity(0.8) : .textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(isSelected ? Color.accentGreen : Color.backgroundCard)
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isSelected ? Color.clear : Color.border, lineWidth: 1)
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Detail Row

private struct DetailRow: View {
    let label: String
    let value: String
    var valueColor: Color = .textPrimary

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.textSecondary)
            Spacer()
            Text(value)
                .foregroundColor(valueColor)
                .monospacedDigit()
        }
    }
}

// MARK: - Data hex init

private extension Data {
    /// Initializes Data from a hex string (no 0x prefix expected).
    /// Returns nil if any character is not a valid hex digit.
    init?(strictHexString hex: String) {
        var chars = Array(hex)
        // Pad odd-length strings
        if chars.count % 2 != 0 { chars.insert("0", at: 0) }
        var bytes = Data()
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else {
                return nil
            }
            bytes.append(byte)
        }
        self = bytes
    }
}

#Preview {
    NavigationStack {
        ConfirmTransactionView(transaction: .preview)
            .environmentObject(WalletService.shared)
            .environmentObject(AppRouter())
    }
}
