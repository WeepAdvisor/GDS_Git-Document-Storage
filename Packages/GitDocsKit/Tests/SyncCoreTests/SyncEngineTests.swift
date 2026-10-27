import XCTest
@testable import Persistence
@testable import SyncCore

final class ConflictResolverTests: XCTestCase {
    func testLastWriterWinsKeepsLocalEdit() {
        let action = ConflictResolver.resolve(local: .modify, remote: .modified, policy: .lastWriterWins, path: "a.txt", login: "me")
        XCTAssertEqual(action, .takeLocal)
    }

    func testKeepBothNamesACopy() {
        let action = ConflictResolver.resolve(local: .modify, remote: .modified, policy: .keepBoth, path: "docs/a.txt", login: "me",
                                              now: Date(timeIntervalSince1970: 1_700_000_000))
        guard case let .conflictCopy(name) = action else {
            return XCTFail("expected a conflict copy")
        }
        XCTAssertTrue(name.hasPrefix("docs/a (conflicted copy me "))
        XCTAssertTrue(name.hasSuffix(".txt"))
    }

    func testDeleteLosesToRemoteEdit() {
        XCTAssertEqual(
            ConflictResolver.resolve(local: .delete, remote: .modified, policy: .lastWriterWins, path: "a.txt", login: "me"),
            .cancelDelete
        )
    }

    func testSecondCopyInTheSameMinuteGetsASuffix() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = ConflictResolver.copyName(path: "a.txt", login: "me", now: now, taken: [])
        let second = ConflictResolver.copyName(path: "a.txt", login: "me", now: now, taken: [first])
        XCTAssertTrue(second.contains(" 2"))
    }
}

final class SyncEngineTests: XCTestCase {
    func testCreateFlushesOneCommit() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gds-engine-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DomainStore(at: directory.appending(path: "store.sqlite"))
        let remote = MockRemote()
        let config = RepoConfig(owner: "o", repo: "r", branch: "main", accountID: "github.com:me", displayName: "Docs")
        let engine = SyncEngine(config: config, domain: store, remote: remote, stagingDirectory: directory.appending(path: "staging"), flushDelayNanoseconds: 60_000_000_000)
        let file = directory.appending(path: "hello.txt")
        try Data("hello".utf8).write(to: file)
        _ = try await engine.createItem(parentID: ItemStore.rootID, name: "hello.txt", isDirectory: false, stagedCopy: file)
        await engine.flush()
        let committed = await remote.paths()
        XCTAssertEqual(committed["hello.txt"], Data("hello".utf8))
        let children = try await engine.children(parentID: ItemStore.rootID)
        XCTAssertEqual(children.map(\.name), ["hello.txt"])
        XCTAssertEqual(children.first?.isUploading, false)
    }

    func testSyncNowFlushesWithoutWaitingForDebounce() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gds-engine-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DomainStore(at: directory.appending(path: "store.sqlite"))
        let remote = MockRemote()
        let config = RepoConfig(owner: "o", repo: "r", branch: "main", accountID: "github.com:me", displayName: "Docs")
        let engine = SyncEngine(config: config, domain: store, remote: remote, stagingDirectory: directory.appending(path: "staging"), flushDelayNanoseconds: 60_000_000_000)
        let file = directory.appending(path: "now.txt")
        try Data("now".utf8).write(to: file)
        _ = try await engine.createItem(parentID: ItemStore.rootID, name: "now.txt", isDirectory: false, stagedCopy: file)
        await engine.syncNow()
        let committed = await remote.paths()
        XCTAssertEqual(committed["now.txt"], Data("now".utf8))
    }

    func testRenamingEmptyFolderBeforeFlushCommitsTheNewName() async throws {
        let (engine, remote, directory) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = try await engine.createItem(parentID: ItemStore.rootID, name: "untitled folder", isDirectory: true, stagedCopy: nil)
        let renamed = try await engine.rename(id: folder.id, newParentID: ItemStore.rootID, newName: "Photos")
        XCTAssertEqual(renamed.name, "Photos")
        XCTAssertTrue(renamed.isUploading)
        await engine.flush()
        let committed = await remote.paths()
        XCTAssertEqual(Set(committed.keys), ["Photos/.gitkeep"])
        let snapshot = try await engine.snapshot(id: folder.id)
        XCTAssertEqual(snapshot?.name, "Photos")
        XCTAssertEqual(snapshot?.isUploading, false)
        XCTAssertEqual(snapshot?.uploadFailed, false)
        let keep = try await engine.children(parentID: folder.id)
        XCTAssertEqual(keep.map(\.uploadFailed), [false])
        XCTAssertEqual(keep.map(\.isUploading), [false])
    }

    func testRenamingSyncedFolderMovesChildren() async throws {
        let (engine, remote, directory) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = try await engine.createItem(parentID: ItemStore.rootID, name: "Box", isDirectory: true, stagedCopy: nil)
        let file = directory.appending(path: "note.txt")
        try Data("note".utf8).write(to: file)
        _ = try await engine.createItem(parentID: folder.id, name: "note.txt", isDirectory: false, stagedCopy: file)
        await engine.flush()
        _ = try await engine.rename(id: folder.id, newParentID: ItemStore.rootID, newName: "Crate")
        await engine.flush()
        let committed = await remote.paths()
        XCTAssertEqual(Set(committed.keys), ["Crate/.gitkeep", "Crate/note.txt"])
        XCTAssertEqual(committed["Crate/note.txt"], Data("note".utf8))
        let snapshot = try await engine.snapshot(id: folder.id)
        XCTAssertEqual(snapshot?.uploadFailed, false)
        XCTAssertEqual(snapshot?.isUploading, false)
    }

    func testIncrementalAddTakesSizeFromTree() async throws {
        let (engine, remote, directory) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Data("# Pricing\n".utf8)
        let sha = GitBlobSHA.sha1(of: body)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        await remote.use(
            head: RemoteHead(commitSHA: "c1", treeSHA: "t1", committedAt: when),
            tree: RemoteTree(entries: [
                RemoteTreeEntry(path: "README.md", kind: .blob, sha: GitBlobSHA.empty, mode: "100644", size: 0),
            ], truncated: false)
        )
        try await engine.pullRemote()

        await remote.use(
            head: RemoteHead(commitSHA: "c2", treeSHA: "t2", committedAt: when),
            tree: RemoteTree(entries: [
                RemoteTreeEntry(path: "README.md", kind: .blob, sha: GitBlobSHA.empty, mode: "100644", size: 0),
                RemoteTreeEntry(path: "Materials/Competitors/Pricing index.md", kind: .blob, sha: sha, mode: "100644", size: Int64(body.count)),
            ], truncated: false),
            diff: RemoteDiff(
                baseSHA: "c1", headSHA: "c2",
                files: [RemoteDiffEntry(path: "Materials/Competitors/Pricing index.md", status: .added, sha: sha, size: nil)],
                commits: [], isTruncated: false
            )
        )
        try await engine.pullRemote()

        let item = try await engine.items.item(path: "Materials/Competitors/Pricing index.md")
        XCTAssertEqual(item?.size, Int64(body.count))
        XCTAssertEqual(item?.blobSHA, sha)
        let snapshot = try await engine.snapshot(id: item?.id ?? "")
        XCTAssertEqual(snapshot?.sizeIsUnknown, false)
        XCTAssertEqual(snapshot?.contentVersion, sha)
    }

    func testZeroSizeNonEmptyBlobIsReportedUnknownUntilFetched() async throws {
        let (engine, remote, directory) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Data("real content\n".utf8)
        let sha = GitBlobSHA.sha1(of: body)
        await remote.storeBlob(sha, body)
        let poisoned = StoredItem(
            id: UUID().uuidString, parentID: ItemStore.rootID, name: "Pricing index.md",
            path: "Materials/Competitors/Pricing index.md", isDirectory: false, blobSHA: sha, size: 0,
            mode: "100644", contentMtime: Date(timeIntervalSince1970: 1_700_000_000), metaRev: 0,
            state: .synced, localSHA: nil, isIgnored: false
        )
        let empty = StoredItem(
            id: UUID().uuidString, parentID: ItemStore.rootID, name: ".gitkeep", path: ".gitkeep",
            isDirectory: false, blobSHA: GitBlobSHA.empty, size: 0, mode: "100644",
            contentMtime: Date(timeIntervalSince1970: 1_700_000_000), metaRev: 0,
            state: .synced, localSHA: nil, isIgnored: false
        )
        let store = await engine.items
        try store.insert(poisoned, recordChanges: false)
        try store.insert(empty, recordChanges: false)

        let before = try await engine.snapshot(id: poisoned.id)
        XCTAssertEqual(before?.sizeIsUnknown, true)
        XCTAssertEqual(before?.contentVersion, sha + "#pending")
        let keep = try await engine.snapshot(id: empty.id)
        XCTAssertEqual(keep?.sizeIsUnknown, false)
        XCTAssertEqual(keep?.contentVersion, GitBlobSHA.empty)

        let revision = try await engine.currentRevision()
        await engine.resumePendingUploads()
        let once = try await engine.currentRevision()
        XCTAssertGreaterThan(once, revision)
        await engine.resumePendingUploads()
        let afterRebroadcast = try await engine.currentRevision()
        XCTAssertEqual(afterRebroadcast, once)

        let url = try await engine.fetchContents(itemID: poisoned.id)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try Data(contentsOf: url), body)
        let healed = try await engine.items.item(id: poisoned.id)
        XCTAssertEqual(healed?.size, Int64(body.count))
        let after = try await engine.snapshot(id: poisoned.id)
        XCTAssertEqual(after?.sizeIsUnknown, false)
        XCTAssertEqual(after?.contentVersion, sha)
        await engine.resumePendingUploads()
        let finalRevision = try await engine.currentRevision()
        XCTAssertEqual(finalRevision, afterRebroadcast + 1)
    }

    func testFileSHAMatchesBufferSHA() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "gds-sha-\(UUID().uuidString)")
        let data = Data("blob-body".utf8)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try GitBlobSHA.sha1(ofFile: url), GitBlobSHA.sha1(of: data))
        XCTAssertEqual(GitBlobSHA.empty, GitBlobSHA.sha1(of: Data()))
    }
}

extension SyncEngineTests {
    fileprivate func makeEngine() throws -> (SyncEngine, MockRemote, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gds-engine-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try DomainStore(at: directory.appending(path: "store.sqlite"))
        let remote = MockRemote()
        let config = RepoConfig(owner: "o", repo: "r", branch: "main", accountID: "github.com:me", displayName: "Docs")
        let engine = SyncEngine(config: config, domain: store, remote: remote, stagingDirectory: directory.appending(path: "staging"), flushDelayNanoseconds: 60_000_000_000)
        return (engine, remote, directory)
    }
}

private actor MockRemote: RemoteRepository {
    private var files: [String: Data] = [:]
    private var headValue: RemoteHead?
    private var treeValue = RemoteTree(entries: [], truncated: false)
    private var diffValue = RemoteDiff(baseSHA: "", headSHA: "", files: [], commits: [], isTruncated: false)
    private var blobs: [String: Data] = [:]

    func paths() -> [String: Data] { files }

    func use(head: RemoteHead, tree: RemoteTree, diff: RemoteDiff? = nil) {
        headValue = head
        treeValue = tree
        if let diff { diffValue = diff }
    }

    func storeBlob(_ sha: String, _ data: Data) { blobs[sha] = data }

    func head(knownETag: String?) async throws -> RemoteHead? {
        if let headValue { return headValue }
        throw SyncError.remote(.emptyRepository)
    }

    func tree(sha: String, recursive: Bool) async throws -> RemoteTree { treeValue }

    func downloadBlob(sha: String, to destination: URL) async throws -> Int64 {
        let data = blobs[sha] ?? Data()
        try data.write(to: destination)
        return Int64(data.count)
    }

    func diff(from baseSHA: String, to headSHA: String) async throws -> RemoteDiff { diffValue }

    func commit(_ request: CommitRequest, limits: CommitLimits) async throws -> CommitResult {
        var shas: [String: String] = [:]
        for change in request.changes {
            switch change {
            case .addition(let path, let url, _, _):
                let data = try Data(contentsOf: url)
                files[path] = data
                shas[path] = GitBlobSHA.sha1(of: data)
            case .deletion(let path):
                files.removeValue(forKey: path)
            case .move(let from, let to, let blobSHA, _):
                let data = files.removeValue(forKey: from) ?? Data()
                files[to] = data
                shas[to] = blobSHA
            case .copy(let to, let blobSHA, _):
                files[to] = Data()
                shas[to] = blobSHA
            }
        }
        return CommitResult(
            newHead: RemoteHead(commitSHA: "abc", treeSHA: "def", committedAt: Date()),
            blobSHAs: shas
        )
    }

    func createFirstFile(path: String, contentURL: URL, branch: String, message: String) async throws -> RemoteHead {
        RemoteHead(commitSHA: "abc", treeSHA: "def", committedAt: Date())
    }

    func recentCommits(limit: Int) async throws -> [RemoteCommitSummary] { [] }
}
