import Foundation
import GRDB

public enum PendingKind: Int, Sendable, Codable {
    case create = 0
    case modifyContent = 1
    case rename = 2
    case delete = 3
    case mkdir = 4
}

public struct PendingOp: Sendable, Equatable {
    public var opID: String
    public var itemID: String
    public var kind: PendingKind
    public var pathBefore: String?
    public var pathAfter: String?
    public var stagingFile: String?
    public var baseBlobSHA: String?
    public var createdAt: Date
    public var batchID: String?

    public init(opID: String = UUID().uuidString, itemID: String, kind: PendingKind, pathBefore: String? = nil,
                pathAfter: String? = nil, stagingFile: String? = nil, baseBlobSHA: String? = nil,
                createdAt: Date = Date(), batchID: String? = nil) {
        self.opID = opID
        self.itemID = itemID
        self.kind = kind
        self.pathBefore = pathBefore
        self.pathAfter = pathAfter
        self.stagingFile = stagingFile
        self.baseBlobSHA = baseBlobSHA
        self.createdAt = createdAt
        self.batchID = batchID
    }
}

public enum CoalescedChange: Sendable, Equatable {
    case addition(path: String, stagingFile: String, mode: String)
    case deletion(path: String)
    case move(from: String, to: String, blobSHA: String, mode: String)
}

public struct PendingOpsCoalescer {
    /// Сворачивает очередь одного батча. `items` — состояние до применения очереди (серверные пути и SHA).
    public static func coalesce(_ ops: [PendingOp], items: [String: StoredItem]) -> [CoalescedChange] {
        struct Acc {
            var created = false
            var deleted = false
            var staging: String?
            var mode: String
            var originalPath: String
            var currentPath: String
            var blobSHA: String?
        }
        var state: [String: Acc] = [:]
        for op in ops.sorted(by: { $0.createdAt < $1.createdAt }) {
            let item = items[op.itemID]
            var acc = state[op.itemID] ?? Acc(
                mode: item?.mode ?? "100644",
                originalPath: op.pathBefore ?? op.pathAfter ?? item?.path ?? "",
                currentPath: op.pathAfter ?? op.pathBefore ?? item?.path ?? "",
                blobSHA: item?.blobSHA
            )
            switch op.kind {
            case .create, .mkdir:
                acc.created = true
                acc.deleted = false
                if let path = op.pathAfter { acc.currentPath = path; if acc.originalPath.isEmpty { acc.originalPath = path } }
                if let staging = op.stagingFile { acc.staging = staging }
            case .modifyContent:
                acc.deleted = false
                if let staging = op.stagingFile { acc.staging = staging }
                if let path = op.pathAfter { acc.currentPath = path }
            case .rename:
                if let path = op.pathAfter { acc.currentPath = path }
            case .delete:
                if acc.created {
                    state[op.itemID] = nil
                    continue
                }
                acc.deleted = true
            }
            state[op.itemID] = acc
        }
        var changes: [CoalescedChange] = []
        for acc in state.values.sorted(by: { $0.currentPath < $1.currentPath }) {
            if acc.deleted {
                changes.append(.deletion(path: acc.originalPath))
                continue
            }
            let moved = acc.currentPath != acc.originalPath && !acc.created
            if let staging = acc.staging {
                if moved { changes.append(.deletion(path: acc.originalPath)) }
                changes.append(.addition(path: acc.currentPath, stagingFile: staging, mode: acc.mode))
            } else if moved, let sha = acc.blobSHA {
                changes.append(.move(from: acc.originalPath, to: acc.currentPath, blobSHA: sha, mode: acc.mode))
            } else if acc.created, acc.currentPath.hasSuffix("/.gitkeep") || acc.mode == "040000" {
                continue
            }
        }
        return changes
    }
}

public final class PendingOpsStore: Sendable {
    public let domain: DomainStore
    public init(domain: DomainStore) { self.domain = domain }

    public func enqueue(_ op: PendingOp) throws {
        try domain.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO pending_ops(op_id, item_id, op, path_before, path_after, staging_file, base_blob_sha, attempts, created_at, batch_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                """, arguments: [op.opID, op.itemID, op.kind.rawValue, op.pathBefore, op.pathAfter, op.stagingFile, op.baseBlobSHA, op.createdAt.timeIntervalSince1970, op.batchID])
        }
    }

    public func queued() throws -> [PendingOp] {
        try domain.dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pending_ops WHERE batch_id IS NULL ORDER BY created_at").map(Self.read)
        }
    }

    public func releaseInFlightBatches() throws {
        try domain.dbPool.write { db in
            try db.execute(sql: "UPDATE pending_ops SET batch_id = NULL WHERE batch_id IS NOT NULL")
        }
    }

    public func markBatch(_ batchID: String, opIDs: [String]) throws {
        try domain.dbPool.write { db in
            for id in opIDs {
                try db.execute(sql: "UPDATE pending_ops SET batch_id = ? WHERE op_id = ?", arguments: [batchID, id])
            }
        }
    }

    public func complete(batchID: String) throws {
        try domain.dbPool.write { db in
            try db.execute(sql: "DELETE FROM pending_ops WHERE batch_id = ?", arguments: [batchID])
        }
    }

    public func deleteQueued(itemID: String) throws {
        try domain.dbPool.write { db in
            try db.execute(sql: "DELETE FROM pending_ops WHERE item_id = ? AND batch_id IS NULL", arguments: [itemID])
        }
    }

    /// Переписать путь назначения у ещё не отправленных операций. `path_before` не трогаем:
    /// это путь на сервере, с него потом делается deletion/move.
    public func retargetQueuedDestinations(from oldPrefix: String, to newPrefix: String) throws {
        guard oldPrefix != newPrefix, !oldPrefix.isEmpty else { return }
        try domain.dbPool.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT op_id, path_after FROM pending_ops WHERE batch_id IS NULL AND path_after IS NOT NULL
                """)
            for row in rows {
                let opID: String = row["op_id"]
                let after: String = row["path_after"]
                let updated = Self.rebase(after, from: oldPrefix, to: newPrefix)
                if updated == after { continue }
                try db.execute(sql: "UPDATE pending_ops SET path_after = ? WHERE op_id = ?", arguments: [updated, opID])
            }
        }
    }

    static func rebase(_ path: String, from oldPrefix: String, to newPrefix: String) -> String {
        if path == oldPrefix { return newPrefix }
        let boundary = oldPrefix + "/"
        guard path.hasPrefix(boundary) else { return path }
        return newPrefix + String(path.dropFirst(oldPrefix.count))
    }

    public func fail(batchID: String, message: String) throws {
        try domain.dbPool.write { db in
            try db.execute(sql: "UPDATE pending_ops SET batch_id = NULL, attempts = attempts + 1, last_error = ? WHERE batch_id = ?",
                           arguments: [message, batchID])
        }
    }

    private static func read(_ row: Row) -> PendingOp {
        let kindRaw: Int = row["op"]
        let created: Double = row["created_at"]
        return PendingOp(
            opID: row["op_id"], itemID: row["item_id"], kind: PendingKind(rawValue: kindRaw) ?? .modifyContent,
            pathBefore: row["path_before"], pathAfter: row["path_after"], stagingFile: row["staging_file"],
            baseBlobSHA: row["base_blob_sha"], createdAt: Date(timeIntervalSince1970: created), batchID: row["batch_id"]
        )
    }
}
