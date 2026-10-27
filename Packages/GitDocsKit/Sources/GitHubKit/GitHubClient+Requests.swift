import Foundation

extension GitHubClient {
    /// Сырой ответ с лимитером и ETag. 304 не бросает ошибку: `notModified == true`, тело пустое.
    public func fetch(_ endpoint: Endpoint, ifNoneMatch: String? = nil) async throws -> Response<Data> {
        let lane = Self.lane(for: endpoint.category)
        await rateLimiter.acquire(lane)
        do {
            let cachedFromStore = endpoint.usesETag ? await etagCache?.etag(for: endpoint.cacheKey) : nil
            let cachedETag = ifNoneMatch ?? cachedFromStore
            let raw = try await send(endpoint, ifNoneMatch: cachedETag)
            await rateLimiter.release(lane)
            if raw.rateLimit.remaining == 0, let retry = raw.rateLimit.recommendedDelay(isSecondaryLimit: false) {
                await rateLimiter.pause(seconds: retry)
            }
            if let tag = raw.etag, !raw.notModified {
                await etagCache?.store(key: endpoint.cacheKey, etag: tag, body: raw.body)
            }
            return raw
        } catch {
            await rateLimiter.release(lane)
            if case let GitHubError.rateLimited(retryAfter) = error {
                await rateLimiter.pause(seconds: retryAfter)
            }
            throw error
        }
    }

    public func value<T: Decodable & Sendable>(_ endpoint: Endpoint, as type: T.Type = T.self) async throws -> T {
        try await request(endpoint).body
    }

    /// POST JSON-файла. Лимитер тот же, что у обычного запроса этой категории.
    public func uploadValue<T: Decodable & Sendable>(_ endpoint: Endpoint, fromFile file: URL, as type: T.Type = T.self) async throws -> T {
        let lane = Self.lane(for: endpoint.category)
        await rateLimiter.acquire(lane)
        do {
            var request = try await makeRequest(endpoint)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let observer = transfer.map { TransferTaskDelegate(reporter: $0) }
            let (data, urlResponse) = try await session.upload(for: request, fromFile: file, delegate: observer)
            guard let http = urlResponse as? HTTPURLResponse else { throw GitHubError.network("Non-HTTP response") }
            let rate = RateLimitState(response: http)
            if !(200..<300).contains(http.statusCode) {
                throw Self.mapError(status: http.statusCode, data: data, response: http, rate: rate)
            }
            let value = try GitHubDecoding.decode(T.self, from: data)
            await rateLimiter.release(lane)
            return value
        } catch {
            await rateLimiter.release(lane)
            throw error
        }
    }

    public func request<T: Decodable & Sendable>(_ endpoint: Endpoint) async throws -> Response<T> {
        let raw = try await fetch(endpoint)
        if raw.notModified {
            guard let cached = await etagCache?.body(for: endpoint.cacheKey) else {
                throw GitHubError.decoding("304 without cached body for \(endpoint.cacheKey)")
            }
            let value = try GitHubDecoding.decode(T.self, from: cached)
            return Response(status: raw.status, body: value, etag: raw.etag, rateLimit: raw.rateLimit, notModified: true, headers: raw.headers)
        }
        let value = try GitHubDecoding.decode(T.self, from: raw.body)
        return Response(status: raw.status, body: value, etag: raw.etag, rateLimit: raw.rateLimit, notModified: false, headers: raw.headers)
    }

    public func graphQL<T: Decodable & Sendable>(_ query: String, variables: Data) async throws -> T {
        let variablesObject = try JSONSerialization.jsonObject(with: variables)
        let envelope: [String: Any] = ["query": query, "variables": variablesObject]
        let body = try JSONSerialization.data(withJSONObject: envelope)
        let endpoint = Endpoint(method: .post, path: "/graphql", body: body, category: .graphQL)
        let raw = try await fetch(endpoint)
        if let failure = Self.graphQLFailure(in: raw.body) { throw failure }
        let response = try GitHubDecoding.decode(GraphQLEnvelope<T>.self, from: raw.body)
        guard let data = response.data else {
            throw GitHubError.graphQL(messages: ["empty GraphQL data"])
        }
        return data
    }

    /// Ошибка мутации, когда GitHub кладёт `null` в `data` и текст в `errors`. Иначе декодер прячет причину.
    static func graphQLFailure(in data: Data) -> GitHubError? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let messages = (object["errors"] as? [[String: Any]])?.compactMap { $0["message"] as? String } ?? []
        guard !messages.isEmpty else { return nil }
        if messages.contains(where: isNotFastForward) { return .notFastForward }
        return .graphQL(messages: messages)
    }

    /// Скачивает тело ответа в файл. Лимитер берётся по категории эндпоинта.
    public func download(_ endpoint: Endpoint, to destination: URL) async throws -> Int64 {
        let lane = Self.lane(for: endpoint.category)
        await rateLimiter.acquire(lane)
        let temp: URL
        let urlResponse: URLResponse
        do {
            let request = try await makeRequest(endpoint)
            let box = ByteDownload(reporter: transfer)
            (temp, urlResponse) = try await box.start(request: request)
        } catch let error as GitHubError {
            await rateLimiter.release(lane)
            if case let .rateLimited(retryAfter) = error { await rateLimiter.pause(seconds: retryAfter) }
            throw error
        } catch {
            await rateLimiter.release(lane)
            throw GitHubError.network(error.localizedDescription)
        }
        await rateLimiter.release(lane)
        guard let http = urlResponse as? HTTPURLResponse else { throw GitHubError.network("Non-HTTP response") }
        let rate = RateLimitState(response: http)
        if !(200..<300).contains(http.statusCode) {
            let data = (try? Data(contentsOf: temp)) ?? Data()
            throw Self.mapError(status: http.statusCode, data: data, response: http, rate: rate)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size
    }

    static func isNotFastForward(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("fast forward") || lower.contains("fast-forward")
            || (lower.contains("expected") && lower.contains("branch"))
    }
}

struct GraphQLEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    struct Failure: Decodable, Sendable { var message: String }
    var data: T?
    var errors: [Failure]?
}
