import AppKit

final class ShelfServiceProvider: NSObject {
    private let onAddURLs: ([URL]) -> Void

    init(onAddURLs: @escaping ([URL]) -> Void) {
        self.onAddURLs = onAddURLs
    }

    @objc(addToShelf:userData:error:)
    func addToShelf(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        var urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] ?? [])
            .map { $0 as URL }

        if urls.isEmpty {
            let legacyType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
            if let paths = pasteboard.propertyList(forType: legacyType) as? [String] {
                urls = paths.map(URL.init(fileURLWithPath:))
            }
        }

        guard !urls.isEmpty else {
            error.pointee = L10n.string("FindAll did not receive any file or folder URLs.") as NSString
            return
        }

        DispatchQueue.main.async { [onAddURLs] in onAddURLs(urls) }
    }
}
