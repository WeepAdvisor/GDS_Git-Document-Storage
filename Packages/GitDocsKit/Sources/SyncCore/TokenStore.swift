import Foundation

/// Хранилище токенов. Реализации: `KeychainTokenStore` (фаза 3), `InMemoryTokenStore` (тесты).
public protocol TokenStore: Sendable {
    func token(for accountID: Account.ID) async throws -> String?
    func setToken(_ token: String, for accountID: Account.ID) async throws
    func removeToken(for accountID: Account.ID) async throws
}

public actor InMemoryTokenStore: TokenStore {
    private var storage: [Account.ID: String] = [:]
    public init(_ initial: [Account.ID: String] = [:]) { storage = initial }
    public func token(for accountID: Account.ID) async throws -> String? { storage[accountID] }
    public func setToken(_ token: String, for accountID: Account.ID) async throws { storage[accountID] = token }
    public func removeToken(for accountID: Account.ID) async throws { storage[accountID] = nil }
}
