import Foundation
import Security
import CryptoKit
import LocalAuthentication

/// SecureEnclaveService provides hardware-backed cryptographic operations
/// using the Secure Enclave on iOS devices.
///
/// The Secure Enclave is a hardware security module (HSM) built into Apple chips
/// that stores cryptographic keys in a way that they can never be extracted --
/// even if the main processor is compromised.
///
/// This service uses P-256 (NIST) elliptic curve keys stored in the Secure Enclave
/// to provide an additional encryption layer on top of the Rust-side password encryption.
///
/// On the simulator (no SE hardware), it falls back to software CryptoKit P-256 keys.
final class SecureEnclaveService {

    private let keyTag = "com.cryptowallet.secureenclave.key"

    enum SecureEnclaveError: LocalizedError {
        case keyCreationFailed(String)
        case keyNotFound
        case encryptionFailed(String)
        case decryptionFailed(String)
        case secureEnclaveUnavailable

        var errorDescription: String? {
            switch self {
            case .keyCreationFailed(let reason):
                return "Secure Enclave key creation failed: \(reason)"
            case .keyNotFound:
                return "Secure Enclave key not found."
            case .encryptionFailed(let reason):
                return "Secure Enclave encryption failed: \(reason)"
            case .decryptionFailed(let reason):
                return "Secure Enclave decryption failed: \(reason)"
            case .secureEnclaveUnavailable:
                return "Secure Enclave is not available on this device."
            }
        }
    }

    // MARK: - Key Management

    /// Creates a new P-256 key in the Secure Enclave with biometric protection.
    ///
    /// The key is created with `.biometryCurrentSet` access control, meaning:
    ///   - User must authenticate with Face ID / Touch ID to use the key
    ///   - If biometric enrollment changes (new fingerprint added), key is invalidated
    ///
    /// On simulator, creates a software CryptoKit key instead.
    ///
    /// - Returns: The SecKey reference (on device) or stores internally (on simulator)
    @discardableResult
    func createKey() throws -> SecKey {
        // Delete any existing key first
        deleteKey()

        #if targetEnvironment(simulator)
        return try createSoftwareKey()
        #else
        return try createSecureEnclaveKey()
        #endif
    }

    /// Retrieves the existing Secure Enclave key.
    ///
    /// - Returns: The SecKey reference
    func getKey() throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecReturnRef as String: true,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess, let key = item else {
            throw SecureEnclaveError.keyNotFound
        }

        // swiftlint:disable:next force_cast
        return key as! SecKey
    }

    /// Deletes the Secure Enclave key.
    func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Encryption

    /// Encrypts data using the Secure Enclave's public key (ECIES).
    ///
    /// This performs elliptic curve integrated encryption:
    ///   1. Generates an ephemeral key pair
    ///   2. Performs ECDH with the SE public key
    ///   3. Derives a symmetric key from the shared secret
    ///   4. Encrypts the data with AES-GCM
    ///
    /// - Parameters:
    ///   - data: The plaintext data to encrypt
    ///   - key: Optional SecKey to use (defaults to stored key)
    /// - Returns: The encrypted data (ephemeral public key + nonce + ciphertext + tag)
    func encrypt(data: Data, using key: SecKey? = nil) throws -> Data {
        let encryptionKey = try key ?? getKey()

        guard let publicKey = SecKeyCopyPublicKey(encryptionKey) else {
            throw SecureEnclaveError.encryptionFailed("Could not get public key")
        }

        var error: Unmanaged<CFError>?
        guard let encryptedData = SecKeyCreateEncryptedData(
            publicKey,
            .eciesEncryptionCofactorVariableIVX963SHA256AESGCM,
            data as CFData,
            &error
        ) else {
            let errorMessage = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            throw SecureEnclaveError.encryptionFailed(errorMessage)
        }

        return encryptedData as Data
    }

    // MARK: - Decryption

    /// Decrypts data using the Secure Enclave's private key.
    ///
    /// This triggers biometric authentication because the SE private key
    /// was created with `.biometryCurrentSet` access control.
    ///
    /// - Parameter data: The encrypted data to decrypt
    /// - Returns: The decrypted plaintext data
    func decrypt(data: Data) throws -> Data {
        let decryptionKey = try getKey()

        var error: Unmanaged<CFError>?
        guard let decryptedData = SecKeyCreateDecryptedData(
            decryptionKey,
            .eciesEncryptionCofactorVariableIVX963SHA256AESGCM,
            data as CFData,
            &error
        ) else {
            let errorMessage = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            throw SecureEnclaveError.decryptionFailed(errorMessage)
        }

        return decryptedData as Data
    }

    // MARK: - Private Helpers

    private func createSecureEnclaveKey() throws -> SecKey {
        var error: Unmanaged<CFError>?

        // Access control: biometric authentication required for private key operations
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            &error
        ) else {
            let errorMessage = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            throw SecureEnclaveError.keyCreationFailed(errorMessage)
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
                kSecAttrAccessControl as String: accessControl,
            ] as [String: Any],
        ]

        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let errorMessage = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            throw SecureEnclaveError.keyCreationFailed(errorMessage)
        }

        return privateKey
    }

    /// Simulator fallback: creates a regular (non-SE) P-256 key via the Keychain.
    private func createSoftwareKey() throws -> SecKey {
        var error: Unmanaged<CFError>?

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ] as [String: Any],
        ]

        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let errorMessage = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            throw SecureEnclaveError.keyCreationFailed(errorMessage)
        }

        return privateKey
    }
}
