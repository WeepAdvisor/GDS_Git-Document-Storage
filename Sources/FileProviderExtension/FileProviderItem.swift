import FileProvider
import SyncCore
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
    let uploadingError: NSError?

    var isFolder: Bool { contentType == .folder }

    init(identifier: NSFileProviderItemIdentifier, parent: NSFileProviderItemIdentifier, filename: String,
         contentType: UTType, size: Int64?, modified: Date, contentVersion: String, metadataRevision: Int,
         readOnly: Bool, isUploading: Bool = false, uploadFailed: Bool = false) {
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parent
        self.filename = filename
        self.contentType = contentType
        self.documentSize = size.map { NSNumber(value: $0) }
        self.contentModificationDate = modified
        self.creationDate = modified
        self.itemVersion = NSFileProviderItemVersion(contentVersion: Data(contentVersion.utf8),
                                                     metadataVersion: Data("\(metadataRevision)".utf8))
        self.isUploaded = !isUploading && !uploadFailed
        self.isUploading = isUploading
        self.uploadingError = uploadFailed
            ? NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSLocalizedDescriptionKey: "Upload failed"])
            : nil

        var caps: NSFileProviderItemCapabilities = [.allowsReading]
        if contentType == .folder { caps.insert(.allowsContentEnumerating) }
        if !readOnly {
            caps.formUnion([.allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting])
            if contentType == .folder { caps.insert(.allowsAddingSubItems) }
        }
        self.capabilities = caps
        super.init()
    }

    convenience init(snapshot: ItemSnapshot) {
        let identifier = snapshot.id == "NSFileProviderRootContainerItemIdentifier"
            ? NSFileProviderItemIdentifier.rootContainer
            : NSFileProviderItemIdentifier(snapshot.id)
        let parent = snapshot.parentID == "NSFileProviderRootContainerItemIdentifier" || snapshot.parentID == snapshot.id
            ? NSFileProviderItemIdentifier.rootContainer
            : NSFileProviderItemIdentifier(snapshot.parentID)
        self.init(
            identifier: identifier, parent: parent, filename: snapshot.name,
            contentType: snapshot.isDirectory ? .folder : UTType(filenameExtension: (snapshot.name as NSString).pathExtension) ?? .data,
            size: snapshot.isDirectory || snapshot.sizeIsUnknown ? nil : snapshot.size, modified: snapshot.modified,
            contentVersion: snapshot.contentVersion, metadataRevision: snapshot.metadataRevision,
            readOnly: snapshot.readOnly, isUploading: snapshot.isUploading, uploadFailed: snapshot.uploadFailed
        )
    }
}
