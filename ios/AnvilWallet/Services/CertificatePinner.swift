import Foundation
import CryptoKit

/// Native URLSession certificate pinning delegate.
///
/// Validates server certificates against pinned SHA-256 public key hashes.
/// If no pins are configured for a hostname, default certificate validation is used.
///
/// Pin hashes should be the base64-encoded SHA-256 of the Subject Public Key Info (SPKI).
/// To extract a pin hash from a live certificate:
///   openssl s_client -connect host:443 | openssl x509 -pubkey -noout | \
///     openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64
final class CertificatePinner: NSObject, URLSessionDelegate {

    /// Pinned SHA-256 hashes keyed by hostname.
    /// Empty array = use default validation (no pinning enforced yet).
    ///
    /// TODO: Populate with real pin hashes at build time for production RPC endpoints.
    /// Example:
    ///   "eth-mainnet.g.alchemy.com": ["base64hash1", "base64hash2"],
    ///   "api.mainnet-beta.solana.com": ["base64hash1"],
    private let pinnedHashes: [String: [String]] = {
        // TODO: Populate with real pin hashes at build time for production RPC endpoints.
        // For now, all hosts fall through to default OS certificate validation.
        return [:]
    }()

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let hostname = challenge.protectionSpace.host

        // If no pins configured for this host, use default validation
        guard let expectedHashes = pinnedHashes[hostname], !expectedHashes.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Evaluate the server trust
        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Check each certificate in the chain for a matching pin
        guard let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        for certificate in certChain {
            guard let publicKey = SecCertificateCopyKey(certificate) else {
                continue
            }

            // Export the public key to DER format and compute SHA-256
            guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
                continue
            }

            let hash = SHA256.hash(data: publicKeyData)
            let hashBase64 = Data(hash).base64EncodedString()

            if expectedHashes.contains(hashBase64) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        // No pin matched — reject the connection
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
