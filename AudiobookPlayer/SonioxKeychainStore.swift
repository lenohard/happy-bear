import Foundation
import Security
import OSLog

protocol SonioxAPIKeyStore {
    func loadKey() throws -> String?
    func saveKey(_ key: String) throws
    func clearKey() throws
}

final class KeychainSonioxAPIKeyStore: SonioxAPIKeyStore {
    private let service = "com.wdh.audiobook.soniox"
    private let account = "soniox_api_key"
    private let logger = Logger(subsystem: "com.wdh.audiobook", category: "SonioxKeychain")

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
            logger.debug("Soniox keychain load: no item found")
            return nil
        }

        guard status == errSecSuccess, let data = item as? Data else {
            logger.error("Soniox keychain load failed: status=\(status)")
            throw SonioxKeychainError.unhandledStatus(status)
        }
        logger.debug("Soniox keychain load succeeded; bytes=\(data.count)")
        return String(data: data, encoding: .utf8)
    }

    func saveKey(_ key: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw SonioxKeychainError.encodingFailure
        }
        logger.debug("Attempting Soniox key save; length=\(data.count)")

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
            logger.debug("Soniox key exists; updating")
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                logger.error("Soniox key update failed: status=\(updateStatus)")
                throw SonioxKeychainError.unhandledStatus(updateStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            logger.error("Soniox key save failed: status=\(status)")
            throw SonioxKeychainError.unhandledStatus(status)
        }
        logger.debug("Soniox key save succeeded")
    }

    func clearKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("Soniox key clear failed: status=\(status)")
            throw SonioxKeychainError.unhandledStatus(status)
        }
        logger.debug("Soniox key clear succeeded (status=\(status))")
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
