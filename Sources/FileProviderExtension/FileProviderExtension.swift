import FileProvider
import os
import SyncCore

/// Фаза 0: демонстрационный провайдер с одним файлом в памяти.
/// Фаза 3+: заменить `DemoCatalog` на `SyncEngine` + `ItemStore` (см. docs/00-PLAN.md).
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GitDocumentStorage.ext", category: "ext")
    private let catalog = DemoCatalog()

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        logger.info("Extension started for domain \(domain.identifier.rawValue, privacy: .public)")
    }

    func invalidate() {
        logger.info("Extension invalidated for domain \(self.domain.identifier.rawValue, privacy: .public)")
    }

    // MARK: - Reading

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if let item = catalog.item(identifier) {
            completionHandler(item, nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        guard let item = catalog.item(itemIdentifier), let data = catalog.contents(itemIdentifier) else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        do {
            let tmp = try NSFileProviderManager(for: domain)?.temporaryDirectoryURL()
                ?? FileManager.default.temporaryDirectory
            let url = tmp.appending(path: UUID().uuidString)
            try data.write(to: url)
            completionHandler(url, item, nil)
        } catch {
            completionHandler(nil, nil, error)
        }
        return Progress()
    }

    // MARK: - Writing (фаза 4). Фаза 0 — только чтение.

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
        return Progress()
    }

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        switch containerItemIdentifier {
        case .rootContainer, .workingSet:
            return DemoEnumerator(items: catalog.allItems())
        case .trashContainer:
            throw NSFileProviderError(.noSuchItem)
        default:
            guard let item = catalog.item(containerItemIdentifier), item.isFolder else {
                throw NSFileProviderError(.noSuchItem)
            }
            return DemoEnumerator(items: catalog.children(of: containerItemIdentifier))
        }
    }
}
