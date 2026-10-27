import Foundation

public struct DeviceCodeSession: Sendable, Equatable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURI: URL
    public var expiresIn: Int
    public var interval: Int
}

public enum DeviceFlowEvent: Sendable, Equatable {
    case pending
    case slowDown
    case authorized(token: String, scope: String)
}

public enum DeviceFlowError: Error, Sendable, Equatable {
    case expired
    case denied
    case http(Int, String)
}

/// GitHub Device Flow. Ходит на `github.com/login`, не на API, но живёт в GitHubKit — единственном сетевом слое.
public struct DeviceFlowAuthenticator: Sendable {
    public var clientID: String
    public var session: URLSession

    public init(clientID: String, session: URLSession = .shared) {
        self.clientID = clientID
        self.session = session
    }

    public func start(scope: String = "repo") async throws -> DeviceCodeSession {
        let body = form(["client_id": clientID, "scope": scope])
        let json = try await post(URL(string: "https://github.com/login/device/code")!, body: body)
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let uriString = json["verification_uri"] as? String,
              let uri = URL(string: uriString) else {
            throw DeviceFlowError.http(200, "Malformed device code response")
        }
        return DeviceCodeSession(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: uri,
            expiresIn: json["expires_in"] as? Int ?? 900,
            interval: json["interval"] as? Int ?? 5
        )
    }

    public func poll(_ codeSession: DeviceCodeSession) -> AsyncThrowingStream<DeviceFlowEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var interval = codeSession.interval
                let deadline = Date().addingTimeInterval(TimeInterval(codeSession.expiresIn))
                while Date() < deadline {
                    if Task.isCancelled { continuation.finish(); return }
                    try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                    do {
                        let event = try await pollOnce(codeSession)
                        continuation.yield(event)
                        if case .authorized = event {
                            continuation.finish()
                            return
                        }
                        if case .slowDown = event { interval += 5 }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish(throwing: DeviceFlowError.expired)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func pollOnce(_ codeSession: DeviceCodeSession) async throws -> DeviceFlowEvent {
        let body = form([
            "client_id": clientID,
            "device_code": codeSession.deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])
        let json = try await post(URL(string: "https://github.com/login/oauth/access_token")!, body: body)
        if let token = json["access_token"] as? String {
            return .authorized(token: token, scope: json["scope"] as? String ?? "")
        }
        switch json["error"] as? String {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "expired_token": throw DeviceFlowError.expired
        case "access_denied": throw DeviceFlowError.denied
        default:
            throw DeviceFlowError.http(200, json["error"] as? String ?? "unknown device-flow error")
        }
    }

    private func post(_ url: URL, body: Data) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DeviceFlowError.http(-1, "Non-HTTP") }
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if !(200..<300).contains(http.statusCode) {
            throw DeviceFlowError.http(http.statusCode, object["error"] as? String ?? "HTTP \(http.statusCode)")
        }
        return object
    }

    private func form(_ fields: [String: String]) -> Data {
        let encoded = fields.map { key, value in
            "\(escape(key))=\(escape(value))"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    private func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
