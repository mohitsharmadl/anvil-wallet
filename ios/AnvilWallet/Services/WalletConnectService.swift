import Foundation
import Combine
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

    init(url: URL) {
        self.request = URLRequest(url: url)
        self.session = URLSession(configuration: .default)
    }

    func connect() {
        task = session.webSocketTask(with: request)
        task?.resume()
        isConnected = true
        onConnect?()
        receiveMessage()
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        isConnected = false
        onDisconnect?(nil)
    }

    func write(string: String, completion: @escaping (Error?) -> Void) {
        task?.send(.string(string)) { error in
            completion(error)
        }
    }

    private func receiveMessage() {
        task?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.onText?(text)
                default:
                    break
                }
                self?.receiveMessage()
            case .failure(let error):
                self?.isConnected = false
                self?.onDisconnect?(error)
            }
        }
    }
}

/// WalletConnectService provides WalletConnect v2 protocol support
/// for connecting to decentralized applications (dApps) via the Reown SDK.
///
/// Supports:
///   - Pairing with dApps via WalletConnect URI
///   - Approving/rejecting session proposals
///   - personal_sign message signing
///   - Session management (list, disconnect)
///
/// Future: eth_sendTransaction, eth_signTypedData_v4, Solana signing
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
        let metadata = AppMetadata(
            name: "Anvil Wallet",
            description: "Self-custody crypto wallet",
            url: "https://anvilwallet.com",
            icons: ["https://anvilwallet.com/icon.png"],
            redirect: try? .init(native: "anvilwallet://", universal: nil, linkMode: false)
        )

        Networking.configure(
            groupIdentifier: "group.com.anvilwallet",
            projectId: projectId,
            socketFactory: NativeSocketFactory()
        )

        WalletKit.configure(metadata: metadata)

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

                if let eip155 = proposal.requiredNamespaces["eip155"] {
                    requiredChains = eip155.chains?.map { $0.absoluteString } ?? []
                    methods = eip155.methods.sorted()
                    events = eip155.events.sorted()
                }

                var optionalChains: [String] = []
                if let optEip155 = proposal.optionalNamespaces?["eip155"] {
                    optionalChains = optEip155.chains?.map { $0.absoluteString } ?? []
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
        guard let wcUri = WalletConnectURI(string: trimmed) else {
            throw WCError.invalidURI
        }
        try await WalletKit.instance.pair(uri: wcUri)
    }

    // MARK: - Session Management

    /// Approves a pending session proposal.
    /// Builds eip155 namespaces from the wallet's ETH address for all requested EVM chains.
    func approveSession(_ proposal: WCSessionProposal, ethAddress: String) async throws {
        // Build the account list for all requested EVM chains
        var allChains = proposal.requiredChains + proposal.optionalChains
        if allChains.isEmpty {
            allChains = ["eip155:1"] // Default to Ethereum mainnet
        }

        let accounts = allChains.compactMap { chainString -> Account? in
            guard let blockchain = Blockchain(chainString) else { return nil }
            return Account(blockchain: blockchain, address: ethAddress)
        }

        let sessionNamespaces: [String: SessionNamespace] = [
            "eip155": SessionNamespace(
                chains: accounts.map { $0.blockchain },
                accounts: accounts,
                methods: Set(["personal_sign", "eth_signTypedData", "eth_signTypedData_v4", "eth_sendTransaction"]),
                events: Set(["chainChanged", "accountsChanged"])
            )
        ]

        try await WalletKit.instance.approve(
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

    /// Supported signing methods — only sign methods we actually implement.
    private static let supportedMethods: Set<String> = ["personal_sign"]

    /// Approves a pending sign request by signing the message data.
    func approveRequest(_ request: WCSignRequest, walletService: WalletService) async throws {
        // Validate chain is EVM (eip155:*)
        guard request.chain.hasPrefix("eip155:") else {
            throw WCError.unsupportedMethod("Non-EVM chain: \(request.chain)")
        }

        // Validate method is one we actually support
        guard Self.supportedMethods.contains(request.method) else {
            throw WCError.unsupportedMethod(request.method)
        }

        let responseValue: AnyCodable

        switch request.method {
        case "personal_sign":
            // personal_sign params: [message_hex, address]
            guard let messageHex = parsePersonalSignMessage(from: request.params) else {
                throw WCError.unsupportedMethod("Malformed personal_sign params")
            }
            let messageBytes = hexToBytes(messageHex)

            // Sign using the wallet service (requires biometric auth)
            let signature = try await walletService.signMessage(messageBytes)
            responseValue = AnyCodable("0x" + signature.map { String(format: "%02x", $0) }.joined())

        default:
            throw WCError.unsupportedMethod(request.method)
        }

        let response = RPCResult.response(responseValue)
        try await WalletKit.instance.respond(
            topic: request.sessionId,
            requestId: RPCID(request.id)!,
            response: response
        )

        await MainActor.run {
            pendingRequest = nil
        }
    }

    /// Rejects a pending sign request.
    func rejectRequest(_ request: WCSignRequest) async throws {
        try await WalletKit.instance.respond(
            topic: request.sessionId,
            requestId: RPCID(request.id)!,
            response: .error(.init(code: 4001, message: "User rejected"))
        )

        await MainActor.run {
            pendingRequest = nil
        }
    }

    // MARK: - Helpers

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

    private func hexToBytes(_ hex: String) -> [UInt8] {
        let cleaned = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            if let byte = UInt8(String(cleaned[index..<nextIndex]), radix: 16) {
                bytes.append(byte)
            }
            index = nextIndex
        }
        return bytes
    }

    // MARK: - Errors

    enum WCError: LocalizedError {
        case invalidURI
        case unsupportedMethod(String)

        var errorDescription: String? {
            switch self {
            case .invalidURI:
                return "Invalid WalletConnect URI"
            case .unsupportedMethod(let method):
                return "Unsupported signing method: \(method)"
            }
        }
    }
}

// Make WCSessionProposal conform to Identifiable for .sheet(item:)
extension WalletConnectService.WCSessionProposal: @retroactive Equatable {
    static func == (lhs: WalletConnectService.WCSessionProposal, rhs: WalletConnectService.WCSessionProposal) -> Bool {
        lhs.id == rhs.id
    }
}

// Make WCSignRequest conform to Identifiable for .sheet(item:)
extension WalletConnectService.WCSignRequest: @retroactive Equatable {
    static func == (lhs: WalletConnectService.WCSignRequest, rhs: WalletConnectService.WCSignRequest) -> Bool {
        lhs.id == rhs.id
    }
}
