import Foundation

/// Абстракция удалённого репозитория. Единственная реализация в v1 — `GitHubRemoteRepository` (фаза 1)
/// поверх `GitHubClient`. В тестах — `MockRemoteRepository`. Все пути — NFC, без ведущего `/`.
public protocol RemoteRepository: Sendable {
    /// Текущий HEAD ветки. `knownETag` — для условного запроса; при 304 возвращает `nil`.
    func head(knownETag: String?) async throws -> RemoteHead?

    /// Полное дерево коммита. При `truncated == true` вызывающая сторона делает `subtree` по каталогам.
    func tree(sha: String, recursive: Bool) async throws -> RemoteTree

    /// Скачивает blob в `destination` (стримингом). Возвращает фактический размер.
    func downloadBlob(sha: String, to destination: URL) async throws -> Int64

    /// Дифф между двумя коммитами (`compare`).
    func diff(from baseSHA: String, to headSHA: String) async throws -> RemoteDiff

    /// Атомарный коммит поверх `expectedHeadSHA`. Бросает `SyncError.notFastForward`, если HEAD ушёл.
    func commit(_ request: CommitRequest, limits: CommitLimits) async throws -> CommitResult

    /// Для пустого репозитория: создаёт первый файл (и ветку) через Contents API.
    func createFirstFile(path: String, contentURL: URL, branch: String, message: String) async throws -> RemoteHead

    /// Последние коммиты ветки (для «Recent activity», фаза 6/9).
    func recentCommits(limit: Int) async throws -> [RemoteCommitSummary]
}

/// Выбор стратегии коммита по составу батча и лимитам (docs/04 §4). Чистая функция — покрыть тестами.
public enum CommitStrategySelector {
    public static func select(for changes: [CommitChange], isEmptyRepository: Bool, limits: CommitLimits = .default) -> CommitStrategy {
        if isEmptyRepository { return .contentsAPIFirstFile }

        var fileCount = 0
        var totalBytes: Int64 = 0
        for change in changes {
            switch change {
            case .addition(_, _, _, let size):
                fileCount += 1
                totalBytes += size
                // Пустой blob GraphQL отклоняет (`createCommitOnBranch` = null) и валит весь коммит, включая файлы в новой папке.
                if size == 0 || size > limits.graphQLMaxFileBytes { return .restGitData }
            case .deletion:
                fileCount += 1
            case .move, .copy:
                return .restGitData
            }
        }
        if fileCount > limits.graphQLMaxFiles || totalBytes > limits.graphQLMaxTotalBytes {
            return .restGitData
        }
        return .graphQL
    }
}

/// Режет пачку, чтобы один запрос к GitHub не собирал всю папку сразу.
public enum CommitChunks {
    public static let maxFiles = 40
    public static let maxBytes: Int64 = 8 * 1024 * 1024

    public static func split(_ changes: [CommitChange], maxFiles: Int = CommitChunks.maxFiles, maxBytes: Int64 = CommitChunks.maxBytes) -> [[CommitChange]] {
        var chunks: [[CommitChange]] = []
        var current: [CommitChange] = []
        var bytes: Int64 = 0
        func flush() {
            if current.isEmpty { return }
            chunks.append(current)
            current = []
            bytes = 0
        }
        for change in changes {
            let size = Self.bytes(of: change)
            if size > maxBytes {
                flush()
                chunks.append([change])
                continue
            }
            if !current.isEmpty, current.count >= maxFiles || bytes + size > maxBytes {
                flush()
            }
            current.append(change)
            bytes += size
        }
        flush()
        return chunks
    }

    private static func bytes(of change: CommitChange) -> Int64 {
        if case .addition(_, _, _, let size) = change { return size }
        return 0
    }
}
