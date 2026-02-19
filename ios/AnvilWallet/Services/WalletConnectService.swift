import Foundation
import Combine
import os.log
import ReownWalletKit

// MARK: - WebSocket Factory (required by Reown SDK)

/// Native URLSessionWebSocketTask-based WebSocket factory for the Reown SDK.
struct NativeSocketFactory: WebSocketFactory {
    func create(with url: URL) -> WebSocketConnecting {
        NativeWebSocket(url: url)
    }
}

/// Minimal WebSocket wrapper using URLSessionWebSocketTask.
///
/// Note: Uses default URLSession TLS validation (not CertificatePinner) because
/// the Reown relay server (relay.walletconnect.com) manages its own cert rotation.
/// CertificatePinner is fail-closed, so pinning the relay would break WC connections
/// when Reown rotates certificates. Standard TLS validation is the accepted trade-off.
final class NativeWebSocket: WebSocketConnecting {
    var isConnected: Bool = false
    var onConnect: (() -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var onText: ((String) -> Void)?
    var request: URLRequest

    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private var didConnect = false

    init(url: URL) {
        self.request = URLRequest(url: url)
        self.session = URLSession(configuration: .default)
    }

    func connect() {
        task = session.webSocketTask(with: request)
        task?.resume()
        didConnect = false
        receiveMessage()
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        isConnected = false
        onDisconnect?(nil)
    }

    func write(string: String, completion: (() -> Void)?) {
        task?.send(.string(string)) { _ in
            completion?()
        }
    }

    private func receiveMessage() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                if !self.didConnect {
                    self.didConnect = true
                    self.isConnected = true
                    self.onConnect?()
                }
                switch message {
                case .string(let text):
                    self.onText?(text)
                default:
                    break
                }
                self.receiveMessage()
            case .failure(let error):
                self.isConnected = false
                self.onDisconnect?(error)
            }
        }
    }
}

// MARK: - CryptoProvider (required by Reown SDK for SIWE verification)

/// Bridges Reown SDK crypto operations to the Rust wallet-core FFI.
struct AnvilCryptoProvider: CryptoProvider {
    func recoverPubKey(signature: EthereumSignature, message: Data) throws -> Data {
        // Reconstruct 65-byte signature: r(32) + s(32) + v(1)
        let sigBytes = Data(signature.r + signature.s + [signature.v + 27])
        let recovered = try recoverEthPubkey(
            signature: sigBytes,
            messageHash: message
        )
        return Data(recovered)
    }

    func keccak256(_ data: Data) -> Data {
        return AnvilWallet.keccak256(data: data)
    }
}

/// WalletConnectService provides WalletConnect v2 protocol support
/// for connecting to decentralized applications (dApps) via the Reown SDK.
///
/// Supports:
///   - Pairing with dApps via WalletConnect URI
///   - Approving/rejecting session proposals
///   - personal_sign message signing
///   - eth_sendTransaction (sign + broadcast EIP-1559 transactions)
///   - eth_signTypedData_v4 (EIP-712 typed data)
///   - solana_signTransaction (sign pre-built Solana transactions)
///   - solana_signMessage (Ed25519 message signing)
///   - Session management (list, disconnect)
final class WalletConnectService: ObservableObject {

    static let shared = WalletConnectService()

    @Published var activeSessions: [WCSession] = []
    @Published var pendingProposal: WCSessionProposal?
    @Published var pendingRequest: WCSignRequest?

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Data Types

    struct WCSession: Identifiable, Hashable {
        let id: String
        let peerName: String
        let peerUrl: String
        let peerIconUrl: String?
        let chains: [String]
        let connectedAt: Date
    }

    struct WCSessionProposal: Identifiable {
        let id: String
        let peerName: String
        let peerUrl: String
        let peerIconUrl: String?
        let requiredChains: [String]
        let optionalChains: [String]
        let methods: [String]
        let events: [String]
    }

    struct WCSignRequest: Identifiable {
        let id: String
        let sessionId: String
        let chain: String
        let method: String
        let params: Data
        let peerName: String
    }

    // MARK: - Configuration

    /// Configures the Reown WalletKit. Must be called once at app launch.
    func configure(projectId: String) {
        guard let redirect = try? AppMetadata.Redirect(native: "anvilwallet://", universal: nil) else {
            Logger(subsystem: "com.anvilwallet", category: "WalletConnect")
                .error("WalletConnect redirect metadata init failed — WC will be unavailable")
            return
        }
        let metadata = AppMetadata(
            name: "Anvil Wallet",
            description: "Self-custody crypto wallet",
            url: "https://anvilwallet.com",
            icons: ["https://anvilwallet.com/icon.png"],
            redirect: redirect
        )

        Networking.configure(
            groupIdentifier: "group.com.anvilwallet",
            projectId: projectId,
            socketFactory: NativeSocketFactory()
        )

        WalletKit.configure(metadata: metadata, crypto: AnvilCryptoProvider())

        setupSubscriptions()
        refreshSessions()
    }

    // MARK: - Subscriptions

    private func setupSubscriptions() {
        // Session proposals from dApps
        WalletKit.instance.sessionProposalPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (proposal, _) in
                let peer = proposal.proposer

                var requiredChains: [String] = []
                var methods: [String] = []
                var events: [String] = []

                // Collect EVM chains
                if let eip155 = proposal.requiredNamespaces["eip155"] {
                    requiredChains += eip155.chains?.map { $0.absoluteString } ?? []
                    methods += eip155.methods.sorted()
                    events += eip155.events.sorted()
                }

                // Collect Solana chains
                if let solana = proposal.requiredNamespaces["solana"] {
                    requiredChains += solana.chains?.map { $0.absoluteString } ?? []
                    methods += solana.methods.sorted()
                    events += solana.events.sorted()
                }

                var optionalChains: [String] = []
                if let optEip155 = proposal.optionalNamespaces?["eip155"] {
                    optionalChains += optEip155.chains?.map { $0.absoluteString } ?? []
                }
                if let optSolana = proposal.optionalNamespaces?["solana"] {
                    optionalChains += optSolana.chains?.map { $0.absoluteString } ?? []
                }

                self?.pendingProposal = WCSessionProposal(
                    id: proposal.id,
                    peerName: peer.name,
                    peerUrl: peer.url,
                    peerIconUrl: peer.icons.first,
                    requiredChains: requiredChains,
                    optionalChains: optionalChains,
                    methods: methods,
                    events: events
                )
            }
            .store(in: &cancellables)

        // Sign requests from connected dApps
        WalletKit.instance.sessionRequestPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (request, _) in
                let paramsData: Data
                if let jsonData = try? JSONEncoder().encode(request.params) {
                    paramsData = jsonData
                } else {
                    paramsData = Data()
                }

                let peerName = WalletKit.instance.getSessions()
                    .first { $0.topic == request.topic }?
                    .peer.name ?? "Unknown DApp"

                self?.pendingRequest = WCSignRequest(
                    id: request.id.string,
                    sessionId: request.topic,
                    chain: request.chainId.absoluteString,
                    method: request.method,
                    params: paramsData,
                    peerName: peerName
                )
            }
            .store(in: &cancellables)

        // Session changes (connect/disconnect)
        WalletKit.instance.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshSessions()
            }
            .store(in: &cancellables)
    }

    // MARK: - Session List

    private func refreshSessions() {
        let sessions = WalletKit.instance.getSessions()
        activeSessions = sessions.map { session in
            WCSession(
                id: session.topic,
                peerName: session.peer.name,
                peerUrl: session.peer.url,
                peerIconUrl: session.peer.icons.first,
                chains: session.namespaces.values.flatMap { $0.chains?.map { $0.absoluteString } ?? [] },
                connectedAt: session.expiryDate // Approximate — SDK doesn't expose createdAt
            )
        }
    }

    // MARK: - Pairing

    /// Initiates pairing with a dApp using a WalletConnect URI.
    func pair(uri: String) async throws {
        // Validate URI scheme before passing to SDK
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("wc:") else {
            throw WCError.invalidURI
        }
        let wcUri: WalletConnectURI
        do {
            wcUri = try WalletConnectURI(uriString: trimmed)
        } catch {
            throw WCError.invalidURI
        }
        try await WalletKit.instance.pair(uri: wcUri)
    }

    // MARK: - Session Management

    /// Approves a pending session proposal.
    /// Builds eip155 and solana namespaces from the wallet's addresses for all requested chains.
    func approveSession(
        _ proposal: WCSessionProposal,
        ethAddress: String,
        solAddress: String? = nil
    ) async throws {
        // Separate chains by namespace
        var allChains = proposal.requiredChains + proposal.optionalChains

        let evmChains = allChains.filter { $0.hasPrefix("eip155:") }
        let solanaChains = allChains.filter { $0.hasPrefix("solana:") }

        var sessionNamespaces: [String: SessionNamespace] = [:]

        // EVM namespace
        var evmChainList = evmChains
        if evmChainList.isEmpty && solanaChains.isEmpty {
            // Default to Ethereum mainnet if no chains requested at all
            evmChainList = ["eip155:1"]
        }

        if !evmChainList.isEmpty {
            let evmAccounts = evmChainList.compactMap { chainString -> Account? in
                guard let blockchain = Blockchain(chainString) else { return nil }
                return Account(blockchain: blockchain, address: ethAddress)
            }

            sessionNamespaces["eip155"] = SessionNamespace(
                chains: evmAccounts.map { $0.blockchain },
                accounts: evmAccounts,
                methods: Self.supportedEvmMethods,
                events: Set(["chainChanged", "accountsChanged"])
            )
        }

        // Solana namespace
        if let solAddr = solAddress, !solanaChains.isEmpty {
            let solAccounts = solanaChains.compactMap { chainString -> Account? in
                guard let blockchain = Blockchain(chainString) else { return nil }
                return Account(blockchain: blockchain, address: solAddr)
            }

            if !solAccounts.isEmpty {
                sessionNamespaces["solana"] = SessionNamespace(
                    chains: solAccounts.map { $0.blockchain },
                    accounts: solAccounts,
                    methods: Self.supportedSolanaMethods,
                    events: Set<String>()
                )
            }
        }

        _ = try await WalletKit.instance.approve(
            proposalId: proposal.id,
            namespaces: sessionNamespaces
        )

        await MainActor.run {
            pendingProposal = nil
        }
        refreshSessions()
    }

    /// Rejects a pending session proposal.
    func rejectSession(_ proposal: WCSessionProposal) async throws {
        try await WalletKit.instance.rejectSession(
            proposalId: proposal.id,
            reason: .userRejected
        )
        await MainActor.run {
            pendingProposal = nil
        }
    }

    /// Disconnects an active session.
    func disconnectSession(_ session: WCSession) async throws {
        try await WalletKit.instance.disconnect(topic: session.id)
        await MainActor.run {
            activeSessions.removeAll { $0.id == session.id }
        }
    }

    // MARK: - Request Handling

    /// Supported EVM signing methods.
    private static let supportedEvmMethods: Set<String> = [
        "personal_sign",
        "eth_sendTransaction",
        "eth_signTypedData_v4",
    ]

    /// Supported Solana signing methods.
    private static let supportedSolanaMethods: Set<String> = [
        "solana_signTransaction",
        "solana_signMessage",
    ]

    /// All supported methods across all namespaces.
    private static let supportedMethods: Set<String> =
        supportedEvmMethods.union(supportedSolanaMethods)

    /// Approves a pending sign request by signing the message data.
    func approveRequest(_ request: WCSignRequest, walletService: WalletService) async throws {
        // Validate method is one we actually support
        guard Self.supportedMethods.contains(request.method) else {
            throw WCError.unsupportedMethod(request.method)
        }

        let responseValue: AnyCodable

        if request.chain.hasPrefix("solana:") {
            // --- Solana methods ---
            guard Self.supportedSolanaMethods.contains(request.method) else {
                throw WCError.unsupportedMethod(request.method)
            }

            // Fail-closed address check — same pattern as EVM methods
            guard let activeSolAddress = walletService.addresses["solana"] else {
                throw WCError.malformedParams("No active Solana wallet address available")
            }

            // If the dApp specified a pubkey, verify it matches our active address
            if let dict = try? JSONSerialization.jsonObject(with: request.params) as? [String: Any],
               let requestedPubkey = dict["pubkey"] as? String,
               !requestedPubkey.isEmpty,
               requestedPubkey != activeSolAddress {
                throw WCError.accountMismatch(requested: requestedPubkey)
            }

            switch request.method {
            case "solana_signTransaction":
                responseValue = try await handleSolanaSignTransaction(request, walletService: walletService)

            case "solana_signMessage":
                responseValue = try await handleSolanaSignMessage(request, walletService: walletService)

            default:
                throw WCError.unsupportedMethod(request.method)
            }
        } else if request.chain.hasPrefix("eip155:") {
            // --- EVM methods ---
            guard Self.supportedEvmMethods.contains(request.method) else {
                throw WCError.unsupportedMethod(request.method)
            }

            // Active wallet ETH address for account validation (fail-closed).
            // All EVM chains share the same address, so grab the first EVM entry.
            // If unavailable, reject all signing requests rather than signing blindly.
            guard let activeAddress = ChainModel.defaults
                .first(where: { $0.chainType == .evm })
                .flatMap({ walletService.addresses[$0.id] })?
                .lowercased()
            else {
                throw WCError.malformedParams("No active EVM wallet address available")
            }

            switch request.method {
            case "personal_sign":
                // personal_sign params: [message_hex, address]
                // Validate that the requested address matches our active wallet
                if let requestedAddress = parsePersonalSignAddress(from: request.params),
                   requestedAddress.lowercased() != activeAddress {
                    throw WCError.accountMismatch(requested: requestedAddress)
                }
                guard let messageHex = parsePersonalSignMessage(from: request.params) else {
                    throw WCError.malformedParams("Malformed personal_sign params")
                }
                guard let messageBytes = strictHexToBytes(messageHex), !messageBytes.isEmpty else {
                    throw WCError.malformedParams("Invalid hex in personal_sign message")
                }

                // Sign using the wallet service (requires biometric auth)
                let signature = try await walletService.signMessage(messageBytes)
                responseValue = AnyCodable("0x" + signature.map { String(format: "%02x", $0) }.joined())

            case "eth_sendTransaction":
                // Validate 'from' address matches active wallet
                if let txParams = parseTransactionParams(from: request.params),
                   let from = txParams.from,
                   from.lowercased() != activeAddress {
                    throw WCError.accountMismatch(requested: from)
                }
                responseValue = try await handleSendTransaction(request, walletService: walletService)

            case "eth_signTypedData_v4":
                // Validate requested address matches active wallet
                if let (requestedAddr, _) = parseTypedDataParams(from: request.params),
                   requestedAddr.lowercased() != activeAddress {
                    throw WCError.accountMismatch(requested: requestedAddr)
                }
                responseValue = try await handleSignTypedData(request, walletService: walletService)

            default:
                throw WCError.unsupportedMethod(request.method)
            }
        } else {
            throw WCError.chainNotSupported(request.chain)
        }

        let rpcId = RPCID(request.id)
        let response = RPCResult.response(responseValue)
        try await WalletKit.instance.respond(
            topic: request.sessionId,
            requestId: rpcId,
            response: response
        )

        await MainActor.run {
            pendingRequest = nil
        }
    }

    /// Rejects a pending sign request.
    func rejectRequest(_ request: WCSignRequest) async throws {
        let rpcId = RPCID(request.id)
        try await WalletKit.instance.respond(
            topic: request.sessionId,
            requestId: rpcId,
            response: .error(.init(code: 4001, message: "User rejected"))
        )

        await MainActor.run {
            pendingRequest = nil
        }
    }

    // MARK: - Helpers

    /// Extracts the address from personal_sign params: [message, address].
    private func parsePersonalSignAddress(from params: Data) -> String? {
        guard let array = try? JSONDecoder().decode([String].self, from: params),
              array.count >= 2 else { return nil }
        return array[1]
    }

    /// Parses the personal_sign message from JSON params.
    /// Returns nil if params are malformed — caller must reject the request.
    private func parsePersonalSignMessage(from params: Data) -> String? {
        // personal_sign params must be a JSON array: ["0xmessage", "0xaddress"]
        guard let array = try? JSONDecoder().decode([String].self, from: params),
              array.count >= 1,
              let first = array.first,
              !first.isEmpty else {
            return nil
        }
        return first.hasPrefix("0x") ? String(first.dropFirst(2)) : first
    }

    /// Strict hex decoder — returns nil on any invalid hex character or odd length.
    private func strictHexToBytes(_ hex: String) -> [UInt8]? {
        let cleaned = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(String(cleaned[index..<nextIndex]), radix: 16) else {
                return nil // Invalid hex pair — reject entire message
            }
            bytes.append(byte)
            index = nextIndex
        }
        return bytes
    }

    // MARK: - eth_sendTransaction

    /// Transaction parameters from a WC eth_sendTransaction request.
    private struct WCTransactionParams: Decodable {
        let from: String?
        let to: String
        let value: String?
        let data: String?
        let gas: String?
        let gasLimit: String?
        let gasPrice: String?
        let maxFeePerGas: String?
        let maxPriorityFeePerGas: String?
        let nonce: String?
    }

    private func parseTransactionParams(from params: Data) -> WCTransactionParams? {
        guard let array = try? JSONDecoder().decode([WCTransactionParams].self, from: params),
              let first = array.first else {
            return nil
        }
        return first
    }

    /// Handles eth_sendTransaction: parse tx, fetch missing params, sign, broadcast.
    private func handleSendTransaction(
        _ request: WCSignRequest,
        walletService: WalletService
    ) async throws -> AnyCodable {
        guard let chainId = Self.extractEvmChainId(from: request.chain) else {
            throw WCError.chainNotSupported(request.chain)
        }
        guard let rpcUrl = Self.rpcUrl(forEvmChainId: chainId) else {
            throw WCError.chainNotSupported("No RPC endpoint for chain \(chainId)")
        }
        guard let txParams = parseTransactionParams(from: request.params) else {
            throw WCError.malformedParams("Invalid eth_sendTransaction params")
        }

        let rpc = RPCService.shared

        // Nonce: use provided or fetch from network
        let nonce: UInt64
        if let n = txParams.nonce, let parsed = Self.hexToUInt64(n) {
            nonce = parsed
        } else {
            guard let from = txParams.from else {
                throw WCError.malformedParams("Missing 'from' address")
            }
            let nonceHex: String = try await rpc.getTransactionCount(rpcUrl: rpcUrl, address: from)
            guard let parsed = Self.hexToUInt64(nonceHex) else {
                throw WCError.rpcError("Invalid nonce: \(nonceHex)")
            }
            nonce = parsed
        }

        // Gas limit: use provided or estimate
        let gasLimit: UInt64
        if let g = txParams.gas ?? txParams.gasLimit, let parsed = Self.hexToUInt64(g) {
            gasLimit = parsed
        } else {
            let estimated: String = try await rpc.estimateGas(
                rpcUrl: rpcUrl,
                from: txParams.from ?? "",
                to: txParams.to,
                value: txParams.value ?? "0x0",
                data: txParams.data
            )
            guard let parsed = Self.hexToUInt64(estimated) else {
                throw WCError.rpcError("Invalid gas estimate: \(estimated)")
            }
            gasLimit = parsed + parsed / 5 // 20% buffer
        }

        // Fee params: EIP-1559 preferred, legacy gasPrice as fallback
        let maxFeeHex: String
        let maxPriorityFeeHex: String
        if let mf = txParams.maxFeePerGas, let mpf = txParams.maxPriorityFeePerGas {
            maxFeeHex = mf
            maxPriorityFeeHex = mpf
        } else if let gp = txParams.gasPrice {
            maxFeeHex = gp
            maxPriorityFeeHex = gp
        } else {
            let fees = try await rpc.feeHistory(rpcUrl: rpcUrl)
            maxPriorityFeeHex = fees.priorityFeeHex
            if let baseFee = Self.hexToUInt64(fees.baseFeeHex),
               let priority = Self.hexToUInt64(fees.priorityFeeHex) {
                let maxFee = baseFee * 2 + priority
                maxFeeHex = "0x" + String(maxFee, radix: 16)
            } else {
                maxFeeHex = fees.baseFeeHex
            }
        }

        // Build calldata — reject invalid hex rather than silently dropping it,
        // because empty calldata changes a contract call into a plain ETH transfer.
        let calldata: Data
        if let dataHex = txParams.data, !dataHex.isEmpty, dataHex != "0x" {
            let cleaned = dataHex.hasPrefix("0x") ? String(dataHex.dropFirst(2)) : dataHex
            guard let bytes = strictHexToBytes(cleaned) else {
                throw WCError.malformedParams("Invalid hex in transaction data field")
            }
            calldata = Data(bytes)
        } else {
            calldata = Data()
        }

        let ethReq = EthTransactionRequest(
            chainId: chainId,
            nonce: nonce,
            to: txParams.to,
            valueWeiHex: txParams.value ?? "0x0",
            data: calldata,
            maxPriorityFeeHex: maxPriorityFeeHex,
            maxFeeHex: maxFeeHex,
            gasLimit: gasLimit
        )

        // Sign
        let signedTx = try await walletService.signTransaction(request: .eth(ethReq))
        let signedTxHex = "0x" + signedTx.map { String(format: "%02x", $0) }.joined()

        // Broadcast and return tx hash
        let txHash: String = try await rpc.sendRawTransaction(rpcUrl: rpcUrl, signedTx: signedTxHex)
        return AnyCodable(txHash)
    }

    // MARK: - eth_signTypedData_v4

    // EIP-712 signing uses sign_eth_raw_hash() FFI which signs a 32-byte hash
    // directly without applying the EIP-191 "\x19Ethereum Signed Message:\n" prefix.

    /// Parses eth_signTypedData_v4 params: [address, typedDataJSON]
    private func parseTypedDataParams(from params: Data) -> (address: String, typedData: Data)? {
        // Common case: params are [String, String] where typedData is a JSON string
        if let array = try? JSONDecoder().decode([String].self, from: params),
           array.count >= 2,
           let typedDataData = array[1].data(using: .utf8) {
            return (array[0], typedDataData)
        }

        // Fallback: typedData may be a JSON object instead of a string
        if let jsonArray = try? JSONSerialization.jsonObject(with: params) as? [Any],
           jsonArray.count >= 2,
           let address = jsonArray[0] as? String {
            if let typedDataStr = jsonArray[1] as? String,
               let data = typedDataStr.data(using: .utf8) {
                return (address, data)
            }
            if let obj = jsonArray[1] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: obj) {
                return (address, data)
            }
        }

        return nil
    }

    /// Handles eth_signTypedData_v4: compute EIP-712 hash and sign.
    private func handleSignTypedData(
        _ request: WCSignRequest,
        walletService: WalletService
    ) async throws -> AnyCodable {
        guard let (_, typedDataBytes) = parseTypedDataParams(from: request.params) else {
            throw WCError.malformedParams("Invalid eth_signTypedData_v4 params")
        }

        let typedData: EIP712TypedData
        do {
            typedData = try JSONDecoder().decode(EIP712TypedData.self, from: typedDataBytes)
        } catch {
            throw WCError.malformedParams("Invalid EIP-712 typed data: \(error.localizedDescription)")
        }

        // Compute EIP-712 hash
        let domainSeparator = EIP712Hasher.hashStruct(
            "EIP712Domain", data: typedData.domain, types: typedData.types
        )
        let messageHash = EIP712Hasher.hashStruct(
            typedData.primaryType, data: typedData.message, types: typedData.types
        )

        // Final hash: keccak256("\x19\x01" || domainSeparator || messageHash)
        var payload = Data([0x19, 0x01])
        payload.append(domainSeparator)
        payload.append(messageHash)
        let finalHash = keccak256(data: payload)

        let signature = try await walletService.signRawHash([UInt8](finalHash))
        return AnyCodable("0x" + signature.map { String(format: "%02x", $0) }.joined())
    }

    // MARK: - EIP-712 Types

    private struct EIP712TypedData: Decodable {
        let types: [String: [EIP712Field]]
        let primaryType: String
        let domain: [String: EIP712Value]
        let message: [String: EIP712Value]
    }

    private struct EIP712Field: Decodable {
        let name: String
        let type: String
    }

    /// Flexible JSON value type for decoding EIP-712 domain and message fields.
    /// Uses String representation for numbers to avoid Double precision loss on uint256 values.
    private enum EIP712Value: Decodable {
        case string(String)
        case number(String) // Stored as string to preserve full precision for large integers
        case bool(Bool)
        case object([String: EIP712Value])
        case array([EIP712Value])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            // Check bool before number — JSON booleans also decode as Double
            if let b = try? container.decode(Bool.self) {
                self = .bool(b)
            } else if let s = try? container.decode(String.self) {
                self = .string(s)
            } else if let n = try? container.decode(JSONNumber.self) {
                self = .number(n.rawValue)
            } else if let o = try? container.decode([String: EIP712Value].self) {
                self = .object(o)
            } else if let a = try? container.decode([EIP712Value].self) {
                self = .array(a)
            } else {
                self = .null
            }
        }
    }

    /// Decodes a JSON number as its raw string representation to avoid Double precision loss.
    private struct JSONNumber: Decodable {
        let rawValue: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            // Try Int64 first for exact integer representation
            if let i = try? container.decode(Int64.self) {
                rawValue = String(i)
            } else if let u = try? container.decode(UInt64.self) {
                rawValue = String(u)
            } else if let d = try? container.decode(Decimal.self) {
                // Decimal preserves up to 38 significant digits (enough for uint128, not uint256)
                // For truly huge values, dApps typically send hex strings, not JSON numbers.
                rawValue = "\(d)"
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a number")
            }
        }
    }

    // MARK: - EIP-712 Hasher

    /// Implements EIP-712 struct hashing per https://eips.ethereum.org/EIPS/eip-712
    private enum EIP712Hasher {

        /// Computes hashStruct(typeName, data) = keccak256(typeHash || encodeData)
        static func hashStruct(
            _ typeName: String,
            data: [String: EIP712Value],
            types: [String: [EIP712Field]]
        ) -> Data {
            let typeStr = encodeType(typeName, types: types)
            let typeHash = keccak256(data: Data(typeStr.utf8))
            let encodedData = encodeData(typeName, data: data, types: types)
            return keccak256(data: typeHash + encodedData)
        }

        /// Encodes the type string: "TypeName(type1 name1,...)" + sorted referenced types.
        static func encodeType(_ typeName: String, types: [String: [EIP712Field]]) -> String {
            guard let fields = types[typeName] else { return "" }
            let primary = typeName + "(" +
                fields.map { "\($0.type) \($0.name)" }.joined(separator: ",") + ")"

            var referenced = Set<String>()
            findReferencedTypes(typeName, types: types, found: &referenced)
            referenced.remove(typeName)

            let sortedRefs = referenced.sorted().map { refType -> String in
                guard let refFields = types[refType] else { return "" }
                return refType + "(" +
                    refFields.map { "\($0.type) \($0.name)" }.joined(separator: ",") + ")"
            }

            return primary + sortedRefs.joined()
        }

        /// Recursively finds all struct types referenced by a given type.
        private static func findReferencedTypes(
            _ typeName: String,
            types: [String: [EIP712Field]],
            found: inout Set<String>
        ) {
            guard let fields = types[typeName] else { return }
            for field in fields {
                let baseType = field.type.replacingOccurrences(of: "[]", with: "")
                if types[baseType] != nil && !found.contains(baseType) {
                    found.insert(baseType)
                    findReferencedTypes(baseType, types: types, found: &found)
                }
            }
        }

        /// Encodes data fields according to their EIP-712 types.
        static func encodeData(
            _ typeName: String,
            data: [String: EIP712Value],
            types: [String: [EIP712Field]]
        ) -> Data {
            guard let fields = types[typeName] else { return Data() }
            var encoded = Data()
            for field in fields {
                let value = data[field.name] ?? .null
                encoded.append(encodeField(type: field.type, value: value, types: types))
            }
            return encoded
        }

        /// Encodes a single field value according to its EIP-712 type.
        static func encodeField(
            type: String,
            value: EIP712Value,
            types: [String: [EIP712Field]]
        ) -> Data {
            // Array types: T[] -> keccak256(concat(encoded elements))
            if type.hasSuffix("[]") {
                let baseType = String(type.dropLast(2))
                guard case .array(let items) = value else { return Data(count: 32) }
                var encoded = Data()
                for item in items {
                    encoded.append(encodeField(type: baseType, value: item, types: types))
                }
                return keccak256(data: encoded)
            }

            // Struct types: recursively hash
            if types[type] != nil {
                guard case .object(let obj) = value else { return Data(count: 32) }
                return hashStruct(type, data: obj, types: types)
            }

            // Atomic types
            return encodeAtomicValue(type: type, value: value)
        }

        /// Encodes an atomic (non-struct, non-array) EIP-712 value to 32 bytes.
        static func encodeAtomicValue(type: String, value: EIP712Value) -> Data {
            if type == "string" {
                guard case .string(let s) = value else { return Data(count: 32) }
                return keccak256(data: Data(s.utf8))
            }

            if type == "bytes" {
                guard case .string(let s) = value else { return Data(count: 32) }
                return keccak256(data: Data(hexToBytes(s)))
            }

            if type == "address" {
                guard case .string(let s) = value else { return Data(count: 32) }
                return leftPad32(Data(hexToBytes(s)))
            }

            if type == "bool" {
                var result = Data(count: 32)
                switch value {
                case .bool(let b): if b { result[31] = 1 }
                case .number(let s): if s != "0" { result[31] = 1 }
                default: break
                }
                return result
            }

            // uint<N> and int<N>
            if type.hasPrefix("uint") || type.hasPrefix("int") {
                let isSigned = type.hasPrefix("int") && !type.hasPrefix("uint")
                return encodeIntValue(value, signed: isSigned)
            }

            // bytes<N> (fixed-size, right-padded)
            if type.hasPrefix("bytes") {
                guard case .string(let s) = value else { return Data(count: 32) }
                let bytes = hexToBytes(s)
                var result = Data(count: 32)
                for (i, b) in bytes.prefix(32).enumerated() { result[i] = b }
                return result
            }

            return Data(count: 32)
        }

        /// Encodes a numeric value (uint/int) as a 32-byte left-padded value.
        /// For signed int<N> types, negative values are encoded as 32-byte two's complement.
        private static func encodeIntValue(_ value: EIP712Value, signed: Bool) -> Data {
            let rawString: String
            switch value {
            case .string(let s): rawString = s
            case .number(let s): rawString = s
            default: return Data(count: 32)
            }

            // Hex strings are already encoded — pass through directly
            if rawString.hasPrefix("0x") || rawString.hasPrefix("0X") {
                return leftPad32(Data(hexToBytes(rawString)))
            }

            // Check for negative values (signed int types)
            if signed && rawString.hasPrefix("-") {
                let magnitude = String(rawString.dropFirst())
                let magBytes = decimalStringToBytes(magnitude)
                return twosComplement32(magBytes)
            }

            // Positive value
            if let n = UInt64(rawString) {
                return leftPad32(uint64ToData(n))
            }
            return leftPad32(decimalStringToBytes(rawString))
        }

        /// Computes 32-byte two's complement of a positive magnitude (big-endian bytes).
        /// twos_complement = (~magnitude + 1), sign-extended to 32 bytes with 0xFF.
        private static func twosComplement32(_ magnitude: Data) -> Data {
            // Pad magnitude to 32 bytes
            var padded = Data(count: max(0, 32 - magnitude.count)) + magnitude
            if padded.count > 32 { padded = Data(padded.suffix(32)) }

            // Bitwise NOT
            for i in padded.indices { padded[i] = ~padded[i] }

            // Add 1 (big-endian)
            var carry: UInt16 = 1
            for i in stride(from: padded.count - 1, through: 0, by: -1) {
                let sum = UInt16(padded[i]) + carry
                padded[i] = UInt8(sum & 0xFF)
                carry = sum >> 8
            }

            return padded
        }

        /// Left-pads data to 32 bytes. Truncates to rightmost 32 bytes if longer.
        static func leftPad32(_ data: Data) -> Data {
            if data.count >= 32 { return Data(data.suffix(32)) }
            return Data(count: 32 - data.count) + data
        }

        private static func uint64ToData(_ n: UInt64) -> Data {
            withUnsafeBytes(of: n.bigEndian) { Data($0) }
        }

        /// Converts a decimal string to minimal big-endian bytes.
        private static func decimalStringToBytes(_ decimal: String) -> Data {
            var chars = Array(decimal).compactMap { $0.wholeNumberValue }
            guard !chars.isEmpty else { return Data([0]) }
            var result: [UInt8] = []
            while !chars.isEmpty {
                var remainder = 0
                var next: [Int] = []
                for digit in chars {
                    let n = remainder * 10 + digit
                    if !next.isEmpty || n / 256 > 0 {
                        next.append(n / 256)
                    }
                    remainder = n % 256
                }
                result.insert(UInt8(remainder), at: 0)
                chars = next
            }
            return Data(result)
        }

        /// Decodes a hex string (with or without 0x prefix) to bytes.
        private static func hexToBytes(_ hex: String) -> [UInt8] {
            let cleaned = hex.hasPrefix("0x") || hex.hasPrefix("0X")
                ? String(hex.dropFirst(2))
                : hex
            guard cleaned.count % 2 == 0 else { return [] }
            var bytes: [UInt8] = []
            var index = cleaned.startIndex
            while index < cleaned.endIndex {
                let nextIndex = cleaned.index(index, offsetBy: 2)
                guard let byte = UInt8(String(cleaned[index..<nextIndex]), radix: 16) else { return [] }
                bytes.append(byte)
                index = nextIndex
            }
            return bytes
        }
    }

    // MARK: - solana_signTransaction

    /// WalletConnect `solana_signTransaction` request params.
    ///
    /// The WC spec sends a JSON object with a `transaction` field containing
    /// the serialized transaction as a base58 string.
    private struct WCSolanaSignTransactionParams: Decodable {
        let transaction: String
    }

    /// Handles solana_signTransaction: decode raw tx, sign with Ed25519, return signed tx.
    private func handleSolanaSignTransaction(
        _ request: WCSignRequest,
        walletService: WalletService
    ) async throws -> AnyCodable {
        // Parse params — WC sends { transaction: "<base58-encoded-tx>" }
        let txBase58: String
        if let params = try? JSONDecoder().decode(
            WCSolanaSignTransactionParams.self, from: request.params
        ) {
            txBase58 = params.transaction
        } else if let dict = try? JSONSerialization.jsonObject(with: request.params) as? [String: Any],
                  let tx = dict["transaction"] as? String {
            txBase58 = tx
        } else {
            throw WCError.malformedParams("Invalid solana_signTransaction params: expected { transaction: string }")
        }

        // Decode base58 transaction to raw bytes
        guard let rawTxData = Base58.decode(txBase58), !rawTxData.isEmpty else {
            throw WCError.malformedParams("Invalid base58 in solana_signTransaction")
        }

        // Sign with wallet service (biometric auth + Ed25519 signing)
        let signedTx = try await walletService.signSolanaRawTransaction(rawTxData)

        // Return the signed transaction as base58 in a JSON object
        // per WC Solana spec: { signature: "<base58>", transaction: "<base58>" }
        // Some dApps only expect { transaction: "<base58>" }
        let signedBase58 = Base58.encode(signedTx)
        return AnyCodable(["transaction": signedBase58])
    }

    // MARK: - solana_signMessage

    /// WalletConnect `solana_signMessage` request params.
    ///
    /// The WC spec sends a JSON object with a `message` field containing
    /// the message as a base58-encoded string, and optionally `pubkey`.
    private struct WCSolanaSignMessageParams: Decodable {
        let message: String
        let pubkey: String?
    }

    /// Handles solana_signMessage: decode message, sign with Ed25519, return signature.
    private func handleSolanaSignMessage(
        _ request: WCSignRequest,
        walletService: WalletService
    ) async throws -> AnyCodable {
        // Parse params — WC sends { message: "<base58-encoded-msg>", pubkey: "<optional>" }
        let messageBase58: String
        if let params = try? JSONDecoder().decode(
            WCSolanaSignMessageParams.self, from: request.params
        ) {
            messageBase58 = params.message
        } else if let dict = try? JSONSerialization.jsonObject(with: request.params) as? [String: Any],
                  let msg = dict["message"] as? String {
            messageBase58 = msg
        } else {
            throw WCError.malformedParams("Invalid solana_signMessage params: expected { message: string }")
        }

        // Decode base58 message to raw bytes
        guard let messageData = Base58.decode(messageBase58) else {
            throw WCError.malformedParams("Invalid base58 in solana_signMessage")
        }

        // Sign with wallet service (biometric auth + Ed25519 signing)
        let signature = try await walletService.signSolanaMessage([UInt8](messageData))

        // Return the signature as base58 in a JSON object
        // per WC Solana spec: { signature: "<base58>" }
        let signatureBase58 = Base58.encode(Data(signature))
        return AnyCodable(["signature": signatureBase58])
    }

    // MARK: - Chain Helpers

    /// Extracts the numeric chain ID from a WC chain string (e.g., "eip155:1" -> 1).
    private static func extractEvmChainId(from chain: String) -> UInt64? {
        guard chain.hasPrefix("eip155:"),
              let idStr = chain.split(separator: ":").last else { return nil }
        return UInt64(idStr)
    }

    /// Finds the RPC URL for an EVM chain ID by looking up ChainModel configs.
    /// Returns the custom override if set, otherwise the default URL.
    private static func rpcUrl(forEvmChainId chainId: UInt64) -> String? {
        ChainModel.allChains.first { $0.evmChainId == chainId }?.activeRpcUrl
    }

    /// Parses a hex string (with or without 0x prefix) to UInt64.
    private static func hexToUInt64(_ hex: String) -> UInt64? {
        let cleaned = hex.hasPrefix("0x") || hex.hasPrefix("0X")
            ? String(hex.dropFirst(2))
            : hex
        return UInt64(cleaned, radix: 16)
    }

    // MARK: - Errors

    enum WCError: LocalizedError {
        case invalidURI
        case unsupportedMethod(String)
        case malformedParams(String)
        case chainNotSupported(String)
        case rpcError(String)
        case accountMismatch(requested: String)

        var errorDescription: String? {
            switch self {
            case .invalidURI:
                return "Invalid WalletConnect URI"
            case .unsupportedMethod(let method):
                return "Unsupported signing method: \(method)"
            case .malformedParams(let detail):
                return "Malformed request: \(detail)"
            case .chainNotSupported(let chain):
                return "Unsupported chain: \(chain)"
            case .rpcError(let detail):
                return "RPC error: \(detail)"
            case .accountMismatch(let requested):
                return "Request targets a different account (\(requested)) than the active wallet"
            }
        }
    }
}

// Make WCSessionProposal conform to Equatable for .sheet(item:)
extension WalletConnectService.WCSessionProposal: Equatable {
    static func == (lhs: WalletConnectService.WCSessionProposal, rhs: WalletConnectService.WCSessionProposal) -> Bool {
        lhs.id == rhs.id
    }
}

// Make WCSignRequest conform to Equatable for .sheet(item:)
extension WalletConnectService.WCSignRequest: Equatable {
    static func == (lhs: WalletConnectService.WCSignRequest, rhs: WalletConnectService.WCSignRequest) -> Bool {
        lhs.id == rhs.id
    }
}
