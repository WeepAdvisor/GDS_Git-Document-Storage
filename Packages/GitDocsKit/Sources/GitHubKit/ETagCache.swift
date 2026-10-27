import Foundation

public protocol ETagCache: Sendable {
    func etag(for key: String) async -> String?
    func body(for key: String) async -> Data?
    func store(key: String, etag: String, body: Data) async
}

public actor InMemoryETagCache: ETagCache {
    private var entries: [String: (etag: String, body: Data)] = [:]
    public init() {}
    public func etag(for key: String) async -> String? { entries[key]?.etag }
    public func body(for key: String) async -> Data? { entries[key]?.body }
    public func store(key: String, etag: String, body: Data) async { entries[key] = (etag, body) }
}
