import Foundation

/// Ошибки слоя GitHub API. Все сетевые/протокольные проблемы маппятся сюда внутри `GitHubClient`.
public enum GitHubError: Error, Sendable, Equatable {
    /// HTTP-ошибка общего вида.
    case http(status: Int, message: String?, documentationURL: String?)
    /// 401 — токен недействителен/отозван.
    case unauthorized
    /// 403/429 с признаками rate limit. `retryAfter` — секунды до повторной попытки.
    case rateLimited(retryAfter: TimeInterval)
    /// 403 с заголовком `X-GitHub-SSO: required; url=...`.
    case ssoRequired(authorizationURL: URL?)
    /// 404 на репозиторий/ветку/объект.
    case notFound
    /// 409 `Git Repository is empty`.
    case emptyRepository
    /// 422 при `PATCH git/refs` без force либо `expectedHeadOid` mismatch в GraphQL.
    case notFastForward
    /// 422 валидации (имя файла, размер, путь).
    case validation(message: String)
    /// Ошибка GraphQL без HTTP-ошибки (`errors[]` в теле).
    case graphQL(messages: [String])
    /// Ответ не распарсился.
    case decoding(String)
    /// Транспорт (URLError и т.п.).
    case network(String)
    /// Файл превышает лимит GitHub (100 MB) — проверяется до отправки.
    case blobTooLarge(bytes: Int64)
    case cancelled
}
