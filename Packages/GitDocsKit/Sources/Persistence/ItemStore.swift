import Foundation
import GRDB

public final class ItemStore: Sendable {
    public static let rootID = "NSFileProviderRootContainerItemIdentifier"

    public let domain: DomainStore
    public init(domain: DomainStore) { self.domain = domain }

    public func item(id: String) throws -> StoredItem? {
        try domain.dbPool.read { db in try Self.fetchOne(db, sql: "SELECT * FROM items WHERE id = ?", arguments: [id]) }
    }

    public func item(path: String) throws -> StoredItem? {
        try domain.dbPool.read { db in try Self.fetchOne(db, sql: "SELECT * FROM items WHERE path = ?", arguments: [path]) }
    }

    public func children(parentID: String) throws -> [StoredItem] {
        try domain.dbPool.read { db in
            try Self.fetchAll(db, sql: """
                SELECT * FROM items WHERE parent_id = ? AND state != ? ORDER BY kind DESC, name COLLATE NOCASE
                """, arguments: [parentID, ItemState.deletedPending.rawValue])
        }
    }

    public func items(in states: [ItemState]) throws -> [StoredItem] {
        let list = states.map { String($0.rawValue) }.joined(separator: ",")
        return try domain.dbPool.read { db in
            try Self.fetchAll(db, sql: "SELECT * FROM items WHERE state IN (\(list))", arguments: [])
        }
    }

    public func allVisible() throws -> [StoredItem] {
        try domain.dbPool.read { db in
            try Self.fetchAll(db, sql: "SELECT * FROM items WHERE state != ? ORDER BY path", arguments: [ItemState.deletedPending.rawValue])
        }
    }

    public func revision() throws -> Int { try domain.revision }

    @discardableResult
    public func insert(_ item: StoredItem, recordChanges: Bool) throws -> StoredItem {
        try domain.dbPool.write { db in
            try Self.write(db, item)
            if recordChanges { try Self.appendChange(db, itemID: item.id, kind: 0) }
            return item
        }
    }

    public func setState(id: String, state: ItemState, localSHA: String?? = nil, recordChanges: Bool) throws {
        try domain.dbPool.write { db in
            if let localSHA {
                try db.execute(sql: "UPDATE items SET state = ?, local_sha = ?, updated_at = ? WHERE id = ?",
                               arguments: [state.rawValue, localSHA, Date().timeIntervalSince1970, id])
            } else {
                try db.execute(sql: "UPDATE items SET state = ?, updated_at = ? WHERE id = ?",
                               arguments: [state.rawValue, Date().timeIntervalSince1970, id])
            }
            if recordChanges { try Self.appendChange(db, itemID: id, kind: 0) }
        }
    }

    /// Поднять `meta_rev` и записать change_log, чтобы working set отдал элемент заново.
    public func rebroadcast(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try domain.dbPool.write { db in
            for id in ids {
                guard var item = try Self.fetchOne(db, sql: "SELECT * FROM items WHERE id = ?", arguments: [id]) else { continue }
                item.metaRev += 1
                try Self.write(db, item)
                try Self.appendChange(db, itemID: id, kind: 0)
            }
        }
    }

    /// `localSHA` == `.some(nil)` очищает колонку, `.none` не трогает.
    public func updateContent(id: String, blobSHA: String?, localSHA: String?, size: Int64, mtime: Date, state: ItemState) throws {
        try domain.dbPool.write { db in
            try db.execute(sql: """
                UPDATE items SET blob_sha = ?, local_sha = ?, size = ?, content_mtime = ?, state = ?, updated_at = ? WHERE id = ?
                """, arguments: [blobSHA, localSHA, size, mtime.timeIntervalSince1970, state.rawValue, Date().timeIntervalSince1970, id])
            try Self.appendChange(db, itemID: id, kind: 0)
        }
    }

    @discardableResult
    public func move(id: String, newParentID: String, newName: String, newPath: String) throws -> StoredItem {
        try domain.dbPool.write { db in
            guard var item = try Self.fetchOne(db, sql: "SELECT * FROM items WHERE id = ?", arguments: [id]) else {
                throw StoreError.notFound(id)
            }
            let oldPath = item.path
            item.parentID = newParentID
            item.name = newName
            item.path = newPath
            item.metaRev += 1
            try Self.write(db, item)
            if item.isDirectory {
                let descendants = try Self.fetchAll(db, sql: "SELECT * FROM items WHERE path LIKE ?", arguments: [oldPath + "/%"])
                for var child in descendants {
                    let suffix = String(child.path.dropFirst(oldPath.count))
                    child.path = newPath + suffix
                    child.metaRev += 1
                    try Self.write(db, child)
                    try Self.appendChange(db, itemID: child.id, kind: 0)
                }
            }
            try Self.appendChange(db, itemID: id, kind: 0)
            return item
        }
    }

    public func delete(id: String, recursive: Bool, recordChanges: Bool) throws {
        try domain.dbPool.write { db in
            guard let item = try Self.fetchOne(db, sql: "SELECT * FROM items WHERE id = ?", arguments: [id]) else { return }
            var ids = [item.id]
            if recursive, item.isDirectory {
                let descendants = try Self.fetchAll(db, sql: "SELECT * FROM items WHERE path LIKE ?", arguments: [item.path + "/%"])
                ids.append(contentsOf: descendants.map(\.id))
            }
            for itemID in ids {
                try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [itemID])
                if recordChanges { try Self.appendChange(db, itemID: itemID, kind: 1) }
            }
        }
    }

    public func markDeletedPending(id: String) throws {
        try setState(id: id, state: .deletedPending, recordChanges: false)
    }

    /// Полная замена дерева. Pending и ignored не удаляются.
    public func applySnapshot(_ entries: [TreeSnapshotEntry], committedAt: Date, recordChanges: Bool) throws {
        try domain.dbPool.write { db in
            var wanted: [String: TreeSnapshotEntry] = [:]
            for entry in entries where !entry.path.isEmpty {
                wanted[entry.path] = entry
                Self.addImplicitDirectories(of: entry.path, into: &wanted)
            }
            let existing = try Self.fetchAll(db, sql: "SELECT * FROM items", arguments: [])
            var byPath = Dictionary(uniqueKeysWithValues: existing.map { ($0.path, $0) })
            let ordered = wanted.keys.sorted { $0.split(separator: "/").count < $1.split(separator: "/").count }
            for path in ordered {
                guard let entry = wanted[path] else { continue }
                let name = path.split(separator: "/").last.map(String.init) ?? path
                let parentPath = path.split(separator: "/").dropLast().joined(separator: "/")
                let parentID = parentPath.isEmpty ? Self.rootID : (byPath[parentPath]?.id ?? Self.rootID)
                if var current = byPath[path] {
                    if current.state == .uploading || current.state == .deletedPending {
                        continue
                    }
                    let changed = current.blobSHA != (entry.isDirectory ? nil : entry.sha) || current.isDirectory != entry.isDirectory
                    current.parentID = parentID
                    current.name = name
                    current.isDirectory = entry.isDirectory
                    current.blobSHA = entry.isDirectory ? nil : entry.sha
                    current.size = entry.isDirectory ? 0 : entry.size
                    current.mode = entry.mode
                    current.contentMtime = committedAt
                    current.state = current.state == .uploading || current.state == .deletedPending ? current.state : .synced
                    if changed { current.metaRev += 1 }
                    try Self.write(db, current)
                    byPath[path] = current
                    if recordChanges, changed { try Self.appendChange(db, itemID: current.id, kind: 0) }
                } else {
                    let created = StoredItem(
                        id: UUID().uuidString, parentID: parentID, name: name, path: path, isDirectory: entry.isDirectory,
                        blobSHA: entry.isDirectory ? nil : entry.sha, size: entry.isDirectory ? 0 : entry.size, mode: entry.mode,
                        contentMtime: committedAt, metaRev: 0, state: .synced, localSHA: nil, isIgnored: false
                    )
                    try Self.write(db, created)
                    byPath[path] = created
                    if recordChanges { try Self.appendChange(db, itemID: created.id, kind: 0) }
                }
            }
            for item in existing where !item.isIgnored && item.state == .synced && wanted[item.path] == nil {
                try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [item.id])
                if recordChanges { try Self.appendChange(db, itemID: item.id, kind: 1) }
            }
        }
    }

    public func changes(since revision: Int) throws -> ChangePage {
        try domain.dbPool.read { db in
            let current = Int(try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'revision'") ?? "0") ?? 0
            let minimum = Int(try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'changelogMinRev'") ?? "0") ?? 0
            if revision < minimum {
                return ChangePage(upserts: [], deletedIDs: [], revision: current, expired: true)
            }
            let rows = try Row.fetchAll(db, sql: "SELECT rev, item_id, kind FROM change_log WHERE rev > ? ORDER BY rev", arguments: [revision])
            var upsertIDs: [String] = []
            var deleted: [String] = []
            for row in rows {
                let itemID: String = row["item_id"]
                let kind: Int = row["kind"]
                if kind == 1 { deleted.append(itemID) } else { upsertIDs.append(itemID) }
            }
            let uniqueUpserts = Array(NSOrderedSet(array: upsertIDs)) as? [String] ?? upsertIDs
            var items: [StoredItem] = []
            for id in uniqueUpserts {
                if let item = try Self.fetchOne(db, sql: "SELECT * FROM items WHERE id = ?", arguments: [id]) {
                    items.append(item)
                }
            }
            return ChangePage(upserts: items, deletedIDs: deleted, revision: current, expired: false)
        }
    }

    public func pruneChangeLog(keeping count: Int) throws {
        try domain.dbPool.write { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change_log") ?? 0
            guard total > count else { return }
            let cutoff = try Int.fetchOne(db, sql: "SELECT rev FROM change_log ORDER BY rev DESC LIMIT 1 OFFSET ?", arguments: [count]) ?? 0
            try db.execute(sql: "DELETE FROM change_log WHERE rev <= ?", arguments: [cutoff])
            try db.execute(sql: "INSERT INTO meta(key, value) VALUES ('changelogMinRev', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [String(cutoff + 1)])
        }
    }

    private static func addImplicitDirectories(of path: String, into wanted: inout [String: TreeSnapshotEntry]) {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return }
        var prefix = ""
        for part in parts.dropLast() {
            prefix = prefix.isEmpty ? part : prefix + "/" + part
            if wanted[prefix] == nil {
                wanted[prefix] = TreeSnapshotEntry(path: prefix, isDirectory: true, sha: "", mode: "040000", size: 0)
            }
        }
    }

    static func appendChange(_ db: Database, itemID: String, kind: Int) throws {
        let current = Int(try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'revision'") ?? "0") ?? 0
        let next = current + 1
        try db.execute(sql: "UPDATE meta SET value = ? WHERE key = 'revision'", arguments: [String(next)])
        try db.execute(sql: "INSERT INTO change_log(rev, item_id, kind, at) VALUES (?, ?, ?, ?)",
                       arguments: [next, itemID, kind, Date().timeIntervalSince1970])
    }

    static func write(_ db: Database, _ item: StoredItem) throws {
        try db.execute(sql: """
            INSERT INTO items(id, parent_id, name, path, kind, blob_sha, size, mode, content_mtime, meta_rev, state, local_sha, is_ignored, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              parent_id = excluded.parent_id, name = excluded.name, path = excluded.path, kind = excluded.kind,
              blob_sha = excluded.blob_sha, size = excluded.size, mode = excluded.mode, content_mtime = excluded.content_mtime,
              meta_rev = excluded.meta_rev, state = excluded.state, local_sha = excluded.local_sha, is_ignored = excluded.is_ignored,
              updated_at = excluded.updated_at
            """, arguments: [
                item.id, item.parentID, item.name, item.path, item.isDirectory ? 1 : 0, item.blobSHA, item.size, item.mode,
                item.contentMtime.timeIntervalSince1970, item.metaRev, item.state.rawValue, item.localSHA, item.isIgnored,
                item.contentMtime.timeIntervalSince1970, Date().timeIntervalSince1970,
            ])
    }

    static func fetchOne(_ db: Database, sql: String, arguments: StatementArguments) throws -> StoredItem? {
        guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else { return nil }
        return read(row)
    }

    static func fetchAll(_ db: Database, sql: String, arguments: StatementArguments) throws -> [StoredItem] {
        try Row.fetchAll(db, sql: sql, arguments: arguments).map(read)
    }

    static func read(_ row: Row) -> StoredItem {
        let kind: Int = row["kind"]
        let stateRaw: Int = row["state"]
        let mtime: Double = row["content_mtime"]
        return StoredItem(
            id: row["id"], parentID: row["parent_id"], name: row["name"], path: row["path"], isDirectory: kind == 1,
            blobSHA: row["blob_sha"], size: row["size"], mode: row["mode"], contentMtime: Date(timeIntervalSince1970: mtime),
            metaRev: row["meta_rev"], state: ItemState(rawValue: stateRaw) ?? .synced, localSHA: row["local_sha"], isIgnored: row["is_ignored"]
        )
    }
}

public enum StoreError: Error, Equatable {
    case notFound(String)
}
