import AppKit
import Darwin

/// iCloud actions shared by the search, folder, and shelf menus.
final class CloudDownloadMenu: NSObject, NSMenuItemValidation {
    private let selection: () -> [URL]
    private var busy = false
#if DEBUG
    private static let logLock = NSLock()
#endif

    private static func log(_ message: String) {
#if DEBUG
        logLock.lock()
        defer { logLock.unlock() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FindAll-iCloud-debug.log")
        let data = Data("\(ISO8601DateFormatter().string(from: Date())) pid=\(ProcessInfo.processInfo.processIdentifier) \(message)\n".utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
#endif
    }
    // Experimental: this system-owned attribute is not a documented pinning API.
    private static let pinAttribute = "com.apple.fileprovider.pinned#PX"

    init(selection: @escaping () -> [URL]) {
        self.selection = selection
    }

    func append(to menu: NSMenu) {
        menu.addItem(.separator())
        for (title, action) in [
            ("Download Now", #selector(download(_:))),
            ("Keep Downloaded", #selector(togglePin(_:))),
            ("Remove Download", #selector(evict(_:)))
        ] {
            let item = menu.addItem(withTitle: L10n.string(title), action: action, keyEquivalent: "")
            item.target = self
        }
    }

    private func isCloudItem(_ url: URL) -> Bool {
        // Do not follow aliases/symlinks into unrelated locations.
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true else { return false }
        return values.isUbiquitousItem == true
    }

    private static func isPinned(_ url: URL) -> Bool {
        var value: UInt8 = 0
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, pinAttribute, &value, 1, 0, XATTR_NOFOLLOW) == 1 && value == 0x31
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let urls = selection()
        item.state = .off
        guard !busy, !urls.isEmpty else { return false }
        if item.action == #selector(togglePin(_:)) {
            guard #available(macOS 15.0, *) else { return false }
            let pinnedCount = urls.filter { Self.isEffectivelyPinned($0) }.count
            item.state = pinnedCount == urls.count ? .on : (pinnedCount == 0 ? .off : .mixed)
            if let inherited = urls.first(where: { !Self.isPinned($0) && Self.pinnedAncestor(of: $0) != nil }),
               let parent = Self.pinnedAncestor(of: inherited) {
                item.toolTip = L10n.string("Kept downloaded by parent folder:") + " " + parent.path
            } else { item.toolTip = nil }
            // Unpin must remain available even if iCloud resource metadata is temporarily unavailable.
            return pinnedCount == urls.count || urls.allSatisfy(isCloudItem)
        }
        guard urls.allSatisfy(isCloudItem) else { return false }
        if item.action == #selector(evict(_:)) {
            return urls.allSatisfy {
                guard !Self.isEffectivelyPinned($0),
                      let values = try? $0.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemDownloadingStatusKey]) else { return false }
                return values.ubiquitousItemIsUploaded == true && values.ubiquitousItemIsUploading != true
                    && values.ubiquitousItemDownloadingStatus != .notDownloaded
            }
        }
        return true
    }

    /// A child can be kept downloaded through a pinned ancestor without its own xattr.
    private static func pinnedAncestor(of url: URL) -> URL? {
        var parent = url.deletingLastPathComponent()
        while parent.path != "/" {
            if isPinned(parent) { return parent }
            parent.deleteLastPathComponent()
        }
        return nil
    }

    private static func isEffectivelyPinned(_ url: URL) -> Bool {
        isPinned(url) || pinnedAncestor(of: url) != nil
    }

    private static func setPinned(_ pinned: Bool, at url: URL) throws {
        if !pinned, let ancestor = pinnedAncestor(of: url) {
            throw NSError(domain: "FindAll.iCloud", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L10n.string("This item is kept downloaded by its parent folder. Turn off Keep Downloaded on that folder:") + "\n" + ancestor.path
            ])
        }
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .contentIndependentMetadataOnly, error: &coordinationError) { coordinatedURL in
            do {
                try coordinatedURL.withUnsafeFileSystemRepresentation { path in
                    guard let path else { throw CocoaError(.fileReadInvalidFileName) }
                    var value: UInt8 = 0x31
                    let result = pinned
                        ? setxattr(path, pinAttribute, &value, 1, 0, XATTR_NOFOLLOW)
                        : removexattr(path, pinAttribute, XATTR_NOFOLLOW)
                    if result != 0 {
                        let code = errno
                        if !pinned && code == ENOATTR { return }
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                    }
                }
            } catch { operationError = error }
        }
        if let error = coordinationError { throw error }
        if let error = operationError { throw error }
        // File Provider updates asynchronously. A local xattr check is not proof of
        // provider completion, but a delayed recheck catches reverted local changes.
        Thread.sleep(forTimeInterval: 1)
        guard isPinned(url) == pinned else { throw CocoaError(.fileWriteUnknown) }
    }

    @objc private func download(_ sender: NSMenuItem) { perform(sender, operation: .download) }
    @objc private func togglePin(_ sender: NSMenuItem) {
        let urls = selection()
        let allPinned = !urls.isEmpty && urls.allSatisfy { Self.isEffectivelyPinned($0) }
        perform(sender, operation: allPinned ? .unpin : .pin)
    }
    @objc private func evict(_ sender: NSMenuItem) { perform(sender, operation: .evict) }

    private enum Operation { case download, pin, unpin, evict }

    private func perform(_ sender: NSMenuItem, operation: Operation) {
        guard validateMenuItem(sender) else {
            Self.log("ignored operation=\(operation) busy=\(busy) urls=\(selection().map(\.path))")
            return
        }
        let urls = selection()
        Self.log("start operation=\(operation) urls=\(urls.map(\.path))")
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var failures: [String] = []
            for url in urls {
                do {
                    // Removing the pin does not require an iCloud metadata lookup to succeed.
                    if operation != .unpin {
                        guard isCloudItem(url) else { throw CocoaError(.fileReadUnsupportedScheme) }
                    }
                    switch operation {
                    case .download: try FileManager.default.startDownloadingUbiquitousItem(at: url)
                    case .pin:
                        try Self.setPinned(true, at: url)
                        // A pin flag alone does not indicate completed download.
                        try FileManager.default.startDownloadingUbiquitousItem(at: url)
                    case .unpin: try Self.setPinned(false, at: url)
                    case .evict:
                        guard !Self.isEffectivelyPinned(url) else { throw CocoaError(.fileWriteNoPermission) }
                        try FileManager.default.evictUbiquitousItem(at: url)
                    }
                    Self.log("completed operation=\(operation) path=\(url.path) ownPin=\(Self.isPinned(url)) inherited=\(Self.pinnedAncestor(of: url)?.path ?? "none")")
                } catch {
                    Self.log("failed operation=\(operation) path=\(url.path) error=\(error)")
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async { [self] in
                busy = false
                if !failures.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = L10n.string("iCloud Operation Failed")
                    alert.informativeText = failures.joined(separator: "\n")
                    alert.runModal()
                }
            }
        }
    }
}
