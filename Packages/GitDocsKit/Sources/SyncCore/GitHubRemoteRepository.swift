import Foundation
import GitHubKit

public struct GitHubRemoteRepository: RemoteRepository {
    public let owner: String
    public let repo: String
    public let branch: String
    public let client: GitHubClient
    public var limits: CommitLimits

    public init(owner: String, repo: String, branch: String, client: GitHubClient, limits: CommitLimits = .default) {
        self.owner = owner
        self.repo = repo
        self.branch = branch
        self.client = client
        self.limits = limits
    }

    public func head(knownETag: String?) async throws -> RemoteHead? {
        let raw: GitHubClient.Response<Data>
        do {
            raw = try await client.fetch(Endpoints.ref(owner: owner, repo: repo, branch: branch), ifNoneMatch: knownETag)
        } catch let error as GitHubError {
            throw SyncError.remote(error)
        }
        if raw.notModified { return nil }
        let ref = try GitHubDecodingShim.decode(GHRef.self, from: raw.body)
        let commit = try await client.value(Endpoints.commit(owner: owner, repo: repo, sha: ref.object.sha), as: GHCommitObject.self)
        return RemoteHead(commitSHA: ref.object.sha, treeSHA: commit.tree.sha, committedAt: commit.committer?.date ?? Date(), etag: raw.etag)
    }

    public func tree(sha: String, recursive: Bool) async throws -> RemoteTree {
        let gh = try await client.value(Endpoints.tree(owner: owner, repo: repo, sha: sha, recursive: recursive), as: GHTree.self)
        return RemoteTree(entries: gh.tree.map(Self.mapEntry), truncated: gh.truncated == true)
    }

    public func downloadBlob(sha: String, to destination: URL) async throws -> Int64 {
        do {
            return try await client.download(Endpoints.blob(owner: owner, repo: repo, sha: sha), to: destination)
        } catch let error as GitHubError {
            throw SyncError.remote(error)
        }
    }

    public func diff(from baseSHA: String, to headSHA: String) async throws -> RemoteDiff {
        let compare = try await client.value(Endpoints.compare(owner: owner, repo: repo, base: baseSHA, head: headSHA), as: GHCompare.self)
        let files = (compare.files ?? []).map { file in
            RemoteDiffEntry(path: file.filename, previousPath: file.previousFilename,
                            status: RemoteDiffEntry.Status(rawValue: file.status) ?? .changed, sha: file.sha, size: nil)
        }
        let commits = (compare.commits ?? []).map { commit in
            RemoteCommitSummary(sha: commit.sha, authorLogin: commit.author?.login, message: commit.commit.message,
                                committedAt: commit.commit.committer?.date ?? Date())
        }
        return RemoteDiff(baseSHA: baseSHA, headSHA: headSHA, files: files, commits: commits, isTruncated: files.count >= 300)
    }

    public func commit(_ request: CommitRequest, limits: CommitLimits) async throws -> CommitResult {
        if request.expectedHeadSHA.isEmpty {
            guard case let .addition(path, url, _, _) = request.changes.first, request.changes.count == 1 else {
                throw SyncError.storage("Empty repository accepts a single first file")
            }
            let head = try await createFirstFile(path: path, contentURL: url, branch: branch, message: request.headline)
            let sha = try GitBlobSHA.sha1(ofFile: url)
            return CommitResult(newHead: head, blobSHAs: [path: sha])
        }
        switch CommitStrategySelector.select(for: request.changes, isEmptyRepository: false, limits: limits) {
        case .graphQL, .contentsAPIFirstFile:
            if Self.containsLargeFile(request.changes, limit: limits.maxInMemoryBytes) {
                return try await commitREST(request, limits: limits)
            }
            return try await commitGraphQL(request, limits: limits)
        case .restGitData:
            return try await commitREST(request, limits: limits)
        }
    }

    public func createFirstFile(path: String, contentURL: URL, branch: String, message: String) async throws -> RemoteHead {
        let bytes = Self.fileByteCount(contentURL, fallback: 0)
        if bytes > limits.gitHubMaxBlobBytes { throw SyncError.fileTooLarge(path: path, bytes: bytes) }
        let written: GHContentsWriteResult
        if bytes > limits.maxInMemoryBytes {
            let body = FileManager.default.temporaryDirectory.appending(path: "gds-contents-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: body) }
            let messageJSON = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
            let branchJSON = String(decoding: try JSONSerialization.data(withJSONObject: branch), as: UTF8.self)
            try JSONBase64Body.write(
                source: contentURL,
                prefix: "{\"message\":\(messageJSON),\"content\":\"",
                suffix: "\",\"branch\":\(branchJSON)}",
                to: body
            )
            written = try await client.uploadValue(Endpoints.putContents(owner: owner, repo: repo, path: path), fromFile: body, as: GHContentsWriteResult.self)
        } else {
            let data = try Data(contentsOf: contentURL)
            let payload: [String: Any] = ["message": message, "content": data.base64EncodedString(), "branch": branch]
            let json = try JSONSerialization.data(withJSONObject: payload)
            written = try await client.value(Endpoints.putContents(owner: owner, repo: repo, path: path, json: json), as: GHContentsWriteResult.self)
        }
        let commit = try await client.value(Endpoints.commit(owner: owner, repo: repo, sha: written.commit.sha), as: GHCommitObject.self)
        return RemoteHead(commitSHA: written.commit.sha, treeSHA: commit.tree.sha, committedAt: commit.committer?.date ?? Date())
    }

    public func recentCommits(limit: Int) async throws -> [RemoteCommitSummary] {
        guard let head = try await head(knownETag: nil) else { return [] }
        let compare = try await diff(from: head.commitSHA, to: head.commitSHA)
        return Array(compare.commits.prefix(limit))
    }

    private func commitGraphQL(_ request: CommitRequest, limits: CommitLimits) async throws -> CommitResult {
        var additions: [[String: String]] = []
        var deletions: [[String: String]] = []
        var shas: [String: String] = [:]
        for change in request.changes {
            switch change {
            case .addition(let path, let url, _, let size):
                let bytes = Self.fileByteCount(url, fallback: size)
                if bytes > limits.maxInMemoryBytes { throw SyncError.fileTooLarge(path: path, bytes: bytes) }
                let data = try Data(contentsOf: url)
                additions.append(["path": path, "contents": data.base64EncodedString()])
                shas[path] = GitBlobSHA.sha1(of: data)
            case .deletion(let path):
                deletions.append(["path": path])
            case .move, .copy:
                return try await commitREST(request, limits: limits)
            }
        }
        var fileChanges: [String: Any] = [:]
        if !additions.isEmpty { fileChanges["additions"] = additions }
        if !deletions.isEmpty { fileChanges["deletions"] = deletions }
        var message: [String: String] = ["headline": request.headline]
        if let body = request.body { message["body"] = body }
        let input: [String: Any] = [
            "branch": ["repositoryNameWithOwner": "\(owner)/\(repo)", "branchName": branch],
            "expectedHeadOid": request.expectedHeadSHA,
            "message": message,
            "fileChanges": fileChanges,
        ]
        let variables = try JSONSerialization.data(withJSONObject: ["input": input])
        let query = """
        mutation($input: CreateCommitOnBranchInput!) {
          createCommitOnBranch(input: $input) { commit { oid committedDate } }
        }
        """
        do {
            let payload = try await client.graphQL(query, variables: variables) as CreateCommitPayload
            let oid = payload.createCommitOnBranch.commit.oid
            let commit = try await client.value(Endpoints.commit(owner: owner, repo: repo, sha: oid), as: GHCommitObject.self)
            let when = commit.committer?.date ?? Date()
            return CommitResult(newHead: RemoteHead(commitSHA: oid, treeSHA: commit.tree.sha, committedAt: when), blobSHAs: shas)
        } catch let error as GitHubError {
            if case .notFastForward = error { throw SyncError.notFastForward }
            throw SyncError.remote(error)
        }
    }

    private func commitREST(_ request: CommitRequest, limits: CommitLimits) async throws -> CommitResult {
        var shas: [String: String] = [:]
        var rejected: [String: String] = [:]
        var tree: [[String: Any]] = []
        for change in request.changes {
            switch change {
            case .addition(let path, let url, let mode, let size):
                let bytes = Self.fileByteCount(url, fallback: size)
                if bytes > limits.gitHubMaxBlobBytes {
                    rejected[path] = "\(path) is \(bytes) bytes. GitHub stores at most 100 MB in one file."
                    continue
                }
                do {
                    let blobSHA = try await uploadBlob(file: url, path: path, bytes: bytes)
                    shas[path] = blobSHA
                    tree.append(["path": path, "mode": mode, "type": "blob", "sha": blobSHA])
                } catch let error as SyncError where Self.isSingleFileTooLarge(error) {
                    rejected[path] = "GitHub rejected \(path) as too large"
                    continue
                }
            case .deletion(let path):
                tree.append(["path": path, "mode": "100644", "type": "blob", "sha": NSNull()])
            case .move(let from, let to, let blobSHA, let mode):
                tree.append(["path": to, "mode": mode, "type": "blob", "sha": blobSHA])
                tree.append(["path": from, "mode": mode, "type": "blob", "sha": NSNull()])
                shas[to] = blobSHA
            case .copy(let to, let blobSHA, let mode):
                tree.append(["path": to, "mode": mode, "type": "blob", "sha": blobSHA])
                shas[to] = blobSHA
            }
        }
        if tree.isEmpty {
            return CommitResult(
                newHead: RemoteHead(commitSHA: request.expectedHeadSHA, treeSHA: request.expectedTreeSHA, committedAt: Date()),
                blobSHAs: shas,
                rejected: rejected
            )
        }
        let treeBody = try JSONSerialization.data(withJSONObject: ["base_tree": request.expectedTreeSHA, "tree": tree])
        let createdTree = try await client.value(Endpoints.createTree(owner: owner, repo: repo, json: treeBody), as: GHCreatedObject.self)
        let message = request.body.map { request.headline + "\n\n" + $0 } ?? request.headline
        let commitBody = try JSONSerialization.data(withJSONObject: [
            "message": message, "tree": createdTree.sha, "parents": [request.expectedHeadSHA],
        ])
        let createdCommit = try await client.value(Endpoints.createCommit(owner: owner, repo: repo, json: commitBody), as: GHCreatedObject.self)
        let refBody = try JSONSerialization.data(withJSONObject: ["sha": createdCommit.sha, "force": false])
        do {
            _ = try await client.value(Endpoints.updateRef(owner: owner, repo: repo, branch: branch, json: refBody), as: GHRef.self)
        } catch let error as GitHubError {
            if case .notFastForward = error { throw SyncError.notFastForward }
            throw SyncError.remote(error)
        }
        let commit = try await client.value(Endpoints.commit(owner: owner, repo: repo, sha: createdCommit.sha), as: GHCommitObject.self)
        return CommitResult(
            newHead: RemoteHead(commitSHA: createdCommit.sha, treeSHA: createdTree.sha, committedAt: commit.committer?.date ?? Date()),
            blobSHAs: shas,
            rejected: rejected
        )
    }

    private func uploadBlob(file url: URL, path: String, bytes: Int64) async throws -> String {
        if bytes > limits.gitHubMaxBlobBytes { throw SyncError.fileTooLarge(path: path, bytes: bytes) }
        let body = FileManager.default.temporaryDirectory.appending(path: "gds-blob-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: body) }
        do {
            try JSONBase64Body.write(source: url, prefix: "{\"content\":\"", suffix: "\",\"encoding\":\"base64\"}", to: body)
            return try await client.uploadValue(Endpoints.createBlob(owner: owner, repo: repo), fromFile: body, as: GHCreatedObject.self).sha
        } catch let error as GitHubError {
            if Self.isTooLarge(error) { throw SyncError.fileTooLarge(path: path, bytes: bytes) }
            throw SyncError.remote(error)
        }
    }

    private static func isSingleFileTooLarge(_ error: SyncError) -> Bool {
        if case .fileTooLarge = error { return true }
        if case .remote(let github) = error { return isTooLarge(github) }
        return false
    }

    private static func isTooLarge(_ error: GitHubError) -> Bool {
        switch error {
        case .validation(let message):
            return message.localizedCaseInsensitiveContains("too large")
        case .graphQL(let messages):
            return messages.contains { $0.localizedCaseInsensitiveContains("too large") }
        default:
            return false
        }
    }

    private static func containsLargeFile(_ changes: [CommitChange], limit: Int64) -> Bool {
        changes.contains { change in
            guard case .addition(_, let url, _, let size) = change else { return false }
            return fileByteCount(url, fallback: size) > limit
        }
    }

    private static func fileByteCount(_ url: URL, fallback: Int64) -> Int64 {
        if let number = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber, number.int64Value > 0 {
            return number.int64Value
        }
        return fallback
    }

    private static func mapEntry(_ entry: GHTree.Entry) -> RemoteTreeEntry {
        let kind: RemoteEntryKind
        if entry.mode == "120000" || entry.type == "commit" {
            kind = .unsupported(mode: entry.mode)
        } else if entry.type == "tree" {
            kind = .tree
        } else {
            kind = .blob
        }
        return RemoteTreeEntry(path: entry.path, kind: kind, sha: entry.sha, mode: entry.mode, size: entry.size.map(Int64.init))
    }
}

private struct CreateCommitPayload: Decodable {
    struct Result: Decodable {
        struct Commit: Decodable { var oid: String }
        var commit: Commit
    }
    var createCommitOnBranch: Result
}

enum GitHubDecodingShim {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: raw))
            }
            return date
        }
        return try decoder.decode(T.self, from: data)
    }
}
