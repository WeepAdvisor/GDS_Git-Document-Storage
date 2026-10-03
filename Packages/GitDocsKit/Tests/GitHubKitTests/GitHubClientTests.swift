import XCTest
@testable import GitHubKit

final class GitHubClientTests: XCTestCase {
    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.github.com/x")!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    func testRateLimitStateParsesHeaders() {
        let http = response(403, headers: [
            "x-ratelimit-limit": "5000", "x-ratelimit-remaining": "0", "x-ratelimit-reset": "1700000000",
            "x-ratelimit-resource": "core",
        ])
        let state = RateLimitState(response: http)
        XCTAssertEqual(state.limit, 5000)
        XCTAssertEqual(state.remaining, 0)
        XCTAssertEqual(state.resetAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(state.resource, "core")
        let delay = state.recommendedDelay(now: Date(timeIntervalSince1970: 1_699_999_940), isSecondaryLimit: false)
        XCTAssertEqual(delay, 60)
    }

    func testRetryAfterWins() {
        let state = RateLimitState(remaining: 100, retryAfter: 17)
        XCTAssertEqual(state.recommendedDelay(isSecondaryLimit: true), 17)
    }

    func testSecondaryLimitDefaultsToMinute() {
        XCTAssertEqual(RateLimitState().recommendedDelay(isSecondaryLimit: true), 60)
        XCTAssertNil(RateLimitState().recommendedDelay(isSecondaryLimit: false))
    }

    func testErrorMapping() {
        let json = #"{"message":"Update is not a fast forward","documentation_url":"x"}"#.data(using: .utf8)!
        XCTAssertEqual(GitHubClient.mapError(status: 422, data: json, response: response(422), rate: .init()), .notFastForward)

        let empty = #"{"message":"Git Repository is empty."}"#.data(using: .utf8)!
        XCTAssertEqual(GitHubClient.mapError(status: 409, data: empty, response: response(409), rate: .init()), .emptyRepository)

        XCTAssertEqual(GitHubClient.mapError(status: 401, data: Data(), response: response(401), rate: .init()), .unauthorized)
        XCTAssertEqual(GitHubClient.mapError(status: 404, data: Data(), response: response(404), rate: .init()), .notFound)

        let limited = #"{"message":"API rate limit exceeded"}"#.data(using: .utf8)!
        let http = response(403, headers: ["retry-after": "30"])
        XCTAssertEqual(GitHubClient.mapError(status: 403, data: limited, response: http, rate: .init(response: http)), .rateLimited(retryAfter: 30))

        let sso = response(403, headers: ["X-GitHub-SSO": "required; url=https://github.com/orgs/acme/sso?authorization_request=abc"])
        XCTAssertEqual(GitHubClient.mapError(status: 403, data: Data(), response: sso, rate: .init()),
                       .ssoRequired(authorizationURL: URL(string: "https://github.com/orgs/acme/sso?authorization_request=abc")))
    }

    func testRequestHeaders() async throws {
        let client = GitHubClient(tokenProvider: { "tok" })
        let endpoint = Endpoint(method: .get, path: "/repos/o/r/git/ref/heads/main", usesETag: true)
        let request = try await client.makeRequest(endpoint, ifNoneMatch: "\"etag\"")
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/o/r/git/ref/heads/main")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"etag\"")
        XCTAssertEqual(endpoint.cacheKey, "GET /repos/o/r/git/ref/heads/main")
    }
}
