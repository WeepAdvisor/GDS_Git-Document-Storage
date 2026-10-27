import Foundation
import Persistence

/// Файлы, которые останутся в папке, но на GitHub не уйдут из‑за лимита размера.
public struct OversizedFile: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var domainID: UUID
    public var domainName: String
    public var path: String
    public var bytes: Int64

    public init(id: String, domainID: UUID, domainName: String, path: String, bytes: Int64) {
        self.id = id
        self.domainID = domainID
        self.domainName = domainName
        self.path = path
        self.bytes = bytes
    }
}

public enum LimitReport {
    private static let fileName = "over-limit.json"

    public static func record(_ file: OversizedFile, container: URL? = nil) {
        var files = load(container: container).filter { $0.id != file.id && $0.path != file.path }
        files.append(file)
        save(files, container: container)
    }

    public static func remove(itemID: String, container: URL? = nil) {
        save(load(container: container).filter { $0.id != itemID }, container: container)
    }

    /// Список из баз доменов: всё, что больше лимита GitHub и не в очереди на выгрузку.
    public static func refresh(container: URL? = nil) -> [OversizedFile] {
        guard let paths = container.map({ SharedPaths(testingContainer: $0) }) ?? (try? SharedPaths()) else {
            return load(container: container)
        }
        let repos = (try? RepoConfigStore(fileURL: paths.reposConfigURL).load().repos) ?? []
        let limit = CommitLimits.default.gitHubMaxBlobBytes
        var found: [OversizedFile] = []
        for repo in repos {
            guard let store = try? DomainStore(at: paths.storeURL(repo.id)) else { continue }
            let items = (try? ItemStore(domain: store).items(in: [.uploadFailed])) ?? []
            for item in items where !item.isDirectory && item.size > limit {
                found.append(OversizedFile(id: item.id, domainID: repo.id, domainName: repo.displayName, path: item.path, bytes: item.size))
            }
        }
        let sorted = found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        save(sorted, container: container)
        return sorted
    }

    public static func load(container: URL? = nil) -> [OversizedFile] {
        guard let url = fileURL(container) else { return [] }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([OversizedFile].self, from: data)) ?? []
    }

    private static func save(_ files: [OversizedFile], container: URL?) {
        guard let url = fileURL(container) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(files) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func fileURL(_ container: URL?) -> URL? {
        let root = container ?? (try? SharedPaths())?.containerURL
        return root?.appending(path: "Library/Application Support").appending(path: fileName)
    }
}
