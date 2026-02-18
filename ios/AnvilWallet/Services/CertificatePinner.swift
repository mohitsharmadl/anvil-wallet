import Foundation
import CryptoKit

/// Native URLSession certificate pinning delegate.
///
/// Validates server certificates against pinned SHA-256 hashes of the
/// Subject Public Key Info (SPKI) DER encoding — the same format used by
/// HTTP Public Key Pinning (HPKP) and tools like OpenSSL.
///
/// If no pins are configured for a hostname, default OS certificate validation
/// is used (no pinning enforced). This is the current state — pin hashes must
/// be populated before pinning is active.
///
/// To extract an SPKI pin hash from a live certificate:
///   openssl s_client -connect host:443 </dev/null 2>/dev/null | \
///     openssl x509 -pubkey -noout | \
///     openssl pkey -pubin -outform der | \
///     openssl dgst -sha256 -binary | base64
final class CertificatePinner: NSObject, URLSessionDelegate {

    /// Set to true after adding real SPKI pin hashes below.
    /// The release blocker script (verify-release-blockers.sh) checks for this sentinel.
    static let pinningConfigured = true

    /// Pinned SHA-256 SPKI hashes keyed by hostname.
    /// Empty dictionary = no pinning enforced (all hosts use default validation).
    ///
    /// To enable pinning:
    ///   1. Run: ./build-scripts/extract-spki-pins.sh
    ///   2. Add entries with at least 2 pins per host (primary + backup CA)
    ///   3. Set pinningConfigured = true above
    ///
    /// Example:
    ///   "eth-mainnet.g.alchemy.com": ["primary_hash=", "backup_hash="],
    private let pinnedHashes: [String: [String]] = [
        // Primary SPKI SHA-256 pins extracted via build-scripts/extract-spki-pins.sh.
        // Re-run the script and update these when RPC providers rotate certificates.
        "eth-mainnet.g.alchemy.com": ["W6sM/g4GEabC51DlpaEW3xFc0yhTWoea3MXDmpEYplM="],
        "polygon-rpc.com": ["/mIrW1Gt1uNcoLNrRarvBDQwfGe+OTZoSzdkJ2TofI0="],
        "arb1.arbitrum.io": ["+pxKDUvZ7AgKLlZN3lxjnt06X+Fh+baL8lkeYaA8Tyk="],
        "mainnet.base.org": ["NvwNjhaHhYRP4vbVCXW67U0IWNBC+uJk1COQr/iZO2E="],
        "mainnet.optimism.io": ["O19TUDK7eGwG5heWJqcfMTwdNdU9O7R4UdbRdC+HqyM="],
        "bsc-dataseed.binance.org": ["zEAnZpAGYJTCdatry/wqycxcC7UNByBkJ4FteO+YqV4="],
        "api.avax.network": ["KLvBYhvR4cS5bIWqomiIKG0pkYjqWGcWnY2XgGPGys0="],
        "api.mainnet-beta.solana.com": ["FuVSH64uQbx6kuUjzjZGuey6i0I9xs0gSAWdRYgdHmY="],
        "blockstream.info": ["9AZIg3NfujJYTXeqbdna11kiWdkWCw/2/56Ocss5UJo="],
        "rpc.sepolia.org": ["m7T5//RX6RgF6JZOP4Y9iZbLl9HjFX5IIzqQjoGEQxk="],
    ]

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

        // If no pins configured for this host, use default OS validation
        guard let expectedHashes = pinnedHashes[hostname], !expectedHashes.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Evaluate the certificate chain first (standard TLS validation)
        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Check each certificate in the chain for a matching SPKI pin
        guard let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        for certificate in certChain {
            // Get the full certificate DER data, then extract the SPKI
            // by hashing the public key in DER form (same as OpenSSL pipeline above).
            guard let publicKey = SecCertificateCopyKey(certificate),
                  let spkiData = spkiDER(for: publicKey) else {
                continue
            }

            let hash = SHA256.hash(data: spkiData)
            let hashBase64 = Data(hash).base64EncodedString()

            if expectedHashes.contains(hashBase64) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        // No pin matched — reject the connection
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    // MARK: - SPKI DER Extraction

    /// Constructs the SPKI DER encoding for a public key.
    ///
    /// SecKeyCopyExternalRepresentation returns raw key bytes (no ASN.1 wrapper).
    /// To match OpenSSL SPKI pins, we need to prepend the correct ASN.1 header
    /// for the key type, producing a full SubjectPublicKeyInfo DER structure.
    private func spkiDER(for publicKey: SecKey) -> Data? {
        guard let rawKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            return nil
        }

        let keyType = SecKeyCopyAttributes(publicKey) as? [String: Any]
        let keySize = keyType?[kSecAttrKeySizeInBits as String] as? Int ?? 0
        let algorithm = keyType?[kSecAttrKeyType as String] as? String ?? ""

        // Select the correct ASN.1 header based on key type
        let header: Data
        if algorithm == kSecAttrKeyTypeRSA as String {
            // RSA SPKI header depends on key size
            header = rsaSpkiHeader(keySize: keySize, rawKeyLength: rawKeyData.count)
        } else if algorithm == kSecAttrKeyTypeECSECPrimeRandom as String {
            // ECDSA P-256 or P-384
            if keySize == 256 {
                // ASN.1 header for P-256 SPKI (26 bytes)
                header = Data([
                    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86,
                    0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A,
                    0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03,
                    0x42, 0x00
                ])
            } else if keySize == 384 {
                // ASN.1 header for P-384 SPKI (23 bytes)
                header = Data([
                    0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2A, 0x86,
                    0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x05, 0x2B,
                    0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00
                ])
            } else {
                return nil
            }
        } else {
            // Unknown key type — cannot construct SPKI
            return nil
        }

        return header + rawKeyData
    }

    /// Constructs the ASN.1 SEQUENCE header for an RSA SPKI.
    /// The header wraps: SEQUENCE { AlgorithmIdentifier, BIT STRING { raw key } }
    private func rsaSpkiHeader(keySize: Int, rawKeyLength: Int) -> Data {
        // RSA AlgorithmIdentifier OID (1.2.840.113549.1.1.1) + NULL params
        let algorithmIdentifier: [UInt8] = [
            0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86,
            0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00
        ]

        // BIT STRING: 0x00 padding byte + raw key
        let bitStringContentLength = 1 + rawKeyLength
        var bitStringHeader = Data([0x03])
        bitStringHeader.append(contentsOf: asn1LengthBytes(bitStringContentLength))
        bitStringHeader.append(0x00) // no unused bits

        // Outer SEQUENCE length
        let sequenceContentLength = algorithmIdentifier.count + bitStringHeader.count + rawKeyLength
        var header = Data([0x30])
        header.append(contentsOf: asn1LengthBytes(sequenceContentLength))
        header.append(contentsOf: algorithmIdentifier)
        header.append(bitStringHeader)

        return header
    }

    /// Encodes a length value in ASN.1 DER format.
    private func asn1LengthBytes(_ length: Int) -> [UInt8] {
        if length < 0x80 {
            return [UInt8(length)]
        } else if length < 0x100 {
            return [0x81, UInt8(length)]
        } else {
            return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
        }
    }
}
