import Foundation
import Security

/// KeychainService provides secure key-value storage using the iOS Keychain.
///
/// Security settings:
///   - kSecAttrAccessibleWhenUnlockedThisDeviceOnly: data only accessible when device is unlocked
///   - kSecAttrSynchronizable: false: no iCloud Keychain sync (keys never leave the device)
///   - Uses kSecClassGenericPassword for all items
final class KeychainService {

    private let serviceName = "com.cryptowallet.keychain"

    enum KeychainError: LocalizedError {
        case duplicateItem
        case itemNotFound
        case unexpectedStatus(OSStatus)
        case encodingError
        case dataConversionError

        var errorDescription: String? {
            switch self {
            case .duplicateItem:
                return "Keychain item already exists."
            case .itemNotFound:
                return "Keychain item not found."
            case .unexpectedStatus(let status):
                return "Keychain error: \(SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error \(status)")"
            case .encodingError:
                return "Failed to encode data for Keychain storage."
            case .dataConversionError:
                return "Failed to convert Keychain data."
            }
        }
    }

    // MARK: - Save

    /// Saves data to the Keychain. If the key already exists, it is updated.
    ///
    /// - Parameters:
    ///   - key: The identifier for this Keychain item
    ///   - data: The data to store
    func save(key: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
            kSecValueData as String: data,
        ]

        // Try to add the item
        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            // Item exists, update it
            let searchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: key,
                kSecAttrSynchronizable as String: kCFBooleanFalse!,
            ]

            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]

            let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Load

    /// Loads data from the Keychain for the given key.
    ///
    /// - Parameter key: The identifier for the Keychain item
    /// - Returns: The stored data, or nil if not found
    func load(key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.dataConversionError
        }

        return data
    }

    // MARK: - Delete

    /// Deletes a Keychain item for the given key.
    ///
    /// - Parameter key: The identifier for the Keychain item
    func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Exists

    /// Checks whether a Keychain item exists for the given key.
    ///
    /// - Parameter key: The identifier to check
    /// - Returns: true if the item exists
    func exists(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
            kSecReturnData as String: kCFBooleanFalse!,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Save with Biometric Protection

    /// Saves data to the Keychain with biometric access control.
    /// The item can only be read after successful Face ID / Touch ID authentication.
    ///
    /// - Parameters:
    ///   - key: The identifier for this Keychain item
    ///   - data: The data to store
    func saveWithBiometricProtection(key: String, data: Data) throws {
        // Delete existing item first
        try? delete(key: key)

        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &error
        ) else {
            throw KeychainError.unexpectedStatus(errSecParam)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecAttrAccessControl as String: accessControl,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
