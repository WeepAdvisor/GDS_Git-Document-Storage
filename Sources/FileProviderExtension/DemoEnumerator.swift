import FileProvider

/// Фаза 0: статический перечислитель. Фаза 3: `ContainerEnumerator` (страницы из `ItemStore`)
/// и `WorkingSetEnumerator` (`enumerateChanges` из `change_log`, anchor = revision).
final class DemoEnumerator: NSObject, NSFileProviderEnumerator {
    private let items: [FileProviderItem]
    private let anchor = NSFileProviderSyncAnchor(Data("0".utf8))

    init(items: [FileProviderItem]) {
        self.items = items
        super.init()
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: self.anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(anchor)
    }
}
