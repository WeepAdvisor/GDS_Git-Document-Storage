import Foundation

/// Описание одного HTTP-запроса к GitHub. Конструкторы для всех нужных эндпоинтов — в `Endpoints.swift`
/// (фаза 1). Здесь только форма.
public struct Endpoint: Sendable, Equatable {
    public enum Method: String, Sendable { case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE" }

    /// Категория для `RateLimiter` (разные пулы параллелизма).
    public enum Category: Sendable { case read, blobDownload, blobUpload, mutation, graphQL }

    public var method: Method
    /// Путь относительно `baseURL`, начинается с `/`. Для GraphQL — `/graphql`.
    public var path: String
    public var query: [URLQueryItem]
    public var body: Data?
    /// Переопределение `Accept` (например, `application/vnd.github.raw+json` для blob).
    public var accept: String?
    public var category: Category
    /// Использовать условный GET с ETag из кэша.
    public var usesETag: Bool

    public init(method: Method, path: String, query: [URLQueryItem] = [], body: Data? = nil,
                accept: String? = nil, category: Category = .read, usesETag: Bool = false) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.accept = accept
        self.category = category
        self.usesETag = usesETag
    }

    /// Ключ для ETag-кэша: метод + путь + query.
    public var cacheKey: String {
        var components = URLComponents()
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        return "\(method.rawValue) \(components.string ?? path)"
    }
}
