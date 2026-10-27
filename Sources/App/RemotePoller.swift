import Foundation
import GitHubKit
import os
import SyncCore

/// Следит за HEAD ветки и будит расширение, пока локальная база не догонит GitHub.
actor RemotePoller {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GitDocumentStorage", category: "sync")
    private var task: Task<Void, Never>?
    private var etags: [UUID: String] = [:]
    private var lastSHA: [UUID: String] = [:]
    private var heads: [UUID: DomainHeadCache] = [:]
    /// 2 с: 304 по ETag не тратит primary limit. Пока база отстаёт — сигнал повторяется каждый тик.
    private let interval: UInt64 = 2_000_000_000

    func start() {
        guard task == nil else { return }
        let pause = interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: pause)
            }
        }
    }

    func tick() async {
        let configuration = (try? RepoConfigStore.resolve().load()) ?? AppConfiguration()
        let repos = configuration.repos.filter { $0.isEnabled && $0.mode != .unavailable }
        await withTaskGroup(of: Void.self) { group in
            for repo in repos {
                group.addTask { await self.poll(repo) }
            }
        }
    }

    private func poll(_ repo: RepoConfig) async {
        let tokens = KeychainTokenStore.fromBundle()
        guard let token = try? await tokens.token(for: repo.accountID), !token.isEmpty else { return }
        let client = GitHubClient { token }
        let remote = GitHubRemoteRepository(owner: repo.owner, repo: repo.repo, branch: repo.branch, client: client)
        do {
            let head = try await remote.head(knownETag: etags[repo.id])
            if let head {
                if let etag = head.etag { etags[repo.id] = etag }
                let changed = lastSHA[repo.id] != head.commitSHA
                lastSHA[repo.id] = head.commitSHA
                if changed {
                    logger.info("Remote head moved for \(repo.fullName, privacy: .public)")
                }
            }
            guard let remoteSHA = lastSHA[repo.id] else { return }
            if storedHead(repo.id) == remoteSHA { return }
            await DomainManager.shared.signal(repo.id.uuidString)
        } catch {
            logger.error("poll \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            ProblemLog.record(kind: "pollFailed", message: String(describing: error), domain: repo.fullName)
        }
    }

    private func storedHead(_ id: UUID) -> String? {
        guard let paths = try? SharedPaths() else { return nil }
        if heads[id] == nil {
            heads[id] = DomainHeadCache(storeURL: paths.storeURL(id))
        }
        return heads[id]?.headSHA()
    }
}
