import Foundation

/// WalletConnectService provides WalletConnect v2 protocol support
/// for connecting to decentralized applications (dApps).
///
/// This is a placeholder for Phase 5 integration with the Reown (formerly WalletConnect) SDK.
/// The stub methods define the expected API surface for:
///   - Pairing with dApps via URI
///   - Approving/rejecting session proposals
///   - Handling sign requests
///   - Managing active sessions
final class WalletConnectService: ObservableObject {

    static let shared = WalletConnectService()

    @Published var activeSessions: [WCSession] = []
    @Published var pendingProposal: WCSessionProposal?
    @Published var pendingRequest: WCSignRequest?

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

    // MARK: - Pairing

    /// Initiates pairing with a dApp using a WalletConnect URI.
    ///
    /// The URI is typically obtained by scanning a QR code or clicking a deep link
    /// from a dApp. Format: wc:<topic>@2?relay-protocol=irn&symKey=<key>
    ///
    /// - Parameter uri: The WalletConnect pairing URI
    func pair(uri: String) async throws {
        // TODO: Phase 5 - Integrate Reown SDK
        // try await Pair.instance.pair(uri: WalletConnectURI(string: uri)!)
        print("[WalletConnect] Pairing with URI: \(uri)")
    }

    // MARK: - Session Management

    /// Approves a pending session proposal from a dApp.
    ///
    /// This grants the dApp access to the specified blockchain accounts
    /// for the requested methods and events.
    ///
    /// - Parameter proposal: The session proposal to approve
    func approveSession(_ proposal: WCSessionProposal) async throws {
        // TODO: Phase 5 - Integrate Reown SDK
        // Build namespaces from proposal requirements and wallet capabilities
        // let session = try await Sign.instance.approve(proposalId: proposal.id, namespaces: namespaces)
        print("[WalletConnect] Approving session: \(proposal.peerName)")
        pendingProposal = nil
    }

    /// Rejects a pending session proposal.
    ///
    /// - Parameter proposal: The session proposal to reject
    func rejectSession(_ proposal: WCSessionProposal) async throws {
        // TODO: Phase 5 - Integrate Reown SDK
        // try await Sign.instance.reject(proposalId: proposal.id, reason: .userRejected)
        print("[WalletConnect] Rejecting session: \(proposal.peerName)")
        pendingProposal = nil
    }

    /// Disconnects an active session.
    ///
    /// - Parameter session: The session to disconnect
    func disconnectSession(_ session: WCSession) async throws {
        // TODO: Phase 5 - Integrate Reown SDK
        // try await Sign.instance.disconnect(topic: session.id)
        activeSessions.removeAll { $0.id == session.id }
    }

    // MARK: - Request Handling

    /// Handles an incoming sign request from a connected dApp.
    ///
    /// This will trigger the UI to show the sign request details
    /// and ask the user to approve or reject.
    ///
    /// - Parameter request: The sign request to handle
    func handleRequest(_ request: WCSignRequest) async {
        // TODO: Phase 5 - Integrate Reown SDK
        // Parse the request method (personal_sign, eth_signTypedData, eth_sendTransaction, etc.)
        // Show approval UI to user
        await MainActor.run {
            pendingRequest = request
        }
    }

    /// Approves a pending sign request, signing the data with the wallet.
    ///
    /// - Parameter request: The sign request to approve
    func approveRequest(_ request: WCSignRequest) async throws {
        // TODO: Phase 5 - Integrate Reown SDK
        // 1. Sign the data using WalletService.signTransaction
        // 2. Send the response back via Sign.instance.respond
        print("[WalletConnect] Approving request: \(request.method)")
        pendingRequest = nil
    }

    /// Rejects a pending sign request.
    ///
    /// - Parameter request: The sign request to reject
    func rejectRequest(_ request: WCSignRequest) async throws {
        // TODO: Phase 5 - Integrate Reown SDK
        // try await Sign.instance.respond(topic: request.sessionId, response: .error(...))
        print("[WalletConnect] Rejecting request: \(request.method)")
        pendingRequest = nil
    }
}
