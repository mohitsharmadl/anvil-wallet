import Foundation
import CryptoKit

/// Native URLSession certificate pinning delegate.
///
/// Validates server certificates against pinned SHA-256 hashes of the
/// Subject Public Key Info (SPKI) DER encoding — the same format used by
/// HTTP Public Key Pinning (HPKP) and tools like OpenSSL.
///
/// Behavior:
///   - Pinned hosts: connection is allowed only if a certificate in the chain
///     matches one of the pinned SPKI hashes. Otherwise the connection is rejected.
///   - Unlisted hosts: connection is rejected (fail-closed). Only hosts explicitly
///     listed in `pinnedHashes` are reachable through this session.
///
/// To refresh pins, run: ./build-scripts/extract-spki-pins.sh
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
        // SPKI SHA-256 pins: [leaf, intermediate CA] per host.
        // Extracted via build-scripts/extract-spki-pins.sh.
        // Two pins per host ensures resilience when leaf certs rotate —
        // the intermediate CA pin acts as a backup until new leaf pins are deployed.
        // Re-run the script and update these when RPC providers rotate certificates.
        "eth-mainnet.g.alchemy.com": [
            "W6sM/g4GEabC51DlpaEW3xFc0yhTWoea3MXDmpEYplM=",  // leaf
            "kZwN96eHtZftBWrOZUsd6cA4es80n3NzSk/XtYz2EqQ=",  // intermediate CA
        ],
        "polygon-rpc.com": [
            "/mIrW1Gt1uNcoLNrRarvBDQwfGe+OTZoSzdkJ2TofI0=",
            "yDu9og255NN5GEf+Bwa9rTrqFQ0EydZ0r1FCh9TdAW4=",
        ],
        "arb1.arbitrum.io": [
            "+pxKDUvZ7AgKLlZN3lxjnt06X+Fh+baL8lkeYaA8Tyk=",
            "y7xVm0TVJNahMr2sZydE2jQH8SquXV9yLF9seROHHHU=",
        ],
        "mainnet.base.org": [
            "NvwNjhaHhYRP4vbVCXW67U0IWNBC+uJk1COQr/iZO2E=",
            "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=",
        ],
        "mainnet.optimism.io": [
            "O19TUDK7eGwG5heWJqcfMTwdNdU9O7R4UdbRdC+HqyM=",
            "OdSlmQD9NWJh4EbcOHBxkhygPwNSwA9Q91eounfbcoE=",
        ],
        "bsc-dataseed.binance.org": [
            "zEAnZpAGYJTCdatry/wqycxcC7UNByBkJ4FteO+YqV4=",
            "G9LNNAql897egYsabashkzUCTEJkWBzgoEtk8X/678c=",
        ],
        "api.avax.network": [
            "KLvBYhvR4cS5bIWqomiIKG0pkYjqWGcWnY2XgGPGys0=",
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",
        ],
        "api.mainnet-beta.solana.com": [
            "FuVSH64uQbx6kuUjzjZGuey6i0I9xs0gSAWdRYgdHmY=",
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",
        ],
        "blockstream.info": [
            "9AZIg3NfujJYTXeqbdna11kiWdkWCw/2/56Ocss5UJo=",
            "AlSQhgtJirc8ahLyekmtX+Iw+v46yPYRLJt9Cq1GlB0=",
        ],
        "rpc.sepolia.org": [
            "m7T5//RX6RgF6JZOP4Y9iZbLl9HjFX5IIzqQjoGEQxk=",
            "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=",
        ],
        "api.etherscan.io": [
            "kjWU9H91qtu39iBXltykNck8+xWT425ShPW+wFF2WTg=",  // leaf
            "a9khLOZJxlnJyrxstg/P+seiDCm+Yf3OsrXyFocBaI0=",  // intermediate CA
        ],
        // Multi-chain block explorer APIs (Etherscan family)
        // All *scan explorers share the same API interface for approval log queries.
        // Pins extracted via build-scripts/extract-spki-pins.sh — re-run on cert rotation.
        "api.polygonscan.com": [
            "a9khLOZJxlnJyrxstg/P+seiDCm+Yf3OsrXyFocBaI0=",  // intermediate CA (Cloudflare)
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",  // backup CA
        ],
        "api.arbiscan.io": [
            "a9khLOZJxlnJyrxstg/P+seiDCm+Yf3OsrXyFocBaI0=",  // intermediate CA (Cloudflare)
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",  // backup CA
        ],
        "api.basescan.org": [
            "a9khLOZJxlnJyrxstg/P+seiDCm+Yf3OsrXyFocBaI0=",  // intermediate CA (Cloudflare)
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",  // backup CA
        ],
        "api-optimistic.etherscan.io": [
            "kjWU9H91qtu39iBXltykNck8+xWT425ShPW+wFF2WTg=",  // leaf (shared with etherscan.io)
            "a9khLOZJxlnJyrxstg/P+seiDCm+Yf3OsrXyFocBaI0=",  // intermediate CA
        ],
        "api.bscscan.com": [
            "a9khLOZJxlnJyrxstg/P+seiDCm+Yf3OsrXyFocBaI0=",  // intermediate CA (Cloudflare)
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",  // backup CA
        ],
        "api.snowscan.xyz": [
            "a9khLOZJxlnJyrxstg/P+seiDCm+Yf3OsrXyFocBaI0=",  // intermediate CA (Cloudflare)
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",  // backup CA
        ],
        "api.coingecko.com": [
            "KeYcPtry8XJxY6pKt44Heq+zSIVxuSBcrqAlWDzNIAE=",  // leaf
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",  // intermediate CA
        ],
        "rpc.ankr.com": [
            "LzqRFppp98SE8LNv5ZlVeUHkujEaaEglSYIhEduyZ4A=",  // leaf
            "yDu9og255NN5GEf+Bwa9rTrqFQ0EydZ0r1FCh9TdAW4=",  // intermediate CA
        ],
        // Bridge aggregator (Socket/Bungee)
        "api.socket.tech": [
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",  // intermediate CA (Amazon)
            "yDu9og255NN5GEf+Bwa9rTrqFQ0EydZ0r1FCh9TdAW4=",  // backup CA
        ],
        // Lido staking APY API
        "eth-api.lido.fi": [
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",  // intermediate CA
            "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=",  // backup CA
        ],
        // 0x DEX aggregator API (swap quotes and execution)
        "api.0x.org": [
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",  // intermediate CA
            "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=",  // backup CA
        ],
        // Jupiter DEX aggregator API (Solana swaps)
        "quote-api.jup.ag": [
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",  // intermediate CA
            "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=",  // backup CA
        ],
        // Blockchair API (Zcash balance/UTXO/broadcast)
        "api.blockchair.com": [
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",  // intermediate CA
            "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=",  // backup CA
        ],
        // PublicNode RPC fallbacks (used when primary RPC endpoints fail)
        "ethereum.publicnode.com": [
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",
            "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=",
        ],
        "polygon-bor-rpc.publicnode.com": [
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",
            "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=",
        ],
        "arbitrum-one-rpc.publicnode.com": [
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",
            "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=",
        ],
        "base-rpc.publicnode.com": [
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",
            "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=",
        ],
        "optimism-rpc.publicnode.com": [
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",
            "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=",
        ],
        "bsc-rpc.publicnode.com": [
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",
            "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=",
        ],
        "avalanche-c-chain-rpc.publicnode.com": [
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",
            "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=",
        ],
        "solana-rpc.publicnode.com": [
            "iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",
            "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=",
        ],
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

        // Fail closed: reject connections to hosts not in our pin set.
        // Only explicitly pinned RPC hosts are allowed through this session.
        guard let expectedHashes = pinnedHashes[hostname], !expectedHashes.isEmpty else {
            completionHandler(.cancelAuthenticationChallenge, nil)
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
