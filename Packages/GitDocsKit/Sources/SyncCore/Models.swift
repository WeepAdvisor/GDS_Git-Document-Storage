import Foundation

// MARK: - Конфигурация (см. docs/02-DATA-MODEL.md §1)

public enum TokenKind: String, Codable, Sendable {
    case oauthDeviceFlow
    case personalAccessToken
}

public enum AccountState: String, Codable, Sendable {
    case ok
    case needsReauth
}

public struct Account: Codable, Identifiable, Sendable, Hashable {
    /// `"github.com:<login>"`
    public let id: String
    public var login: String
    public var displayName: String?
    public var avatarURL: URL?
    public var tokenKind: TokenKind
    public var state: AccountState
    public var addedAt: Date

    public init(login: String, displayName: String? = nil, avatarURL: URL? = nil,
                tokenKind: TokenKind, state: AccountState = .ok, addedAt: Date = Date(), host: String = "github.com") {
        self.id = "\(host):\(login)"
        self.login = login
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.tokenKind = tokenKind
        self.state = state
        self.addedAt = addedAt
    }
}

public enum AccessMode: String, Codable, Sendable {
    case readWrite
    case readOnly
    case unavailable
}

/// Политика конфликтов (ADR-006, docs/03 §5).
public enum ConflictPolicy: String, Codable, Sendable, CaseIterable {
    case lastWriterWins
    case keepBoth
}

public struct RepoConfig: Codable, Identifiable, Sendable, Hashable {
    /// Совпадает с `NSFileProviderDomainIdentifier.rawValue`.
    public let id: UUID
    public var owner: String
    public var repo: String
    public var branch: String
    public var accountID: Account.ID
    /// Имя папки в Finder.
    public var displayName: String
    public var mode: AccessMode
    public var conflictPolicy: ConflictPolicy
    public var pollInterval: TimeInterval
    public var isEnabled: Bool
    public var lastCapabilityReport: CapabilityReport?

    public init(id: UUID = UUID(), owner: String, repo: String, branch: String, accountID: Account.ID,
                displayName: String? = nil, mode: AccessMode = .readWrite,
                conflictPolicy: ConflictPolicy = .lastWriterWins, pollInterval: TimeInterval = 5,
                isEnabled: Bool = true, lastCapabilityReport: CapabilityReport? = nil) {
        self.id = id
        self.owner = owner
        self.repo = repo
        self.branch = branch
        self.accountID = accountID
        self.displayName = displayName ?? repo
        self.mode = mode
        self.conflictPolicy = conflictPolicy
        self.pollInterval = pollInterval
        self.isEnabled = isEnabled
        self.lastCapabilityReport = lastCapabilityReport
    }

    public var fullName: String { "\(owner)/\(repo)" }
}

// MARK: - Проверка возможностей (docs/04 §5)

public struct CapabilityReport: Codable, Sendable, Hashable {
    public enum Reason: String, Codable, Sendable {
        case noAccess, archived, disabled, noPush, protectedBranch, tokenScope, ssoRequired, emptyRepo
    }
    public enum Warning: String, Codable, Sendable {
        case lfsDetected, hugeTree, largeTree, largeRepo, unknownProtection
    }

    public var mode: AccessMode
    public var reasons: [Reason]
    public var warnings: [Warning]
    public var accountID: Account.ID
    public var defaultBranch: String?
    public var isEmptyRepository: Bool
    public var ssoAuthorizationURL: URL?
    public var rateLimitRemaining: Int?
    public var checkedAt: Date

    public init(mode: AccessMode, reasons: [Reason] = [], warnings: [Warning] = [], accountID: Account.ID,
                defaultBranch: String? = nil, isEmptyRepository: Bool = false, ssoAuthorizationURL: URL? = nil,
                rateLimitRemaining: Int? = nil, checkedAt: Date = Date()) {
        self.mode = mode
        self.reasons = reasons
        self.warnings = warnings
        self.accountID = accountID
        self.defaultBranch = defaultBranch
        self.isEmptyRepository = isEmptyRepository
        self.ssoAuthorizationURL = ssoAuthorizationURL
        self.rateLimitRemaining = rateLimitRemaining
        self.checkedAt = checkedAt
    }
}

// MARK: - Удалённое состояние

public enum RemoteEntryKind: Sendable, Equatable {
    case blob
    case tree
    /// Submodule / symlink — пропускаются (docs/01 §7).
    case unsupported(mode: String)
}

public struct RemoteTreeEntry: Sendable, Equatable {
    public var path: String      // NFC, без ведущего `/`
    public var kind: RemoteEntryKind
    public var sha: String
    public var mode: String      // 100644 / 100755 / 040000
    public var size: Int64?

    public init(path: String, kind: RemoteEntryKind, sha: String, mode: String, size: Int64? = nil) {
        self.path = path
        self.kind = kind
        self.sha = sha
        self.mode = mode
        self.size = size
    }
}

public struct RemoteHead: Sendable, Equatable {
    public var commitSHA: String
    public var treeSHA: String
    public var committedAt: Date
    public var etag: String?

    public init(commitSHA: String, treeSHA: String, committedAt: Date, etag: String? = nil) {
        self.commitSHA = commitSHA
        self.treeSHA = treeSHA
        self.committedAt = committedAt
        self.etag = etag
    }
}

public struct RemoteTree: Sendable, Equatable {
    public var entries: [RemoteTreeEntry]
    /// GitHub обрезал ответ (> 100 000 записей / 7 MB) — нужен поуровневый обход.
    public var truncated: Bool

    public init(entries: [RemoteTreeEntry], truncated: Bool) {
        self.entries = entries
        self.truncated = truncated
    }
}

public struct RemoteDiffEntry: Sendable, Equatable {
    public enum Status: String, Sendable { case added, modified, removed, renamed, changed, copied, unchanged }
    public var path: String
    public var previousPath: String?
    public var status: Status
    public var sha: String?
    public var size: Int64?

    public init(path: String, previousPath: String? = nil, status: Status, sha: String?, size: Int64? = nil) {
        self.path = path
        self.previousPath = previousPath
        self.status = status
        self.sha = sha
        self.size = size
    }
}

public struct RemoteCommitSummary: Sendable, Equatable {
    public var sha: String
    public var authorLogin: String?
    public var message: String
    public var committedAt: Date

    public init(sha: String, authorLogin: String?, message: String, committedAt: Date) {
        self.sha = sha
        self.authorLogin = authorLogin
        self.message = message
        self.committedAt = committedAt
    }
}

public struct RemoteDiff: Sendable, Equatable {
    public var baseSHA: String
    public var headSHA: String
    public var files: [RemoteDiffEntry]
    public var commits: [RemoteCommitSummary]
    /// `files` неполон (≥ 300 файлов) — делать полный `tree` и diff с БД.
    public var isTruncated: Bool

    public init(baseSHA: String, headSHA: String, files: [RemoteDiffEntry], commits: [RemoteCommitSummary], isTruncated: Bool) {
        self.baseSHA = baseSHA
        self.headSHA = headSHA
        self.files = files
        self.commits = commits
        self.isTruncated = isTruncated
    }
}

// MARK: - Коммит (docs/03 §4, docs/04 §4)

/// Одно изменение в составе коммита. Содержимое передаётся файлом (staging), не в памяти.
public enum CommitChange: Sendable, Equatable {
    /// Новый или изменённый файл с новым содержимым.
    case addition(path: String, contentURL: URL, mode: String, size: Int64)
    /// Удаление пути (файл). Каталоги удаляются перечислением файлов.
    case deletion(path: String)
    /// Переименование/перемещение без изменения содержимого (переиспользуем blob SHA).
    case move(from: String, to: String, blobSHA: String, mode: String)
    /// Копия существующего blob под новым путём (Finder «Duplicate», копирование внутри репо).
    case copy(to: String, blobSHA: String, mode: String)
}

public struct CommitRequest: Sendable, Equatable {
    public var changes: [CommitChange]
    /// Ожидаемый HEAD ветки (оптимистическая блокировка). Несовпадение → `SyncError.notFastForward`.
    public var expectedHeadSHA: String
    public var expectedTreeSHA: String
    public var headline: String
    public var body: String?

    public init(changes: [CommitChange], expectedHeadSHA: String, expectedTreeSHA: String, headline: String, body: String? = nil) {
        self.changes = changes
        self.expectedHeadSHA = expectedHeadSHA
        self.expectedTreeSHA = expectedTreeSHA
        self.headline = headline
        self.body = body
    }
}

public struct CommitResult: Sendable, Equatable {
    public var newHead: RemoteHead
    /// path → blob SHA для всех additions/copies/moves (чтобы обновить `items.blob_sha`).
    public var blobSHAs: [String: String]

    public init(newHead: RemoteHead, blobSHAs: [String: String]) {
        self.newHead = newHead
        self.blobSHAs = blobSHAs
    }
}

/// Пороги выбора стратегии коммита (docs/04 §2.1, §4). Уточняются в фазе 7.
public struct CommitLimits: Sendable, Equatable {
    public var graphQLMaxFiles: Int = 200
    public var graphQLMaxFileBytes: Int64 = 10 * 1024 * 1024
    public var graphQLMaxTotalBytes: Int64 = 25 * 1024 * 1024
    public var gitHubMaxBlobBytes: Int64 = 100 * 1024 * 1024
    public init() {}
    public static let `default` = CommitLimits()
}

public enum CommitStrategy: Sendable, Equatable {
    case graphQL
    case restGitData
    case contentsAPIFirstFile
}
