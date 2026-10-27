import FileProvider
import SyncCore

/// File Provider отдаёт observer в синхронный метод и ждёт колбэк позже. Протокол не `Sendable`.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

final class LiveEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let engine: SyncEngine
    private let container: NSFileProviderItemIdentifier
    private let domainID: String
    private let pageSize = 500

    init(engine: SyncEngine, container: NSFileProviderItemIdentifier, domainID: String) {
        self.engine = engine
        self.container = container
        self.domainID = domainID
        super.init()
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let engine = self.engine
        let container = self.container
        let pageSize = self.pageSize
        let start = Self.offset(of: page)
        let boxed = UncheckedSendable(value: observer)
        Task {
            do {
                if container == .rootContainer {
                    try await engine.ensureInitialLoad()
                }
                let items = try await Self.load(engine: engine, container: container)
                let end = min(start + pageSize, items.count)
                boxed.value.didEnumerate(items[start..<end].map { FileProviderItem(snapshot: $0) })
                if end < items.count {
                    boxed.value.finishEnumerating(upTo: NSFileProviderPage(Data("\(end)".utf8)))
                } else {
                    boxed.value.finishEnumerating(upTo: nil)
                }
            } catch {
                boxed.value.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let engine = self.engine
        let boxed = UncheckedSendable(value: observer)
        let domainID = self.domainID
        Task {
            do {
                let defaults = (try? SharedPaths(bundle: .main))?.userDefaults
                if let id = UUID(uuidString: domainID), SharedDefaultsKey.consumeSyncRequest(id, defaults: defaults) {
                    await engine.syncNow()
                } else {
                    try await engine.pullRemote()
                }
                let revision = Int(String(data: anchor.rawValue, encoding: .utf8) ?? "") ?? 0
                let page = try await engine.changes(since: revision)
                if page.expired {
                    boxed.value.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                    return
                }
                if !page.upserts.isEmpty {
                    let snapshots = try await engine.allVisible().filter { item in page.upserts.contains { $0.id == item.id } }
                    boxed.value.didUpdate(snapshots.map { FileProviderItem(snapshot: $0) })
                }
                if !page.deletedIDs.isEmpty {
                    boxed.value.didDeleteItems(withIdentifiers: page.deletedIDs.map { NSFileProviderItemIdentifier($0) })
                }
                let current = try await engine.currentRevision()
                boxed.value.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(Data("\(current)".utf8)), moreComing: false)
            } catch {
                boxed.value.finishEnumeratingWithError(error)
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let engine = self.engine
        let boxed = UncheckedSendable(value: completionHandler)
        Task {
            let revision = (try? await engine.currentRevision()) ?? 0
            boxed.value(NSFileProviderSyncAnchor(Data("\(revision)".utf8)))
        }
    }

    private static func load(engine: SyncEngine, container: NSFileProviderItemIdentifier) async throws -> [ItemSnapshot] {
        if container == .workingSet { return try await engine.allVisible() }
        let parent = container == .rootContainer ? "NSFileProviderRootContainerItemIdentifier" : container.rawValue
        return try await engine.children(parentID: parent)
    }

    private static func offset(of page: NSFileProviderPage) -> Int {
        Int(String(data: page.rawValue, encoding: .utf8) ?? "") ?? 0
    }
}
