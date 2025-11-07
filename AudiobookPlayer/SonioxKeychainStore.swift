import Foundation
import Security

protocol SonioxAPIKeyStore {
    func loadKey() throws -> String?
    func saveKey(_ key: String) throws
    func clearKey() throws
}

final class KeychainSonioxAPIKeyStore: SonioxAPIKeyStore {
    private let service = "com.wdh.audiobook.soniox"
    private let account = "soniox_api_key"

    func loadKey() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = item as? Data else {
            throw SonioxKeychainError.unhandledStatus(status)
        }

        return String(data: data, encoding: .utf8)
    }

    func saveKey(_ key: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw SonioxKeychainError.encodingFailure
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw SonioxKeychainError.unhandledStatus(updateStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw SonioxKeychainError.unhandledStatus(status)
        }
    }

    func clearKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SonioxKeychainError.unhandledStatus(status)
        }
    }
}

enum SonioxKeychainError: Error {
    case encodingFailure
    case unhandledStatus(OSStatus)
}

extension SonioxKeychainError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .encodingFailure:
            return "Failed to encode Soniox API key."
        case .unhandledStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error: \(message)"
            }
            return "Keychain error (status \(status))."
        }
    }
}
