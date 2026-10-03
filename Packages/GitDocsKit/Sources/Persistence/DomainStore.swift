import Foundation
import GRDB

/// База одного домена (репозитория): `store.sqlite` в контейнере App Group (docs/02 §2).
/// Открывается и приложением (чтение статусов), и расширением (основной писатель) — WAL + busyTimeout.
public final class DomainStore: Sendable {
    public let dbPool: DatabasePool

    public static let currentSchemaVersion = 1

    public init(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        dbPool = try DatabasePool(path: url.path, configuration: config)
        try Self.migrator.migrate(dbPool)
    }

    /// Для тестов: in-memory база с той же схемой.
    public static func inMemory() throws -> DomainStore {
        try DomainStore(queue: try DatabaseQueue())
    }

    private init(queue: DatabaseQueue) throws {
        // DatabasePool требует файл; для тестов оборачиваем DatabaseQueue через временный файл.
        let url = FileManager.default.temporaryDirectory.appending(path: "gds-\(UUID().uuidString).sqlite")
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbPool = try DatabasePool(path: url.path, configuration: config)
        try Self.migrator.migrate(dbPool)
    }

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
            try db.execute(sql: "INSERT INTO meta(key, value) VALUES ('revision', '0'), ('schemaVersion', '1')")

            try db.create(table: "items") { t in
                t.column("id", .text).primaryKey()
                t.column("parent_id", .text).notNull().indexed()
                t.column("name", .text).notNull()
                t.column("path", .text).notNull().unique()
                t.column("kind", .integer).notNull()            // 0 file, 1 directory
                t.column("blob_sha", .text)
                t.column("size", .integer).notNull().defaults(to: 0)
                t.column("mode", .text).notNull().defaults(to: "100644")
                t.column("content_mtime", .double).notNull()
                t.column("meta_rev", .integer).notNull().defaults(to: 0)
                t.column("state", .integer).notNull().defaults(to: 0).indexed() // 0 synced,1 uploading,2 upload_failed,3 conflict,4 deleted_pending
                t.column("local_sha", .text)
                t.column("is_ignored", .boolean).notNull().defaults(to: false)
                t.column("created_at", .double).notNull()
                t.column("updated_at", .double).notNull()
            }
            try db.create(index: "items_parent_name", on: "items", columns: ["parent_id", "name"])

            try db.create(table: "change_log") { t in
                t.column("rev", .integer).primaryKey()
                t.column("item_id", .text).notNull()
                t.column("kind", .integer).notNull()            // 0 upsert, 1 delete
                t.column("at", .double).notNull()
            }

            try db.create(table: "pending_ops") { t in
                t.column("op_id", .text).primaryKey()
                t.column("item_id", .text).notNull().indexed()
                t.column("op", .integer).notNull()              // 0 create,1 modifyContent,2 rename,3 delete,4 mkdir
                t.column("path_before", .text)
                t.column("path_after", .text)
                t.column("staging_file", .text)
                t.column("base_blob_sha", .text)
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("last_error", .text)
                t.column("created_at", .double).notNull()
                t.column("batch_id", .text).indexed()
            }

            try db.create(table: "etag_cache") { t in
                t.column("url", .text).primaryKey()
                t.column("etag", .text).notNull()
                t.column("body", .blob)
                t.column("fetched_at", .double).notNull()
            }

            try db.create(table: "events") { t in
                t.column("id", .integer).primaryKey(autoincrement: true)
                t.column("kind", .text).notNull()                // conflict, overwritten, uploadFailed, ...
                t.column("path", .text)
                t.column("message", .text).notNull()
                t.column("at", .double).notNull()
                t.column("shown", .boolean).notNull().defaults(to: false)
            }
        }
        return migrator
    }

    // MARK: - meta helpers

    public func metaValue(_ key: String) throws -> String? {
        try dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
        }
    }

    public func setMetaValue(_ value: String, for key: String) throws {
        try dbPool.write { db in
            try db.execute(sql: "INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [key, value])
        }
    }

    public var revision: Int {
        get throws { Int(try metaValue("revision") ?? "0") ?? 0 }
    }
}
