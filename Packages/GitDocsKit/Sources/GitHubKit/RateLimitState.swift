import Foundation

/// Снимок состояния лимитов из заголовков ответа GitHub.
/// Парсинг вынесен в чистую функцию, чтобы покрыть тестами без сети.
public struct RateLimitState: Sendable, Equatable {
    public var limit: Int?
    public var remaining: Int?
    /// UTC epoch seconds, когда окно сбросится.
    public var resetAt: Date?
    /// Из заголовка `retry-after` (secondary limit).
    public var retryAfter: TimeInterval?
    /// Ресурс (`core`, `graphql`, `search`), заголовок `x-ratelimit-resource`.
    public var resource: String?

    public init(limit: Int? = nil, remaining: Int? = nil, resetAt: Date? = nil,
                retryAfter: TimeInterval? = nil, resource: String? = nil) {
        self.limit = limit
        self.remaining = remaining
        self.resetAt = resetAt
        self.retryAfter = retryAfter
        self.resource = resource
    }

    /// Заголовки HTTP регистронезависимы; `HTTPURLResponse.value(forHTTPHeaderField:)` это учитывает.
    public init(response: HTTPURLResponse) {
        func int(_ name: String) -> Int? { response.value(forHTTPHeaderField: name).flatMap { Int($0) } }
        limit = int("x-ratelimit-limit")
        remaining = int("x-ratelimit-remaining")
        resetAt = int("x-ratelimit-reset").map { Date(timeIntervalSince1970: TimeInterval($0)) }
        retryAfter = response.value(forHTTPHeaderField: "retry-after").flatMap { TimeInterval($0) }
        resource = response.value(forHTTPHeaderField: "x-ratelimit-resource")
    }

    /// Сколько ждать перед следующим запросом согласно рекомендациям GitHub
    /// (retry-after → до reset при remaining == 0 → минимум 60 с для secondary limit).
    public func recommendedDelay(now: Date = Date(), isSecondaryLimit: Bool) -> TimeInterval? {
        if let retryAfter { return max(retryAfter, 1) }
        if remaining == 0, let resetAt { return max(resetAt.timeIntervalSince(now), 1) }
        return isSecondaryLimit ? 60 : nil
    }
}
