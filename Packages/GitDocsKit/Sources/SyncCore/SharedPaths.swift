import Foundation

/// Пути в контейнере App Group, общие для приложения и расширения (docs/01 §4).
public struct SharedPaths: Sendable {
    public let appGroupID: String
    public let containerURL: URL

    public enum Error: Swift.Error { case missingAppGroupID, containerUnavailable(String) }

    /// Читает `GDSAppGroupID` из Info.plist текущего бандла (заполняется XcodeGen из xcconfig).
    public init(bundle: Bundle = .main) throws {
        guard let id = bundle.object(forInfoDictionaryKey: "GDSAppGroupID") as? String, !id.isEmpty else {
            throw Error.missingAppGroupID
        }
        try self.init(appGroupID: id)
    }

    public init(appGroupID: String) throws {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw Error.containerUnavailable(appGroupID)
        }
        self.appGroupID = appGroupID
        self.containerURL = url
    }

    /// Для тестов: произвольный каталог вместо контейнера группы.
    public init(testingContainer url: URL) {
        appGroupID = "test"
        containerURL = url
    }

    public var domainsRoot: URL { containerURL.appending(path: "Library/Application Support/Domains", directoryHint: .isDirectory) }
    public func domainDirectory(_ domainID: UUID) -> URL { domainsRoot.appending(path: domainID.uuidString, directoryHint: .isDirectory) }
    public func storeURL(_ domainID: UUID) -> URL { domainDirectory(domainID).appending(path: "store.sqlite") }
    public func stagingDirectory(_ domainID: UUID) -> URL { domainDirectory(domainID).appending(path: "staging", directoryHint: .isDirectory) }
    public func stagingURL(_ domainID: UUID, opID: UUID) -> URL { stagingDirectory(domainID).appending(path: opID.uuidString) }
    public func blobCacheDirectory(_ domainID: UUID) -> URL { domainDirectory(domainID).appending(path: "blobcache", directoryHint: .isDirectory) }
    public var reposConfigURL: URL { containerURL.appending(path: "Library/Application Support/repos.json") }

    public func ensureDomainDirectories(_ domainID: UUID) throws {
        try FileManager.default.createDirectory(at: stagingDirectory(domainID), withIntermediateDirectories: true)
    }

    public var userDefaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }
}

/// Ключи App Group UserDefaults, разделяемые между процессами.
public enum SharedDefaultsKey {
    public static let heartbeatAt = "heartbeatAt"
    public static let lastActivityAt = "lastActivityAt"
    public static func knownRemoteHead(_ domainID: UUID) -> String { "knownRemoteHead.\(domainID.uuidString)" }
    public static let strictUnavailabilityMode = "strictUnavailabilityMode"
    public static func syncRequest(_ domainID: UUID) -> String { "syncRequest.\(domainID.uuidString)" }
    public static func syncRequestSeen(_ domainID: UUID) -> String { "syncRequestSeen.\(domainID.uuidString)" }

    /// Приложение просит расширение немедленно вытянуть GitHub и выгрузить очередь.
    public static func postSyncRequest(_ domainID: UUID, defaults: UserDefaults?) {
        defaults?.set(Date().timeIntervalSince1970, forKey: syncRequest(domainID))
        defaults?.synchronize()
    }

    /// `true` ровно один раз на каждый `postSyncRequest`.
    public static func consumeSyncRequest(_ domainID: UUID, defaults: UserDefaults?) -> Bool {
        let stamp = defaults?.double(forKey: syncRequest(domainID)) ?? 0
        guard stamp > 0 else { return false }
        let seen = defaults?.double(forKey: syncRequestSeen(domainID)) ?? 0
        guard stamp > seen else { return false }
        defaults?.set(stamp, forKey: syncRequestSeen(domainID))
        defaults?.synchronize()
        return true
    }
}

/// Идентификатор пункта «Sync Now» в контекстном меню Finder.
public enum SyncCommand {
    public static let actionIdentifier = "com.nasonov.gitdocumentstorage.syncNow"
}
