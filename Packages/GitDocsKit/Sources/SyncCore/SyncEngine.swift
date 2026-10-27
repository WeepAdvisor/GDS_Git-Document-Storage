import Foundation
import Persistence

public struct ItemSnapshot: Sendable, Equatable {
    public var id: String
    public var parentID: String
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date
    public var contentVersion: String
    public var metadataRevision: Int
    public var isUploading: Bool
    public var uploadFailed: Bool
    public var readOnly: Bool
    /// `true` — в БД размер 0, но blob не пустой. File Provider при `documentSize == 0` не вызывает `fetchContents`.
    public var sizeIsUnknown: Bool

    public init(id: String, parentID: String, name: String, isDirectory: Bool, size: Int64, modified: Date,
                contentVersion: String, metadataRevision: Int, isUploading: Bool, uploadFailed: Bool = false, readOnly: Bool,
                sizeIsUnknown: Bool = false) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.contentVersion = contentVersion
        self.metadataRevision = metadataRevision
        self.isUploading = isUploading
        self.uploadFailed = uploadFailed
        self.readOnly = readOnly
        self.sizeIsUnknown = sizeIsUnknown
    }
}

public actor SyncEngine {
    public let config: RepoConfig
    public let items: ItemStore
    public let pending: PendingOpsStore
    public let remote: any RemoteRepository
    public let stagingDirectory: URL
    public var isAppAlive: @Sendable () -> Bool
    public var flushDelayNanoseconds: UInt64
    public var onDidSync: (@Sendable () -> Void)?

    private let ignore = IgnoreRules.default
    private var debounceTask: Task<Void, Never>?
    private var firstQueuedAt: Date?
    private var flushing = false
    private var flushAgain = false
    private var flushImmediately = false
    private var forwardAttempts = 0
    private var didRebroadcastUnknownSizes = false

    public func setSyncHandler(_ handler: @escaping @Sendable () -> Void) {
        onDidSync = handler
    }

    public init(config: RepoConfig, domain: DomainStore, remote: any RemoteRepository, stagingDirectory: URL,
                isAppAlive: @escaping @Sendable () -> Bool = { true }, flushDelayNanoseconds: UInt64 = 2_000_000_000) {
        self.config = config
        self.items = ItemStore(domain: domain)
        self.pending = PendingOpsStore(domain: domain)
        self.remote = remote
        self.stagingDirectory = stagingDirectory
        self.isAppAlive = isAppAlive
        self.flushDelayNanoseconds = flushDelayNanoseconds
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try? pending.releaseInFlightBatches()
    }

    /// Поднять файлы, чья выгрузка оборвалась, и снова поставить их в очередь.
    public func resumePendingUploads() {
        try? reviveStuckItems()
        if rebroadcastUnknownSizes() {
            onDidSync?()
        }
        if (try? pending.queued().isEmpty) == false {
            scheduleFlush()
        }
    }

    /// Файл виден в Finder, а очередь пустая: выгрузку отменили посередине.
    private func reviveStuckItems() throws {
        let stuck = try items.items(in: [.uploading, .deletedPending])
        let queued = Set(try pending.queued().map(\.itemID))
        for item in stuck where !queued.contains(item.id) && !item.isDirectory {
            let staging = stagingDirectory.appending(path: item.id)
            guard FileManager.default.fileExists(atPath: staging.path) else { continue }
            try items.setState(id: item.id, state: .uploading, recordChanges: false)
            try pending.enqueue(PendingOp(
                itemID: item.id,
                kind: item.blobSHA == nil ? .create : .modifyContent,
                pathBefore: item.path,
                pathAfter: item.path,
                stagingFile: staging.path,
                baseBlobSHA: item.blobSHA
            ))
        }
    }

    public var canWrite: Bool { config.mode == .readWrite }

    public func snapshot(_ item: StoredItem) -> ItemSnapshot {
        let unknown = Self.contentSizeUnknown(item)
        return ItemSnapshot(
            id: item.id, parentID: item.parentID, name: item.name, isDirectory: item.isDirectory, size: item.size,
            modified: item.contentMtime,
            contentVersion: unknown ? item.contentVersion + Self.unknownSizeSuffix : item.contentVersion,
            metadataRevision: item.metaRev,
            isUploading: item.state == .uploading, uploadFailed: item.state == .uploadFailed,
            readOnly: !canWrite || item.isIgnored, sizeIsUnknown: unknown
        )
    }

    public func snapshot(id: String) throws -> ItemSnapshot? {
        if id == ItemStore.rootID {
            return ItemSnapshot(id: id, parentID: id, name: config.displayName, isDirectory: true, size: 0, modified: Date(),
                                contentVersion: "root", metadataRevision: 0, isUploading: false, readOnly: !canWrite)
        }
        return try items.item(id: id).map(snapshot)
    }

    public func children(parentID: String) throws -> [ItemSnapshot] {
        try items.children(parentID: parentID).map(snapshot)
    }

    public func allVisible() throws -> [ItemSnapshot] { try items.allVisible().map(snapshot) }

    public func changes(since revision: Int) throws -> ChangePage { try items.changes(since: revision) }

    public func currentRevision() throws -> Int { try items.revision() }

    public func ensureInitialLoad() async throws {
        if try items.domain.metaValue("headSHA") != nil { return }
        do {
            try await pullRemote(recordInitial: false)
        } catch {
            logRemoteFailure(error)
            throw error
        }
    }

    public func pullRemote() async throws {
        do {
            try await pullRemote(recordInitial: true)
        } catch {
            logRemoteFailure(error)
            throw error
        }
    }

    public func fetchContents(itemID: String) async throws -> URL {
        try requireApp()
        guard let item = try items.item(id: itemID) else { throw SyncError.itemNotFound }
        if let local = item.localSHA {
            let staged = stagingDirectory.appending(path: item.id)
            if FileManager.default.fileExists(atPath: staged.path) { return staged }
            _ = local
        }
        guard let sha = item.blobSHA else { throw SyncError.itemNotFound }
        let destination = FileManager.default.temporaryDirectory.appending(path: "gds-\(sha)")
        if !Self.usableBlobCache(at: destination, sha: sha) {
            try? FileManager.default.removeItem(at: destination)
            let expected = item.size > 0 ? item.size : 1
            SyncActivity.setBytes(domain: config.id, direction: .download, done: 0, total: expected)
            do {
                _ = try await remote.downloadBlob(sha: sha, to: destination)
            } catch {
                SyncActivity.setBytes(domain: config.id, direction: .download, done: 0, total: 0)
                throw error
            }
        }
        let bytes = Self.fileByteCount(destination)
        if bytes == 0, sha != GitBlobSHA.empty {
            try? FileManager.default.removeItem(at: destination)
            SyncActivity.setBytes(domain: config.id, direction: .download, done: 0, total: 0)
            throw SyncError.storage("GitHub returned an empty blob")
        }
        if item.size != bytes {
            try items.updateContent(id: item.id, blobSHA: item.blobSHA, localSHA: item.localSHA, size: bytes,
                                    mtime: item.contentMtime, state: item.state)
        }
        let total = max(bytes, 1)
        SyncActivity.setBytes(domain: config.id, direction: .download, done: total, total: total)
        return destination
    }

    public func createItem(parentID: String, name: String, isDirectory: Bool, stagedCopy: URL?) async throws -> ItemSnapshot {
        try requireWritable()
        if let error = PathNormalizer.validateName(name) { throw SyncError.invalidFileName(error.localized) }
        let parentPath = try path(forParent: parentID)
        let path = parentPath.isEmpty ? PathNormalizer.normalizeName(name) : parentPath + "/" + PathNormalizer.normalizeName(name)
        if ignore.isIgnoredPath(path) {
            let item = StoredItem(id: UUID().uuidString, parentID: parentID, name: name, path: path, isDirectory: isDirectory,
                                  blobSHA: nil, size: 0, mode: isDirectory ? "040000" : "100644", contentMtime: Date(), metaRev: 0,
                                  state: .synced, localSHA: nil, isIgnored: true)
            try items.insert(item, recordChanges: false)
            return snapshot(item)
        }
        if isDirectory {
            let folder = StoredItem(id: UUID().uuidString, parentID: parentID, name: name, path: path, isDirectory: true,
                                    blobSHA: nil, size: 0, mode: "040000", contentMtime: Date(), metaRev: 0,
                                    state: .uploading, localSHA: nil, isIgnored: false)
            try items.insert(folder, recordChanges: true)
            let keepPath = path + "/.gitkeep"
            let keepID = UUID().uuidString
            let keepData = Data("\n".utf8)
            let keepURL = try writeStaging(keepData, id: keepID)
            let keep = StoredItem(id: keepID, parentID: folder.id, name: ".gitkeep", path: keepPath, isDirectory: false,
                                  blobSHA: nil, size: Int64(keepData.count), mode: "100644", contentMtime: Date(), metaRev: 0,
                                  state: .uploading, localSHA: GitBlobSHA.sha1(of: keepData), isIgnored: false)
            try items.insert(keep, recordChanges: true)
            try pending.enqueue(PendingOp(itemID: keep.id, kind: .create, pathAfter: keepPath, stagingFile: keepURL.path))
            scheduleFlush()
            return snapshot(folder)
        }
        guard let stagedCopy else { throw SyncError.storage("Missing file contents") }
        let bytes = Self.fileByteCount(stagedCopy)
        if bytes > CommitLimits.default.gitHubMaxBlobBytes {
            return try keepOversized(source: stagedCopy, parentID: parentID, name: name, path: path, bytes: bytes)
        }
        let id = UUID().uuidString
        let staged = try stageUpload(stagedCopy, path: path, id: id)
        let item = StoredItem(id: id, parentID: parentID, name: name, path: path, isDirectory: false, blobSHA: nil,
                              size: staged.size, mode: "100644", contentMtime: Date(), metaRev: 0, state: .uploading,
                              localSHA: staged.sha, isIgnored: false)
        try items.insert(item, recordChanges: true)
        try pending.enqueue(PendingOp(itemID: id, kind: .create, pathAfter: path, stagingFile: staged.url.path))
        scheduleFlush()
        return snapshot(item)
    }

    public func modifyContents(id: String, stagedCopy: URL) async throws -> ItemSnapshot {
        try requireWritable()
        guard var item = try items.item(id: id), !item.isDirectory else { throw SyncError.itemNotFound }
        let bytes = Self.fileByteCount(stagedCopy)
        if bytes > CommitLimits.default.gitHubMaxBlobBytes {
            let staged = try copyOversized(stagedCopy, id: item.id)
            item.localSHA = nil
            item.size = staged.size
            item.state = .uploadFailed
            item.contentMtime = Date()
            try items.insert(item, recordChanges: true)
            try pending.deleteQueued(itemID: item.id)
            noteOversized(id: item.id, path: item.path, bytes: staged.size)
            return snapshot(item)
        }
        let staged = try stageUpload(stagedCopy, path: item.path, id: item.id)
        item.localSHA = staged.sha
        item.size = staged.size
        item.state = .uploading
        item.contentMtime = Date()
        try items.insert(item, recordChanges: true)
        try pending.enqueue(PendingOp(itemID: item.id, kind: item.blobSHA == nil ? .create : .modifyContent,
                                      pathBefore: item.path, pathAfter: item.path, stagingFile: staged.url.path, baseBlobSHA: item.blobSHA))
        scheduleFlush()
        return snapshot(item)
    }

    public func rename(id: String, newParentID: String, newName: String) async throws -> ItemSnapshot {
        try requireWritable()
        if let error = PathNormalizer.validateName(newName) { throw SyncError.invalidFileName(error.localized) }
        guard let current = try items.item(id: id) else { throw SyncError.itemNotFound }
        let parentPath = try path(forParent: newParentID)
        let newPath = parentPath.isEmpty ? newName : parentPath + "/" + PathNormalizer.normalizeName(newName)
        if newPath == current.path && newParentID == current.parentID { return snapshot(current) }
        let oldPath = current.path
        _ = try items.move(id: id, newParentID: newParentID, newName: newName, newPath: newPath)
        if current.isDirectory {
            // Git не хранит каталоги. Пустая папка — это .gitkeep; перенос должен уехать как move файлов.
            try enqueueMovedFiles(oldPath: oldPath, newPath: newPath, folderID: id)
        } else {
            try pending.enqueue(PendingOp(itemID: id, kind: .rename, pathBefore: oldPath, pathAfter: newPath, baseBlobSHA: current.blobSHA))
            try items.setState(id: id, state: .uploading, recordChanges: true)
        }
        scheduleFlush()
        guard let fresh = try items.item(id: id) else { throw SyncError.itemNotFound }
        return snapshot(fresh)
    }

    public func delete(id: String) async throws {
        try requireWritable()
        guard let item = try items.item(id: id) else { return }
        LimitReport.remove(itemID: id)
        let victims = try descendantFiles(of: item)
        for victim in victims {
            LimitReport.remove(itemID: victim.id)
        }
        for victim in victims {
            try items.markDeletedPending(id: victim.id)
            try pending.enqueue(PendingOp(itemID: victim.id, kind: .delete, pathBefore: victim.path))
        }
        if item.isDirectory { try items.delete(id: item.id, recursive: false, recordChanges: true) }
        scheduleFlush()
    }

    /// Вытянуть удалённые изменения и сразу выгрузить очередь, без debounce.
    public func syncNow() async {
        CrashLog.mark("syncNow \(config.fullName)", process: "file-provider")
        debounceTask?.cancel()
        debounceTask = nil
        flushImmediately = true
        await flush()
    }

    public func flush() async {
        if flushing {
            flushAgain = true
            return
        }
        flushing = true
        CrashLog.mark("flush \(config.fullName)", process: "file-provider")
        defer {
            flushing = false
            CrashLog.clearMark(process: "file-provider")
            firstQueuedAt = nil
            let again = flushAgain
            let now = flushImmediately
            flushAgain = false
            if again {
                scheduleFlush(resetBackoff: false, immediate: now)
            }
            if !again || now { flushImmediately = false }
        }
        do {
            try requireApp()
            if config.mode != .readWrite { return }
            try await pullRemote()
            try expandDirectoryRenames()
            let queued = try pending.queued()
            guard !queued.isEmpty else {
                try markIdleDirectoriesSynced()
                return
            }
            let batchID = UUID().uuidString
            try pending.markBatch(batchID, opIDs: queued.map(\.opID))
            let byID = try Dictionary(uniqueKeysWithValues: items.allVisible().map { ($0.id, $0) })
            let coalesced = PendingOpsCoalescer.coalesce(queued, items: byID)
            guard !coalesced.isEmpty else {
                try pending.complete(batchID: batchID)
                try markIdleDirectoriesSynced()
                onDidSync?()
                return
            }
            let created = Set(queued.filter { $0.kind == .create }.compactMap(\.pathAfter))
            var changes: [CommitChange] = []
            for change in coalesced {
                switch change {
                case .addition(let path, let staging, let mode):
                    let url = URL(fileURLWithPath: staging)
                    let size = (try? FileManager.default.attributesOfItem(atPath: staging)[.size] as? NSNumber)?.int64Value ?? 0
                    changes.append(.addition(path: path, contentURL: url, mode: mode, size: size))
                case .deletion(let path):
                    changes.append(.deletion(path: path))
                case .move(let from, let to, let sha, let mode):
                    changes.append(.move(from: from, to: to, blobSHA: sha, mode: mode))
                }
            }
            let message = CommitMessageComposer.compose(changes: changes, createdPaths: created)
            let batchCount = Int64(changes.count)
            reportUpload(done: 0, total: batchCount)
            let result = try await commitChanges(changes, headline: message.headline, body: message.body)
            var owners: [String: String] = [:]
            for op in queued {
                if let path = op.pathAfter { owners[path] = op.itemID }
            }
            for (path, sha) in result.blobSHAs {
                if let item = try item(committedAt: path, owners: owners) {
                    try items.updateContent(id: item.id, blobSHA: sha, localSHA: nil, size: item.size, mtime: result.newHead.committedAt, state: .synced)
                }
            }
            for (path, message) in result.rejected {
                if let item = try item(committedAt: path, owners: owners) {
                    try items.setState(id: item.id, state: .uploadFailed, recordChanges: true)
                    if item.size > CommitLimits.default.gitHubMaxBlobBytes || message.localizedCaseInsensitiveContains("100 MB") {
                        noteOversized(id: item.id, path: path, bytes: item.size)
                    }
                }
                try recordEvent(kind: "uploadFailed", path: path, message: message)
            }
            for change in coalesced {
                if case .deletion(let path) = change, let item = try items.item(path: path) {
                    try items.delete(id: item.id, recursive: false, recordChanges: true)
                }
            }
            try items.domain.setMetaValue(result.newHead.commitSHA, for: "headSHA")
            try items.domain.setMetaValue(result.newHead.treeSHA, for: "headTreeSHA")
            try pending.complete(batchID: batchID)
            try markIdleDirectoriesSynced()
            forwardAttempts = 0
            let left = Int64((try? pending.queued().count) ?? 0)
            if left == 0 {
                reportUpload(done: batchCount, total: batchCount)
            } else {
                reportUpload(done: 0, total: left)
            }
            onDidSync?()
            if try !pending.queued().isEmpty { scheduleFlush(resetBackoff: false) }
        } catch let error as SyncError where error == .notFastForward {
            forwardAttempts += 1
            try? await pullRemote()
            try? pending.releaseInFlightBatches()
            if forwardAttempts < 5 {
                scheduleFlush(resetBackoff: false)
            } else {
                forwardAttempts = 0
                try? markUploadFailed(SyncError.storage("Could not fast-forward after 5 attempts"))
            }
        } catch let error as SyncError where error == .remote(.cancelled) {
            // Следующая правка того же файла отменила запрос. Операция остаётся в очереди.
            try? pending.releaseInFlightBatches()
            flushAgain = true
        } catch {
            try? pending.releaseInFlightBatches()
            try? markUploadFailed(error)
        }
    }

    private func pullRemote(recordInitial: Bool) async throws {
        try requireApp()
        let etag = try items.domain.metaValue("headETag")
        let head: RemoteHead?
        do {
            head = try await remote.head(knownETag: etag)
        } catch let error as SyncError where error == .remote(.emptyRepository) {
            return
        }
        guard let head else { return }
        if try items.domain.metaValue("headSHA") == head.commitSHA { return }
        let previous = try items.domain.metaValue("headSHA")
        if let previous, previous != head.commitSHA {
            reportDownload(done: 0, total: 1)
            let diff = try await remote.diff(from: previous, to: head.commitSHA)
            if diff.isTruncated {
                try await replaceTree(head, recordChanges: true)
            } else {
                let sizes = (try? await blobSizes(for: diff, treeSHA: head.treeSHA)) ?? [:]
                try apply(diff, committedAt: head.committedAt, sizes: sizes)
            }
        } else if previous == nil {
            try await replaceTree(head, recordChanges: recordInitial)
        }
        try items.domain.setMetaValue(head.commitSHA, for: "headSHA")
        try items.domain.setMetaValue(head.treeSHA, for: "headTreeSHA")
        if let etag = head.etag { try items.domain.setMetaValue(etag, for: "headETag") }
        onDidSync?()
    }

    private func replaceTree(_ head: RemoteHead, recordChanges: Bool) async throws {
        reportDownload(done: 0, total: 1)
        let tree = try await remote.tree(sha: head.treeSHA, recursive: true)
        let entries = tree.entries.compactMap { entry -> TreeSnapshotEntry? in
            switch entry.kind {
            case .unsupported: return nil
            case .tree:
                return TreeSnapshotEntry(path: entry.path, isDirectory: true, sha: entry.sha, mode: entry.mode, size: 0)
            case .blob:
                return TreeSnapshotEntry(path: entry.path, isDirectory: false, sha: entry.sha, mode: entry.mode, size: entry.size ?? 0)
            }
        }
        let count = Int64(max(entries.count, 1))
        reportDownload(done: 0, total: count)
        try items.applySnapshot(entries, committedAt: head.committedAt, recordChanges: recordChanges)
        reportDownload(done: count, total: count)
    }

    /// `compare` не содержит `size`. Берём его из дерева того же коммита, иначе File Provider
    /// материализует новый файл как 0 байт и больше не вызывает `fetchContents`.
    private func blobSizes(for diff: RemoteDiff, treeSHA: String) async throws -> [String: Int64] {
        let wanted = Set(diff.files.compactMap { file -> String? in
            switch file.status {
            case .added, .modified, .changed: return file.size == nil ? file.path : nil
            default: return nil
            }
        })
        guard !wanted.isEmpty else { return [:] }
        let tree = try await remote.tree(sha: treeSHA, recursive: true)
        var sizes: [String: Int64] = [:]
        for entry in tree.entries where wanted.contains(entry.path) {
            guard case .blob = entry.kind, let size = entry.size else { continue }
            sizes[entry.path] = size
        }
        return sizes
    }

    private func apply(_ diff: RemoteDiff, committedAt: Date, sizes: [String: Int64] = [:]) throws {
        let total = Int64(diff.files.count)
        if total > 0 { reportDownload(done: 0, total: total) }
        let queuedIDs = Set(try pending.queued().map(\.itemID))
        for (index, file) in diff.files.enumerated() {
            if total > 0, index % 5 == 0 {
                reportDownload(done: Int64(index), total: total)
            }
            switch file.status {
            case .added:
                if try items.item(path: file.path) != nil { continue }
                let parent = try ensureParents(of: file.path, mtime: committedAt)
                let name = PathNormalizer.fileName(of: file.path)
                let item = StoredItem(id: UUID().uuidString, parentID: parent, name: name, path: file.path, isDirectory: false,
                                      blobSHA: file.sha, size: Self.resolvedSize(file, known: sizes, fallback: 0), mode: "100644",
                                      contentMtime: committedAt, metaRev: 0, state: .synced, localSHA: nil, isIgnored: false)
                try items.insert(item, recordChanges: true)
            case .modified, .changed:
                guard let item = try items.item(path: file.path) else { continue }
                if queuedIDs.contains(item.id) {
                    let action = try conflictAction(for: item, remote: file.status, path: file.path)
                    switch action {
                    case .takeLocal, .resurrectLocal:
                        continue
                    case .conflictCopy(let copyPath):
                        if try keepLocalCopy(of: item, at: copyPath, mtime: committedAt) {
                            try items.updateContent(id: item.id, blobSHA: file.sha, localSHA: nil,
                                                     size: Self.resolvedSize(file, known: sizes, fallback: item.size), mtime: committedAt, state: .synced)
                            try recordEvent(kind: "conflict", path: file.path, message: "Kept both versions of \(file.path)")
                        }
                        continue
                    case .cancelDelete, .dropLocal, .takeRemote:
                        try pending.deleteQueued(itemID: item.id)
                    }
                }
                try items.updateContent(id: item.id, blobSHA: file.sha, localSHA: nil,
                                         size: Self.resolvedSize(file, known: sizes, fallback: item.size), mtime: committedAt, state: .synced)
            case .removed:
                guard let item = try items.item(path: file.path) else { continue }
                if queuedIDs.contains(item.id) {
                    let action = try conflictAction(for: item, remote: .removed, path: file.path)
                    switch action {
                    case .takeLocal, .resurrectLocal:
                        continue
                    case .dropLocal:
                        try pending.deleteQueued(itemID: item.id)
                        try items.delete(id: item.id, recursive: false, recordChanges: true)
                        continue
                    case .cancelDelete:
                        try pending.deleteQueued(itemID: item.id)
                        try items.setState(id: item.id, state: .synced, recordChanges: true)
                        continue
                    default:
                        continue
                    }
                }
                try items.delete(id: item.id, recursive: false, recordChanges: true)
            case .renamed:
                let previous = file.previousPath ?? file.path
                guard let item = try items.item(path: previous) else { continue }
                let parent = try ensureParents(of: file.path, mtime: committedAt)
                _ = try items.move(id: item.id, newParentID: parent, newName: PathNormalizer.fileName(of: file.path), newPath: file.path)
            case .copied, .unchanged:
                break
            }
        }
        if total > 0 { reportDownload(done: total, total: total) }
    }

    private func ensureParents(of path: String, mtime: Date) throws -> String {
        let parentPath = PathNormalizer.parentPath(of: path)
        guard !parentPath.isEmpty else { return ItemStore.rootID }
        if let existing = try items.item(path: parentPath) { return existing.id }
        let parent = try ensureParents(of: parentPath, mtime: mtime)
        let folder = StoredItem(id: UUID().uuidString, parentID: parent, name: PathNormalizer.fileName(of: parentPath), path: parentPath,
                                isDirectory: true, blobSHA: nil, size: 0, mode: "040000", contentMtime: mtime, metaRev: 0,
                                state: .synced, localSHA: nil, isIgnored: false)
        try items.insert(folder, recordChanges: true)
        return folder.id
    }

    private func commitChanges(_ changes: [CommitChange], headline: String, body: String?) async throws -> CommitResult {
        var headSHA = try items.domain.metaValue("headSHA") ?? ""
        var treeSHA = try items.domain.metaValue("headTreeSHA") ?? ""
        var remaining = changes
        var shas: [String: String] = [:]
        var rejected: [String: String] = [:]
        var committedAt = Date()
        if headSHA.isEmpty, let first = remaining.first {
            let firstResult = try await remote.commit(
                CommitRequest(changes: [first], expectedHeadSHA: "", expectedTreeSHA: "", headline: headline, body: body),
                limits: .default
            )
            shas.merge(firstResult.blobSHAs) { _, new in new }
            rejected.merge(firstResult.rejected) { _, new in new }
            headSHA = firstResult.newHead.commitSHA
            treeSHA = firstResult.newHead.treeSHA
            committedAt = firstResult.newHead.committedAt
            try items.domain.setMetaValue(headSHA, for: "headSHA")
            try items.domain.setMetaValue(treeSHA, for: "headTreeSHA")
            remaining.removeFirst()
            reportUpload(done: Int64(changes.count - remaining.count), total: Int64(changes.count))
        }
        for chunk in CommitChunks.split(remaining) {
            let piece = try await commitAllowingSplit(chunk, headSHA: &headSHA, treeSHA: &treeSHA, headline: headline, body: body)
            shas.merge(piece.shas) { _, new in new }
            rejected.merge(piece.rejected) { _, new in new }
            committedAt = piece.committedAt
            reportUpload(done: Int64(shas.count + rejected.count), total: Int64(changes.count))
        }
        return CommitResult(
            newHead: RemoteHead(commitSHA: headSHA, treeSHA: treeSHA, committedAt: committedAt),
            blobSHAs: shas,
            rejected: rejected
        )
    }

    private func commitAllowingSplit(_ chunk: [CommitChange], headSHA: inout String, treeSHA: inout String, headline: String, body: String?) async throws -> (shas: [String: String], rejected: [String: String], committedAt: Date) {
        do {
            let result = try await remote.commit(
                CommitRequest(changes: chunk, expectedHeadSHA: headSHA, expectedTreeSHA: treeSHA, headline: headline, body: body),
                limits: .default
            )
            if !result.newHead.commitSHA.isEmpty {
                headSHA = result.newHead.commitSHA
                treeSHA = result.newHead.treeSHA
                try items.domain.setMetaValue(headSHA, for: "headSHA")
                try items.domain.setMetaValue(treeSHA, for: "headTreeSHA")
            }
            return (result.blobSHAs, result.rejected, result.newHead.committedAt)
        } catch {
            guard Self.payloadTooLarge(error) else { throw error }
            if chunk.count <= 1, let path = chunk.first.flatMap(Self.changePath) {
                return ([:], [path: "GitHub rejected \(path) as too large"], Date())
            }
            let mid = max(chunk.count / 2, 1)
            let left = try await commitAllowingSplit(Array(chunk[..<mid]), headSHA: &headSHA, treeSHA: &treeSHA, headline: headline, body: body)
            let right = try await commitAllowingSplit(Array(chunk[mid...]), headSHA: &headSHA, treeSHA: &treeSHA, headline: headline, body: body)
            var shas = left.shas
            shas.merge(right.shas) { _, new in new }
            var rejected = left.rejected
            rejected.merge(right.rejected) { _, new in new }
            return (shas, rejected, right.committedAt)
        }
    }

    private static func payloadTooLarge(_ error: Error) -> Bool {
        guard let sync = error as? SyncError else { return false }
        switch sync {
        case .fileTooLarge:
            return true
        case .remote(let github):
            switch github {
            case .validation(let message):
                return message.localizedCaseInsensitiveContains("too large")
            case .graphQL(let messages):
                return messages.contains { $0.localizedCaseInsensitiveContains("too large") }
            default:
                return false
            }
        default:
            return false
        }
    }

    private static func changePath(_ change: CommitChange) -> String? {
        switch change {
        case .addition(let path, _, _, _), .deletion(let path):
            return path
        case .move(_, let to, _, _), .copy(let to, _, _):
            return to
        }
    }

    private func conflictAction(for item: StoredItem, remote: RemoteDiffEntry.Status, path: String) throws -> ConflictAction {
        let kinds = try pending.queued().filter { $0.itemID == item.id }.map(\.kind)
        let local: LocalOpKind
        if kinds.contains(.delete) { local = .delete }
        else if kinds.contains(.rename) { local = .rename }
        else if kinds.contains(.create) || kinds.contains(.mkdir) { local = .create }
        else { local = .modify }
        let login = config.accountID.split(separator: ":").last.map(String.init) ?? "me"
        return ConflictResolver.resolve(local: local, remote: remote, policy: config.conflictPolicy, path: path, login: login)
    }

    private func keepLocalCopy(of item: StoredItem, at copyPath: String, mtime: Date) throws -> Bool {
        let source = stagingDirectory.appending(path: item.id)
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        let data = try Data(contentsOf: source)
        let parent = try ensureParents(of: copyPath, mtime: mtime)
        let id = UUID().uuidString
        let stored = try writeStaging(data, id: id)
        let name = PathNormalizer.fileName(of: copyPath)
        let copy = StoredItem(
            id: id, parentID: parent, name: name, path: copyPath, isDirectory: false, blobSHA: nil,
            size: Int64(data.count), mode: item.mode, contentMtime: mtime, metaRev: 0, state: .uploading,
            localSHA: GitBlobSHA.sha1(of: data), isIgnored: false
        )
        try items.insert(copy, recordChanges: true)
        try pending.enqueue(PendingOp(itemID: id, kind: .create, pathAfter: copyPath, stagingFile: stored.path))
        try pending.deleteQueued(itemID: item.id)
        return true
    }

    private func scheduleFlush(resetBackoff: Bool = true, immediate: Bool = false) {
        if resetBackoff { forwardAttempts = 0 }
        if firstQueuedAt == nil { firstQueuedAt = Date() }
        // Не отменять уже идущую выгрузку: URLSession отмена даёт облачко с восклицательным знаком.
        if flushing {
            flushAgain = true
            if immediate { flushImmediately = true }
            return
        }
        debounceTask?.cancel()
        publishUploadQueue()
        let delay: UInt64 = {
            if immediate || flushImmediately { return 0 }
            if let start = firstQueuedAt, Date().timeIntervalSince(start) >= 10 { return 0 }
            return flushDelayNanoseconds
        }()
        if immediate || flushImmediately { flushImmediately = false }
        debounceTask = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled else { return }
            await self.flush()
        }
    }

    private func writeStaging(_ data: Data, id: String) throws -> URL {
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let url = stagingDirectory.appending(path: id)
        try data.write(to: url)
        return url
    }

    private func path(forParent parentID: String) throws -> String {
        if parentID == ItemStore.rootID { return "" }
        guard let parent = try items.item(id: parentID) else { throw SyncError.itemNotFound }
        return parent.path
    }

    private func descendantFiles(of item: StoredItem) throws -> [StoredItem] {
        if !item.isDirectory { return [item] }
        return try items.allVisible().filter { $0.path == item.path || $0.path.hasPrefix(item.path + "/") }.filter { !$0.isDirectory }
    }

    /// Путь в коммите мог остаться старым, если папку переименовали, пока выгрузка уже шла.
    private func item(committedAt path: String, owners: [String: String]) throws -> StoredItem? {
        if let item = try items.item(path: path) { return item }
        guard let id = owners[path] else { return nil }
        return try items.item(id: id)
    }

    /// Старые сборки клали rename на саму папку. У такого op нет blob, coalescer его выбрасывал и коммит не уходил.
    private func expandDirectoryRenames() throws {
        var directoryOps: [PendingOp] = []
        for op in try pending.queued() where op.kind == .rename {
            guard let item = try items.item(id: op.itemID), item.isDirectory else { continue }
            directoryOps.append(op)
        }
        let grouped = Dictionary(grouping: directoryOps, by: \.itemID)
        for (folderID, ops) in grouped {
            guard let folder = try items.item(id: folderID) else { continue }
            let oldest = ops.min { $0.createdAt < $1.createdAt }
            guard let oldPath = oldest?.pathBefore, oldPath != folder.path else {
                try pending.deleteQueued(itemID: folderID)
                continue
            }
            try enqueueMovedFiles(oldPath: oldPath, newPath: folder.path, folderID: folderID)
        }
    }

    /// Перенос каталога = move каждого файла (для пустой папки это `.gitkeep`) плюс сдвиг path_after у уже стоящих в очереди созданий.
    private func enqueueMovedFiles(oldPath: String, newPath: String, folderID: String) throws {
        guard oldPath != newPath else { return }
        try pending.retargetQueuedDestinations(from: oldPath, to: newPath)
        try pending.deleteQueued(itemID: folderID)
        guard try items.item(id: folderID) != nil else { return }
        if try descendantFiles(ofFolderPath: newPath).isEmpty {
            try enqueueGitkeep(folderID: folderID, folderPath: newPath)
        }
        let files = try descendantFiles(ofFolderPath: newPath)
        let queuedIDs = Set(try pending.queued().map(\.itemID))
        var touched = false
        for file in files {
            let suffix = String(file.path.dropFirst(newPath.count))
            let from = oldPath + suffix
            if queuedIDs.contains(file.id) {
                try items.setState(id: file.id, state: .uploading, recordChanges: true)
                touched = true
                continue
            }
            if from == file.path { continue }
            if let sha = file.blobSHA {
                try pending.enqueue(PendingOp(itemID: file.id, kind: .rename, pathBefore: from, pathAfter: file.path, baseBlobSHA: sha))
                try items.setState(id: file.id, state: .uploading, recordChanges: true)
                touched = true
            } else {
                let staging = stagingDirectory.appending(path: file.id)
                if FileManager.default.fileExists(atPath: staging.path) {
                    try pending.enqueue(PendingOp(itemID: file.id, kind: .create, pathAfter: file.path, stagingFile: staging.path))
                    try items.setState(id: file.id, state: .uploading, recordChanges: true)
                    touched = true
                }
            }
        }
        if touched {
            try items.setState(id: folderID, state: .uploading, recordChanges: true)
        }
    }

    private func descendantFiles(ofFolderPath path: String) throws -> [StoredItem] {
        try items.allVisible().filter { !$0.isDirectory && !$0.isIgnored && ($0.path == path || $0.path.hasPrefix(path + "/")) }
    }

    private func enqueueGitkeep(folderID: String, folderPath: String) throws {
        let keepPath = folderPath + "/.gitkeep"
        if try items.item(path: keepPath) != nil { return }
        let keepID = UUID().uuidString
        let keepData = Data("\n".utf8)
        let keepURL = try writeStaging(keepData, id: keepID)
        let keep = StoredItem(id: keepID, parentID: folderID, name: ".gitkeep", path: keepPath, isDirectory: false,
                              blobSHA: nil, size: Int64(keepData.count), mode: "100644", contentMtime: Date(), metaRev: 0,
                              state: .uploading, localSHA: GitBlobSHA.sha1(of: keepData), isIgnored: false)
        try items.insert(keep, recordChanges: true)
        try pending.enqueue(PendingOp(itemID: keepID, kind: .create, pathAfter: keepPath, stagingFile: keepURL.path))
    }

    private func requireWritable() throws {
        if config.mode != .readWrite { throw SyncError.readOnlyRepository }
        try requireApp()
    }

    private func requireApp() throws {
        if !isAppAlive() { throw SyncError.appNotRunning }
    }

    private func keepOversized(source: URL, parentID: String, name: String, path: String, bytes: Int64) throws -> ItemSnapshot {
        let id = UUID().uuidString
        let staged = try copyOversized(source, id: id)
        let item = StoredItem(
            id: id, parentID: parentID, name: name, path: path, isDirectory: false, blobSHA: nil,
            size: staged.size, mode: "100644", contentMtime: Date(), metaRev: 0, state: .uploadFailed,
            localSHA: nil, isIgnored: false
        )
        try items.insert(item, recordChanges: true)
        noteOversized(id: id, path: path, bytes: staged.size)
        try recordEvent(kind: "overLimit", path: path, message: "\(staged.size) bytes is over the 100 MB GitHub limit")
        return snapshot(item)
    }

    private func copyOversized(_ source: URL, id: String) throws -> (url: URL, size: Int64) {
        let bytes = Self.fileByteCount(source)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let destination = stagingDirectory.appending(path: id)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return (destination, bytes)
    }

    private func noteOversized(id: String, path: String, bytes: Int64) {
        LimitReport.record(OversizedFile(id: id, domainID: config.id, domainName: config.displayName, path: path, bytes: bytes))
    }

    private func stageUpload(_ source: URL, path: String, id: String) throws -> (url: URL, size: Int64, sha: String) {
        let bytes = Self.fileByteCount(source)
        if bytes > CommitLimits.default.gitHubMaxBlobBytes {
            throw SyncError.fileTooLarge(path: path, bytes: bytes)
        }
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let destination = stagingDirectory.appending(path: id)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        if bytes > CommitLimits.default.maxInMemoryBytes {
            try FileManager.default.copyItem(at: source, to: destination)
            return (destination, bytes, try GitBlobSHA.sha1(ofFile: destination))
        }
        let data = try Data(contentsOf: source)
        try data.write(to: destination, options: .atomic)
        return (destination, Int64(data.count), GitBlobSHA.sha1(of: data))
    }

    private static let unknownSizeSuffix = "#pending"

    /// Размер 0 при непустом blob. macOS считает такой файл скачанным и не зовёт `fetchContents`.
    static func contentSizeUnknown(_ item: StoredItem) -> Bool {
        guard !item.isDirectory, item.state == .synced, item.localSHA == nil, item.size == 0, let sha = item.blobSHA else {
            return false
        }
        return sha != GitBlobSHA.empty
    }

    private func rebroadcastUnknownSizes() -> Bool {
        if didRebroadcastUnknownSizes { return false }
        didRebroadcastUnknownSizes = true
        let ids = (try? items.allVisible().filter(Self.contentSizeUnknown).map(\.id)) ?? []
        guard !ids.isEmpty else { return false }
        do {
            try items.rebroadcast(ids: ids)
            return true
        } catch {
            return false
        }
    }

    private static func resolvedSize(_ file: RemoteDiffEntry, known: [String: Int64], fallback: Int64) -> Int64 {
        file.size ?? known[file.path] ?? fallback
    }

    private static func usableBlobCache(at url: URL, sha: String) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if sha == GitBlobSHA.empty { return true }
        return fileByteCount(url) > 0
    }

    private static func fileByteCount(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func publishUploadQueue() {
        let count = Int64((try? pending.queued().count) ?? 0)
        if count > 0 { reportUpload(done: 0, total: count) }
    }

    private func reportUpload(done: Int64, total: Int64) {
        SyncActivity.setFiles(domain: config.id, direction: .upload, done: done, total: total)
    }

    private func reportDownload(done: Int64, total: Int64) {
        SyncActivity.setFiles(domain: config.id, direction: .download, done: done, total: total)
    }

    private func markIdleDirectoriesSynced() throws {
        let pendingPaths = try pending.queued().compactMap { $0.pathAfter ?? $0.pathBefore }
        for item in try items.items(in: [.uploading]) where item.isDirectory {
            let prefix = item.path + "/"
            if pendingPaths.contains(where: { $0 == item.path || $0.hasPrefix(prefix) }) { continue }
            try items.setState(id: item.id, state: .synced, recordChanges: true)
        }
    }

    private func markUploadFailed(_ error: Error) throws {
        let failed = try items.items(in: [.uploading])
        for item in failed {
            try items.setState(id: item.id, state: .uploadFailed, recordChanges: true)
        }
        reportUpload(done: 0, total: 0)
        let listed = failed.map(\.path).joined(separator: ", ")
        let message = listed.isEmpty ? String(describing: error) : "\(error) [\(listed)]"
        try recordEvent(kind: "uploadFailed", path: failed.first?.path, message: message)
        onDidSync?()
    }

    private func logRemoteFailure(_ error: Error) {
        if case SyncError.remote(.emptyRepository) = error { return }
        if case SyncError.remote(.cancelled) = error { return }
        ProblemLog.record(kind: "downloadFailed", message: String(describing: error), domain: config.fullName)
    }

    private func recordEvent(kind: String, path: String?, message: String) throws {
        try items.domain.dbPool.write { db in
            try db.execute(sql: "INSERT INTO events(kind, path, message, at, shown) VALUES (?, ?, ?, ?, 0)",
                           arguments: [kind, path, message, Date().timeIntervalSince1970])
        }
        ProblemLog.record(kind: kind, message: message, path: path, domain: config.fullName)
    }
}

extension PathNormalizer.ValidationError {
    var localized: String {
        switch self {
        case .empty: return "Empty name"
        case .containsNUL: return "Name contains NUL"
        case .dotOrDotDot: return "Reserved name"
        case .gitDirectory: return ".git is not allowed"
        case .trailingSpaceOrDot: return "Name ends with a space or a dot"
        case .tooLong: return "Name is too long"
        }
    }
}
