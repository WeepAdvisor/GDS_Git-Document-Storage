import Foundation

/// Единственная точка выхода в сеть к GitHub (см. `.cursor/rules/github-api.mdc`).
/// Фаза 1: добавить `RateLimiter`, `ETagCache`, `download(_:to:)`, `graphQL(_:variables:)`,
/// маппинг ошибок (`GitHubError`) и декодирование моделей.
public actor GitHubClient {
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var userAgent: String
        public var apiVersion: String

        public init(baseURL: URL = URL(string: "https://api.github.com")!,
                    userAgent: String = "GitDocumentStorage/0.1 (macOS)",
                    apiVersion: String = "2022-11-28") {
            self.baseURL = baseURL
            self.userAgent = userAgent
            self.apiVersion = apiVersion
        }
    }

    public struct Response<Body: Sendable>: Sendable {
        public let status: Int
        public let body: Body
        public let etag: String?
        public let rateLimit: RateLimitState
        public let notModified: Bool
        /// Имена заголовков в нижнем регистре.
        public let headers: [String: String]

        public init(status: Int, body: Body, etag: String?, rateLimit: RateLimitState, notModified: Bool, headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.etag = etag
            self.rateLimit = rateLimit
            self.notModified = notModified
            self.headers = headers
        }
    }

    public let configuration: Configuration
    let session: URLSession
    let tokenProvider: @Sendable () async throws -> String
    let rateLimiter: RateLimiter
    let etagCache: (any ETagCache)?
    let transfer: TransferReporter?

    /// - Parameter tokenProvider: отдаёт актуальный токен аккаунта (из `TokenStore`).
    public init(configuration: Configuration = .init(),
                session: URLSession = .shared,
                rateLimiter: RateLimiter = RateLimiter(),
                etagCache: (any ETagCache)? = nil,
                transfer: TransferReporter? = nil,
                tokenProvider: @escaping @Sendable () async throws -> String) {
        self.configuration = configuration
        self.session = session
        self.rateLimiter = rateLimiter
        self.etagCache = etagCache
        self.transfer = transfer
        self.tokenProvider = tokenProvider
    }

    /// Собирает `URLRequest` с обязательными заголовками. Публично — для тестов.
    public func makeRequest(_ endpoint: Endpoint, ifNoneMatch: String? = nil) async throws -> URLRequest {
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)!
        components.path = endpoint.path
        components.queryItems = endpoint.query.isEmpty ? nil : endpoint.query
        guard let url = components.url else { throw GitHubError.network("Bad URL for \(endpoint.path)") }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.httpBody = endpoint.body
        request.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        request.setValue(endpoint.accept ?? "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        if endpoint.body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let ifNoneMatch { request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    /// Сырой запрос без декодирования. Фаза 1 оборачивает его лимитером и кэшем.
    public func send(_ endpoint: Endpoint, ifNoneMatch: String? = nil) async throws -> Response<Data> {
        let request = try await makeRequest(endpoint, ifNoneMatch: ifNoneMatch)
        let (data, urlResponse): (Data, URLResponse)
        do {
            let observer = transfer.map { TransferTaskDelegate(reporter: $0) }
            (data, urlResponse) = try await session.data(for: request, delegate: observer)
        } catch let error as URLError where error.code == .cancelled {
            throw GitHubError.cancelled
        } catch {
            throw GitHubError.network(error.localizedDescription)
        }
        guard let http = urlResponse as? HTTPURLResponse else { throw GitHubError.network("Non-HTTP response") }
        let rate = RateLimitState(response: http)
        let headers = Self.lowercasedHeaders(http)
        if http.statusCode == 304 {
            return Response(status: 304, body: Data(), etag: http.value(forHTTPHeaderField: "ETag"), rateLimit: rate, notModified: true, headers: headers)
        }
        if (200..<300).contains(http.statusCode) {
            return Response(status: http.statusCode, body: data, etag: http.value(forHTTPHeaderField: "ETag"), rateLimit: rate, notModified: false, headers: headers)
        }
        throw Self.mapError(status: http.statusCode, data: data, response: http, rate: rate)
    }

    /// Маппинг HTTP-ошибок GitHub в `GitHubError`. Публично — для тестов.
    public static func mapError(status: Int, data: Data, response: HTTPURLResponse, rate: RateLimitState) -> GitHubError {
        struct APIErrorBody: Decodable { let message: String?; let documentation_url: String? }
        let body = try? JSONDecoder().decode(APIErrorBody.self, from: data)
        let message = body?.message ?? ""

        if let sso = response.value(forHTTPHeaderField: "X-GitHub-SSO"), sso.contains("required") {
            let url = sso.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("url=") }.map { String($0.dropFirst(4)) }.flatMap(URL.init(string:))
            return .ssoRequired(authorizationURL: url)
        }
        switch status {
        case 401: return .unauthorized
        case 403, 429:
            if message.localizedCaseInsensitiveContains("rate limit") || rate.remaining == 0 || rate.retryAfter != nil {
                return .rateLimited(retryAfter: rate.recommendedDelay(isSecondaryLimit: true) ?? 60)
            }
            return .http(status: status, message: message, documentationURL: body?.documentation_url)
        case 404: return .notFound
        case 409 where message.localizedCaseInsensitiveContains("empty"): return .emptyRepository
        case 422:
            if message.localizedCaseInsensitiveContains("fast forward") || message.localizedCaseInsensitiveContains("fast-forward") {
                return .notFastForward
            }
            return .validation(message: message)
        default:
            return .http(status: status, message: message, documentationURL: body?.documentation_url)
        }
    }

    static func lowercasedHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String, let text = value as? String else { continue }
            result[name.lowercased()] = text
        }
        return result
    }

    static func lane(for category: Endpoint.Category) -> RateLimiter.Lane {
        switch category {
        case .read: return .read
        case .blobDownload: return .blobDownload
        case .blobUpload: return .blobUpload
        case .mutation: return .mutation
        case .graphQL: return .graphQL
        }
    }
}
