import Foundation
import Security

public struct KeychainTokenStore: TokenStore, Sendable {
    public let service: String
    public let accessGroup: String?

    public init(service: String = "GitDocumentStorage.github", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public static func fromBundle(_ bundle: Bundle = .main) -> KeychainTokenStore {
        let group = bundle.object(forInfoDictionaryKey: "GDSKeychainAccessGroup") as? String
        return KeychainTokenStore(accessGroup: group?.isEmpty == false ? group : nil)
    }

    public func token(for accountID: Account.ID) async throws -> String? {
        var query = base(accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound, accessGroup != nil {
            return try await tokenWithoutGroup(accountID)
        }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setToken(_ token: String, for accountID: Account.ID) async throws {
        try await removeToken(for: accountID)
        var query = base(accountID)
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            var fallback = base(accountID)
            fallback.removeValue(forKey: kSecAttrAccessGroup as String)
            fallback[kSecValueData as String] = Data(token.utf8)
            fallback[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let retry = SecItemAdd(fallback as CFDictionary, nil)
            if retry != errSecSuccess { throw KeychainError.status(retry) }
        }
    }

    public func removeToken(for accountID: Account.ID) async throws {
        SecItemDelete(base(accountID) as CFDictionary)
        var fallback = base(accountID)
        fallback.removeValue(forKey: kSecAttrAccessGroup as String)
        SecItemDelete(fallback as CFDictionary)
    }

    private func tokenWithoutGroup(_ accountID: Account.ID) async throws -> String? {
        var query = base(accountID)
        query.removeValue(forKey: kSecAttrAccessGroup as String)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func base(_ accountID: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

public enum KeychainError: Error { case status(OSStatus) }
