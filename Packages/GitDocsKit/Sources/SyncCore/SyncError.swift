import Foundation
import GitHubKit

/// Ошибки движка синхронизации. В расширении маппятся в ошибки File Provider
/// (`FileProviderErrorMapper` в таргете расширения, т.к. `FileProvider` фреймворк там).
public enum SyncError: Error, Sendable, Equatable {
    /// Главное приложение не запущено — папка недоступна (ADR-005).
    case appNotRunning
    case notFastForward
    case remote(GitHubError)
    case readOnlyRepository
    case itemNotFound
    case invalidFileName(String)
    case fileTooLarge(path: String, bytes: Int64)
    case syncAnchorExpired
    case storage(String)
    case conflict(path: String)
}
