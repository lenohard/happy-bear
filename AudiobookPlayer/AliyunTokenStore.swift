import Foundation
import Security

protocol AliyunOAuthTokenStore {
    func loadToken() throws -> AliyunOAuthToken?
    func saveToken(_ token: AliyunOAuthToken) throws
    func clearToken() throws
}

final class KeychainAliyunOAuthTokenStore: AliyunOAuthTokenStore {
    private let service = "com.wdh.audiobook.aliyun.oauth"
    private let account = "aliyun_oauth_token"

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    func loadToken() throws -> AliyunOAuthToken? {
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
            throw TokenStoreError.unhandledStatus(status)
        }

        return try decoder.decode(AliyunOAuthToken.self, from: data)
    }

    func saveToken(_ token: AliyunOAuthToken) throws {
        let data = try encoder.encode(token)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw TokenStoreError.unhandledStatus(updateStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw TokenStoreError.unhandledStatus(status)
        }
    }

    func clearToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.unhandledStatus(status)
        }
    }
}
