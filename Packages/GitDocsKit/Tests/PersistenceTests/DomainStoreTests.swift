import XCTest
import GRDB
@testable import Persistence

final class DomainStoreTests: XCTestCase {
    func testMigrationCreatesSchema() throws {
        let store = try DomainStore.inMemory()
        let tables = try store.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        for expected in ["meta", "items", "change_log", "pending_ops", "etag_cache", "events"] {
            XCTAssertTrue(tables.contains(expected), "missing table \(expected)")
        }
        XCTAssertEqual(try store.revision, 0)
        XCTAssertEqual(try store.metaValue("schemaVersion"), "1")
    }

    func testMetaUpsert() throws {
        let store = try DomainStore.inMemory()
        try store.setMetaValue("abc123", for: "headSHA")
        XCTAssertEqual(try store.metaValue("headSHA"), "abc123")
        try store.setMetaValue("def456", for: "headSHA")
        XCTAssertEqual(try store.metaValue("headSHA"), "def456")
    }

    func testOpensOnDiskWithWAL() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "gds-test-\(UUID().uuidString)")
            .appending(path: "store.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try DomainStore(at: url)
        let mode = try store.dbPool.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
        XCTAssertEqual(mode?.lowercased(), "wal")
    }
}
