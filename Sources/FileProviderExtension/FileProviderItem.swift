import FileProvider
import UniformTypeIdentifiers

/// Элемент, отдаваемый системе. Фаза 3: конструировать из строки `items` БД (docs/02 §3).
final class FileProviderItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let itemVersion: NSFileProviderItemVersion
    let documentSize: NSNumber?
    let contentModificationDate: Date?
    let creationDate: Date?
    let isUploaded: Bool
    let isUploading: Bool

    var isFolder: Bool { contentType == .folder }

    init(identifier: NSFileProviderItemIdentifier, parent: NSFileProviderItemIdentifier, filename: String,
         contentType: UTType, size: Int64?, modified: Date, contentVersion: String, metadataRevision: Int,
         readOnly: Bool, isUploading: Bool = false) {
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parent
        self.filename = filename
        self.contentType = contentType
        self.documentSize = size.map { NSNumber(value: $0) }
        self.contentModificationDate = modified
        self.creationDate = modified
        self.itemVersion = NSFileProviderItemVersion(contentVersion: Data(contentVersion.utf8),
                                                     metadataVersion: Data("\(metadataRevision)".utf8))
        self.isUploaded = !isUploading
        self.isUploading = isUploading

        var caps: NSFileProviderItemCapabilities = [.allowsReading]
        if contentType == .folder { caps.insert(.allowsContentEnumerating) }
        if !readOnly {
            caps.formUnion([.allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting])
            if contentType == .folder { caps.insert(.allowsAddingSubItems) }
        }
        self.capabilities = caps
        super.init()
    }
}
