import FileProvider
import UniformTypeIdentifiers

/// Фаза 0: содержимое «папки» в памяти. Удаляется в фазе 3.
final class DemoCatalog: @unchecked Sendable {
    private let readmeID = NSFileProviderItemIdentifier(rawValue: "demo-readme")
    private let readmeText = """
    GitDocumentStorage — Phase 0 demo.
    If you can read this in Finder, the File Provider extension is wired up correctly.
    """

    private lazy var readme = FileProviderItem(
        identifier: readmeID, parent: .rootContainer, filename: "README.txt", contentType: .plainText,
        size: Int64(readmeText.utf8.count), modified: Date(timeIntervalSince1970: 1_759_500_000),
        contentVersion: "demo-v1", metadataRevision: 0, readOnly: true
    )

    private lazy var root = FileProviderItem(
        identifier: .rootContainer, parent: .rootContainer, filename: "Demo", contentType: .folder,
        size: nil, modified: Date(timeIntervalSince1970: 1_759_500_000),
        contentVersion: "root", metadataRevision: 0, readOnly: true
    )

    func item(_ id: NSFileProviderItemIdentifier) -> FileProviderItem? {
        switch id {
        case .rootContainer: return root
        case readmeID: return readme
        default: return nil
        }
    }

    func allItems() -> [FileProviderItem] { [readme] }

    func children(of id: NSFileProviderItemIdentifier) -> [FileProviderItem] {
        id == .rootContainer ? [readme] : []
    }

    func contents(_ id: NSFileProviderItemIdentifier) -> Data? {
        id == readmeID ? Data(readmeText.utf8) : nil
    }
}
