import Foundation

public struct AppConfiguration: Codable, Sendable, Equatable {
    public var accounts: [Account]
    public var repos: [RepoConfig]
    /// Перекрывает Client ID из бандла, если OAuth App зарегистрирован позже сборки.
    public var oauthClientID: String?

    public init(accounts: [Account] = [], repos: [RepoConfig] = [], oauthClientID: String? = nil) {
        self.accounts = accounts
        self.repos = repos
        self.oauthClientID = oauthClientID
    }

    private enum CodingKeys: String, CodingKey { case accounts, repos, oauthClientID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        repos = try container.decodeIfPresent([RepoConfig].self, forKey: .repos) ?? []
        oauthClientID = try container.decodeIfPresent(String.self, forKey: .oauthClientID)
    }
}

public struct RepoConfigStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    /// App Group, если контейнер доступен, иначе `~/Library/Application Support/GitDocumentStorage`.
    public static func resolve(bundle: Bundle = .main) -> RepoConfigStore {
        if let paths = try? SharedPaths(bundle: bundle) {
            return RepoConfigStore(fileURL: paths.reposConfigURL)
        }
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/GitDocumentStorage/repos.json")
        return RepoConfigStore(fileURL: fallback)
    }

    public func load() throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AppConfiguration() }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppConfiguration.self, from: data)
    }

    public func save(_ configuration: AppConfiguration) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(configuration)
        try data.write(to: fileURL, options: .atomic)
    }

    public func repo(id: UUID) throws -> RepoConfig? {
        try load().repos.first { $0.id == id }
    }
}
