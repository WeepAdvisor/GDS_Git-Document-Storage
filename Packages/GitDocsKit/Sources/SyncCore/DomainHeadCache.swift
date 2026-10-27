import Foundation
import Persistence

/// Читает `headSHA` из базы домена. Пул открывается один раз, когда файл уже есть.
public final class DomainHeadCache: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var store: DomainStore?

    public init(storeURL: URL) {
        url = storeURL
    }

    public func headSHA() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if store == nil {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            store = try? DomainStore(at: url)
        }
        return try? store?.metaValue("headSHA")
    }
}
