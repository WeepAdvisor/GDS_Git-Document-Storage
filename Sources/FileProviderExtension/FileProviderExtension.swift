import FileProvider
import GitHubKit
import os
import Persistence
import SyncCore

/// Демо-домен «demo» остаётся в памяти. Остальные домены — реальный `SyncEngine`.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderCustomAction {
    let domain: NSFileProviderDomain
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GitDocumentStorage.ext", category: "ext")
    private let catalog = DemoCatalog()
    private let engine: SyncEngine?
    private let usesDemo: Bool

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let raw = domain.identifier.rawValue
        usesDemo = raw == "demo"
        if usesDemo {
            engine = nil
        } else {
            engine = Self.makeEngine(domainID: raw, domain: domain)
        }
        super.init()
        CrashReporter.shared.start(process: "file-provider")
        logger.info("Extension started for domain \(raw, privacy: .public) engine=\(self.engine == nil ? "demo-or-missing" : "live", privacy: .public)")
    }

    func invalidate() {
        logger.info("Extension invalidated for domain \(self.domain.identifier.rawValue, privacy: .public)")
    }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if usesDemo {
            completionHandler(catalog.item(identifier), catalog.item(identifier) == nil ? NSFileProviderError(.noSuchItem) : nil)
            return Progress()
        }
        guard let engine else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        let rawID = identifier.rawValue
        let finish = UncheckedSendable(value: completionHandler)
        Task {
            do {
                guard let snapshot = try await engine.snapshot(id: rawID) else {
                    finish.value(nil, NSFileProviderError(.noSuchItem))
                    return
                }
                finish.value(FileProviderItem(snapshot: snapshot), nil)
            } catch {
                finish.value(nil, error)
            }
        }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        if usesDemo {
            guard let item = catalog.item(itemIdentifier), let data = catalog.contents(itemIdentifier) else {
                completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
                return Progress()
            }
            do {
                let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                try data.write(to: url)
                completionHandler(url, item, nil)
            } catch {
                completionHandler(nil, nil, error)
            }
            return Progress()
        }
        guard let engine else {
            completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
            return Progress()
        }
        return Self.hopFetch(engine: engine, rawID: itemIdentifier.rawValue, finish: UncheckedSendable(value: completionHandler))
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        guard let engine else {
            completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
            return Progress()
        }
        return Self.hopCreate(
            engine: engine,
            parent: itemTemplate.parentItemIdentifier.rawValue,
            name: itemTemplate.filename,
            isDirectory: itemTemplate.contentType == .folder,
            staged: url.flatMap { try? Self.copyImmediately($0) },
            finish: UncheckedSendable(value: completionHandler)
        )
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        guard let engine else {
            completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
            return Progress()
        }
        return Self.hopModify(
            engine: engine,
            id: item.itemIdentifier.rawValue,
            staged: newContents.flatMap { try? Self.copyImmediately($0) },
            contentsChanged: changedFields.contains(.contents),
            renamed: changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier),
            newName: item.filename,
            newParent: item.parentItemIdentifier.rawValue,
            finish: UncheckedSendable(value: completionHandler)
        )
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        guard let engine else {
            completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
            return Progress()
        }
        return Self.hopDelete(engine: engine, rawID: identifier.rawValue, finish: UncheckedSendable(value: completionHandler))
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if usesDemo {
            switch containerItemIdentifier {
            case .rootContainer, .workingSet:
                return DemoEnumerator(items: catalog.allItems())
            default:
                return DemoEnumerator(items: catalog.children(of: containerItemIdentifier))
            }
        }
        guard let engine else { throw NSFileProviderError(.noSuchItem) }
        return LiveEnumerator(engine: engine, container: containerItemIdentifier, domainID: domain.identifier.rawValue)
    }

    func performAction(identifier: NSFileProviderExtensionActionIdentifier,
                       onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                       completionHandler: @escaping (Error?) -> Void) -> Progress {
        let finish = UncheckedSendable(value: completionHandler)
        guard identifier.rawValue == SyncCommand.actionIdentifier, let engine else {
            finish.value(nil)
            return Progress()
        }
        Task {
            await engine.syncNow()
            finish.value(nil)
        }
        return Progress()
    }

    private static func makeEngine(domainID: String, domain: NSFileProviderDomain) -> SyncEngine? {
        guard let id = UUID(uuidString: domainID),
              let paths = try? SharedPaths(bundle: .main),
              let config = try? RepoConfigStore(fileURL: paths.reposConfigURL).repo(id: id),
              let store = try? DomainStore(at: paths.storeURL(id)) else { return nil }
        let tokens = KeychainTokenStore.fromBundle()
        let accountID = config.accountID
        let transfer = TransferReporter()
        let repoID = id
        transfer.onChange = { direction, done, total in
            let mapped: SyncDirection = direction == .upload ? .upload : .download
            SyncActivity.setBytes(domain: repoID, direction: mapped, done: done, total: total)
        }
        let client = GitHubClient(transfer: transfer) {
            guard let token = try await tokens.token(for: accountID) else { throw GitHubError.unauthorized }
            return token
        }
        let remote = GitHubRemoteRepository(owner: config.owner, repo: config.repo, branch: config.branch, client: client)
        let mainID = Bundle.main.object(forInfoDictionaryKey: "GDSMainAppBundleID") as? String ?? ""
        let engine = SyncEngine(
            config: config, domain: store, remote: remote, stagingDirectory: paths.stagingDirectory(id),
            isAppAlive: {
                AppLiveness(mainAppBundleID: mainID, defaultsSuiteName: paths.appGroupID).isAlive
            }
        )
        let domainRaw = domain.identifier.rawValue
        Task {
            await engine.setSyncHandler {
                Task {
                    let identifier = NSFileProviderDomainIdentifier(rawValue: domainRaw)
                    let domains = try? await NSFileProviderManager.domains()
                    guard let match = domains?.first(where: { $0.identifier == identifier }) else { return }
                    try? await NSFileProviderManager(for: match)?.signalEnumerator(for: .workingSet)
                }
            }
            await engine.resumePendingUploads()
        }
        return engine
    }

    private static func hopFetch(engine: SyncEngine, rawID: String, finish: UncheckedSendable<(URL?, NSFileProviderItem?, Error?) -> Void>) -> Progress {
        Task { await fetch(engine: engine, rawID: rawID, finish: finish) }
        return Progress()
    }

    private static func hopCreate(engine: SyncEngine, parent: String, name: String, isDirectory: Bool, staged: URL?,
                                  finish: UncheckedSendable<(NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void>) -> Progress {
        Task { await create(engine: engine, parent: parent, name: name, isDirectory: isDirectory, staged: staged, finish: finish) }
        return Progress()
    }

    private static func hopModify(engine: SyncEngine, id: String, staged: URL?, contentsChanged: Bool, renamed: Bool, newName: String, newParent: String,
                                  finish: UncheckedSendable<(NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void>) -> Progress {
        Task {
            await modify(engine: engine, id: id, staged: staged, contentsChanged: contentsChanged, renamed: renamed, newName: newName, newParent: newParent, finish: finish)
        }
        return Progress()
    }

    private static func hopDelete(engine: SyncEngine, rawID: String, finish: UncheckedSendable<(Error?) -> Void>) -> Progress {
        Task { await remove(engine: engine, rawID: rawID, finish: finish) }
        return Progress()
    }

    private static func fetch(engine: SyncEngine, rawID: String, finish: UncheckedSendable<(URL?, NSFileProviderItem?, Error?) -> Void>) async {
        do {
            let url = try await engine.fetchContents(itemID: rawID)
            let snapshot = try await engine.snapshot(id: rawID)
            finish.value(url, snapshot.map(FileProviderItem.init(snapshot:)), nil)
        } catch {
            finish.value(nil, nil, fileError(error, path: rawID))
        }
    }

    private static func create(engine: SyncEngine, parent: String, name: String, isDirectory: Bool, staged: URL?,
                               finish: UncheckedSendable<(NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void>) async {
        do {
            let snapshot = try await engine.createItem(parentID: parent, name: name, isDirectory: isDirectory, stagedCopy: staged)
            finish.value(FileProviderItem(snapshot: snapshot), [], false, nil)
        } catch {
            finish.value(nil, [], false, fileError(error, path: name))
        }
    }

    private static func modify(engine: SyncEngine, id: String, staged: URL?, contentsChanged: Bool, renamed: Bool, newName: String, newParent: String,
                               finish: UncheckedSendable<(NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void>) async {
        do {
            var snapshot: ItemSnapshot?
            if contentsChanged, let staged {
                snapshot = try await engine.modifyContents(id: id, stagedCopy: staged)
            }
            if renamed {
                snapshot = try await engine.rename(id: id, newParentID: newParent, newName: newName)
            }
            guard let snapshot else {
                finish.value(nil, [], false, NSFileProviderError(.noSuchItem))
                return
            }
            finish.value(FileProviderItem(snapshot: snapshot), [], false, nil)
        } catch {
            finish.value(nil, [], false, fileError(error, path: newName))
        }
    }

    private static func remove(engine: SyncEngine, rawID: String, finish: UncheckedSendable<(Error?) -> Void>) async {
        do {
            try await engine.delete(id: rawID)
            finish.value(nil)
        } catch {
            finish.value(fileError(error, path: rawID))
        }
    }

    private static func copyImmediately(_ url: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appending(path: "gds-stage-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    private static func fileError(_ error: Error, path: String? = nil) -> Error {
        ProblemLog.record(kind: "fileProvider", message: String(describing: error), path: path)
        if let sync = error as? SyncError {
            switch sync {
            case .appNotRunning: return NSFileProviderError(.serverUnreachable)
            case .readOnlyRepository: return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            case .itemNotFound: return NSFileProviderError(.noSuchItem)
            default: return NSFileProviderError(.serverUnreachable)
            }
        }
        return error
    }
}
