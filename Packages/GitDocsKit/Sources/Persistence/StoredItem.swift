import Foundation

public enum ItemState: Int, Sendable, Codable {
    case synced = 0
    case uploading = 1
    case uploadFailed = 2
    case conflict = 3
    case deletedPending = 4
}

public struct StoredItem: Sendable, Equatable {
    public var id: String
    public var parentID: String
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var blobSHA: String?
    public var size: Int64
    public var mode: String
    public var contentMtime: Date
    public var metaRev: Int
    public var state: ItemState
    public var localSHA: String?
    public var isIgnored: Bool

    public init(id: String, parentID: String, name: String, path: String, isDirectory: Bool, blobSHA: String?,
                size: Int64, mode: String, contentMtime: Date, metaRev: Int, state: ItemState, localSHA: String?, isIgnored: Bool) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.blobSHA = blobSHA
        self.size = size
        self.mode = mode
        self.contentMtime = contentMtime
        self.metaRev = metaRev
        self.state = state
        self.localSHA = localSHA
        self.isIgnored = isIgnored
    }

    /// Версия содержимого для File Provider: локальный git-blob SHA, пока файл не доехал, иначе серверный.
    public var contentVersion: String { localSHA ?? blobSHA ?? "0" }
}

public struct TreeSnapshotEntry: Sendable, Equatable {
    public var path: String
    public var isDirectory: Bool
    public var sha: String
    public var mode: String
    public var size: Int64

    public init(path: String, isDirectory: Bool, sha: String, mode: String, size: Int64) {
        self.path = path
        self.isDirectory = isDirectory
        self.sha = sha
        self.mode = mode
        self.size = size
    }
}

public struct ChangePage: Sendable {
    public var upserts: [StoredItem]
    public var deletedIDs: [String]
    public var revision: Int
    public var expired: Bool

    public init(upserts: [StoredItem], deletedIDs: [String], revision: Int, expired: Bool) {
        self.upserts = upserts
        self.deletedIDs = deletedIDs
        self.revision = revision
        self.expired = expired
    }
}
