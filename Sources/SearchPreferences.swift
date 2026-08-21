import AppKit
import Foundation

enum SearchCategory: String, CaseIterable, Codable {
    case all
    case folder
    case application
    case video
    case audio
    case image
    case document
    case presentation
    case word
    case excel
    case pdf
    case archive

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .folder: return String(localized: "Folders")
        case .application: return String(localized: "Applications")
        case .video: return String(localized: "Videos")
        case .audio: return String(localized: "Audio")
        case .image: return String(localized: "Images")
        case .document: return String(localized: "Documents")
        case .presentation: return "PPT"
        case .word: return "Word"
        case .excel: return "Excel"
        case .pdf: return "PDF"
        case .archive: return String(localized: "Archives")
        }
    }

    var metadataPredicate: NSPredicate? {
        let typeTree = NSMetadataItemContentTypeTreeKey
        let contentType = NSMetadataItemContentTypeKey
        switch self {
        case .all:
            return nil
        case .folder:
            return NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "%K == %@", typeTree, "public.folder"),
                NSCompoundPredicate(notPredicateWithSubpredicate:
                    NSPredicate(format: "%K == %@", typeTree, "com.apple.application-bundle"))
            ])
        case .application:
            return NSPredicate(format: "%K == %@", typeTree, "com.apple.application-bundle")
        case .video:
            return NSPredicate(format: "%K == %@", typeTree, "public.movie")
        case .audio:
            return NSPredicate(format: "%K == %@", typeTree, "public.audio")
        case .image:
            return NSPredicate(format: "%K == %@", typeTree, "public.image")
        case .document:
            return NSPredicate(format: "%K == %@", typeTree, "public.document")
        case .presentation:
            return NSPredicate(format: "%K == %@", typeTree, "public.presentation")
        case .word:
            return Self.contentTypePredicate([
                "com.microsoft.word.doc",
                "org.openxmlformats.wordprocessingml.document",
                "org.openxmlformats.wordprocessingml.template"
            ], key: contentType)
        case .excel:
            return Self.contentTypePredicate([
                "com.microsoft.excel.xls",
                "org.openxmlformats.spreadsheetml.sheet",
                "org.openxmlformats.spreadsheetml.template"
            ], key: contentType)
        case .pdf:
            return NSPredicate(format: "%K == %@", contentType, "com.adobe.pdf")
        case .archive:
            return NSPredicate(format: "%K == %@", typeTree, "public.archive")
        }
    }

    var metadataQueryExpression: String? {
        switch self {
        case .all:
            return nil
        case .folder:
            return "(kMDItemContentTypeTree == \"public.folder\" && !(kMDItemContentTypeTree == \"com.apple.application-bundle\"))"
        case .application:
            return "kMDItemContentTypeTree == \"com.apple.application-bundle\""
        case .video:
            return "kMDItemContentTypeTree == \"public.movie\""
        case .audio:
            return "kMDItemContentTypeTree == \"public.audio\""
        case .image:
            return "kMDItemContentTypeTree == \"public.image\""
        case .document:
            return "kMDItemContentTypeTree == \"public.document\""
        case .presentation:
            return "kMDItemContentTypeTree == \"public.presentation\""
        case .word:
            return Self.contentTypeQueryExpression([
                "com.microsoft.word.doc",
                "org.openxmlformats.wordprocessingml.document",
                "org.openxmlformats.wordprocessingml.template"
            ])
        case .excel:
            return Self.contentTypeQueryExpression([
                "com.microsoft.excel.xls",
                "org.openxmlformats.spreadsheetml.sheet",
                "org.openxmlformats.spreadsheetml.template"
            ])
        case .pdf:
            return "kMDItemContentType == \"com.adobe.pdf\""
        case .archive:
            return "kMDItemContentTypeTree == \"public.archive\""
        }
    }

    private static func contentTypePredicate(_ identifiers: [String], key: String) -> NSPredicate {
        NSCompoundPredicate(orPredicateWithSubpredicates: identifiers.map {
            NSPredicate(format: "%K == %@", key, $0)
        })
    }

    private static func contentTypeQueryExpression(_ identifiers: [String]) -> String {
        "(" + identifiers.map { "kMDItemContentType == \"\($0)\"" }.joined(separator: " || ") + ")"
    }
}

enum SearchMatchMode: String, CaseIterable, Codable {
    case contains
    case prefix
    case exact

    var title: String {
        switch self {
        case .contains: return String(localized: "Contains")
        case .prefix: return String(localized: "Starts With")
        case .exact: return String(localized: "Exact")
        }
    }

    var toolTip: String {
        switch self {
        case .contains:
            return String(localized: "Matches file names containing the entire entered text. Spaces are treated as part of the name.")
        case .prefix:
            return String(localized: "Matches file names starting with the entire entered text. Spaces are treated as part of the name.")
        case .exact:
            return String(localized: "Matches the entire file name or display name, ignoring letter case and diacritics.")
        }
    }
}

enum ResultSortMode: String, CaseIterable, Codable {
    case smart
    case nameAscending
    case nameDescending
    case pathAscending
    case pathDescending
    case kindAscending
    case kindDescending
    case sizeDescending
    case sizeAscending
    case modifiedDescending
    case modifiedAscending

    var title: String {
        switch self {
        case .smart: return String(localized: "Smart (Common Documents First)")
        case .nameAscending: return String(localized: "Name (A–Z)")
        case .nameDescending: return String(localized: "Name (Z–A)")
        case .pathAscending: return String(localized: "Path (A–Z)")
        case .pathDescending: return String(localized: "Path (Z–A)")
        case .kindAscending: return String(localized: "Kind (A–Z)")
        case .kindDescending: return String(localized: "Kind (Z–A)")
        case .sizeDescending: return String(localized: "Size (Largest First)")
        case .sizeAscending: return String(localized: "Size (Smallest First)")
        case .modifiedDescending: return String(localized: "Modified (Newest First)")
        case .modifiedAscending: return String(localized: "Modified (Oldest First)")
        }
    }
}

enum FolderPriority: Int, CaseIterable, Codable {
    case normal = 0
    case preferred = 1
    case pinned = 2

    var title: String {
        switch self {
        case .normal: return String(localized: "Normal")
        case .preferred: return String(localized: "Preferred")
        case .pinned: return String(localized: "Pinned")
        }
    }

    var rank: Int {
        switch self {
        case .pinned: return 0
        case .preferred: return 1
        case .normal: return 2
        }
    }
}

struct FolderRule: Codable, Equatable {
    var path: String
    var priority: FolderPriority
}

enum WindowPlacement: String, CaseIterable {
    case center
    case remember

    var title: String {
        switch self {
        case .center: return String(localized: "Center on the current display")
        case .remember: return String(localized: "Restore the previous position")
        }
    }
}

enum WindowStartupSize: String, CaseIterable {
    case previous
    case defaultSize

    var title: String {
        switch self {
        case .previous: return String(localized: "Use the previous window size")
        case .defaultSize: return String(localized: "Use the default window size")
        }
    }
}

enum ColumnSizingMode: String, CaseIterable {
    case fitWindow
    case manual

    var title: String {
        switch self {
        case .fitWindow: return String(localized: "Fit columns to window (No Horizontal Scrolling)")
        case .manual: return String(localized: "Manual column widths (Scroll When Needed)")
        }
    }
}

enum FileManagerChoice: String, CaseIterable {
    case systemDefault
    case finder
    case custom
}

enum WindowPreferences {
    static let didChangeNotification = Notification.Name("FindAllWindowPreferencesDidChange")
    static let resetColumnLayoutNotification = Notification.Name("FindAllResetColumnLayout")
    static let resetWindowSizeNotification = Notification.Name("FindAllResetWindowSize")

    static let defaultWindowSize = NSSize(width: 980, height: 620)
    static let columnWidthsKey = "table.columnWidths.v4"
    static let automaticColumnWidthsKey = "table.automaticColumnWidths.v1"
    static let automaticColumnReferenceWidthKey = "table.automaticColumnReferenceWidth.v1"
    static let columnOrderKey = "table.columnOrder.v1"

    private enum Key {
        static let placement = "window.placement"
        static let startupSize = "window.startupSize"
        static let rememberSize = "window.rememberSize"
        static let savedSize = "window.savedSize"
        static let savedOrigin = "window.savedOrigin"
        static let keepOnTop = "window.keepOnTop"
        static let showOnAllSpaces = "window.showOnAllSpaces"
        static let columnSizingMode = "table.columnSizingMode"
        static let fileManagerChoice = "fileManager.choice"
        static let customFileManagerPath = "fileManager.customPath"
    }

    static var placement: WindowPlacement {
        get { WindowPlacement(rawValue: UserDefaults.standard.string(forKey: Key.placement) ?? "") ?? .center }
        set { set(newValue.rawValue, forKey: Key.placement) }
    }

    static var startupSize: WindowStartupSize {
        get {
            if let rawValue = UserDefaults.standard.string(forKey: Key.startupSize),
               let value = WindowStartupSize(rawValue: rawValue) {
                return value
            }
            guard UserDefaults.standard.object(forKey: Key.rememberSize) != nil else { return .previous }
            return UserDefaults.standard.bool(forKey: Key.rememberSize) ? .previous : .defaultSize
        }
        set { set(newValue.rawValue, forKey: Key.startupSize) }
    }

    static var keepOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: Key.keepOnTop) }
        set { set(newValue, forKey: Key.keepOnTop) }
    }

    static var showOnAllSpaces: Bool {
        get { UserDefaults.standard.bool(forKey: Key.showOnAllSpaces) }
        set { set(newValue, forKey: Key.showOnAllSpaces) }
    }

    static var columnSizingMode: ColumnSizingMode {
        get { ColumnSizingMode(rawValue: UserDefaults.standard.string(forKey: Key.columnSizingMode) ?? "") ?? .fitWindow }
        set { set(newValue.rawValue, forKey: Key.columnSizingMode) }
    }

    static var fileManagerChoice: FileManagerChoice {
        get {
            let choice = FileManagerChoice(rawValue: UserDefaults.standard.string(forKey: Key.fileManagerChoice) ?? "") ?? .systemDefault
            if choice == .custom, customFileManagerURL == nil { return .systemDefault }
            return choice
        }
        set { set(newValue.rawValue, forKey: Key.fileManagerChoice) }
    }

    static var customFileManagerURL: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: Key.customFileManagerPath),
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.standardizedFileURL.path, forKey: Key.customFileManagerPath)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.customFileManagerPath)
            }
            notify()
        }
    }

    static var savedSize: NSSize? {
        get {
            guard let value = UserDefaults.standard.string(forKey: Key.savedSize) else { return nil }
            let size = NSSizeFromString(value)
            return size.width > 0 && size.height > 0 ? size : nil
        }
        set {
            if let newValue { UserDefaults.standard.set(NSStringFromSize(newValue), forKey: Key.savedSize) }
            else { UserDefaults.standard.removeObject(forKey: Key.savedSize) }
        }
    }

    static var savedOrigin: NSPoint? {
        get {
            guard let value = UserDefaults.standard.string(forKey: Key.savedOrigin) else { return nil }
            return NSPointFromString(value)
        }
        set {
            if let newValue { UserDefaults.standard.set(NSStringFromPoint(newValue), forKey: Key.savedOrigin) }
            else { UserDefaults.standard.removeObject(forKey: Key.savedOrigin) }
        }
    }

    static func resetColumnLayout() {
        UserDefaults.standard.removeObject(forKey: columnWidthsKey)
        UserDefaults.standard.removeObject(forKey: automaticColumnWidthsKey)
        UserDefaults.standard.removeObject(forKey: automaticColumnReferenceWidthKey)
        UserDefaults.standard.removeObject(forKey: columnOrderKey)
        NotificationCenter.default.post(name: resetColumnLayoutNotification, object: nil)
    }

    static func resetWindowSize() {
        UserDefaults.standard.removeObject(forKey: Key.savedSize)
        NotificationCenter.default.post(name: resetWindowSizeNotification, object: nil)
    }

    private static func set(_ value: Any, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        notify()
    }

    private static func notify() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

enum FileManagerSupport {
    static func openFolders(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let workspace = NSWorkspace.shared
        if let applicationURL = selectedFileManagerURL {
            open(urls, with: applicationURL, workspace: workspace)
        } else {
            urls.forEach { workspace.open($0) }
        }
    }

    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let applicationURL = selectedFileManagerURL else {
            revealInFinder(urls)
            return
        }
        if isFinder(applicationURL) {
            revealInFinder(urls)
        } else if isQSpace(applicationURL), systemFileViewerIsQSpace {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } else if isQSpace(applicationURL), revealInQSpace(urls) {
            return
        } else {
            open(parentURLs(for: urls), with: applicationURL, workspace: .shared)
        }
    }

    static var canSelectRevealedItem: Bool {
        guard let applicationURL = selectedFileManagerURL else { return true }
        return isFinder(applicationURL) || isQSpace(applicationURL)
    }

    private static var finderURL: URL {
        URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    }

    private static var selectedFileManagerURL: URL? {
        switch WindowPreferences.fileManagerChoice {
        case .finder:
            return finderURL
        case .custom:
            return WindowPreferences.customFileManagerURL
        case .systemDefault:
            guard let bundleIdentifier = UserDefaults.standard.string(forKey: "NSFileViewer"),
                  bundleIdentifier != "com.apple.finder" else { return nil }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        }
    }

    private static func isFinder(_ applicationURL: URL) -> Bool {
        Bundle(url: applicationURL)?.bundleIdentifier == "com.apple.finder"
    }

    private static func isQSpace(_ applicationURL: URL) -> Bool {
        Bundle(url: applicationURL)?.bundleIdentifier?.hasPrefix("com.jinghaoshe.qspace") == true
    }

    private static var systemFileViewerIsQSpace: Bool {
        UserDefaults.standard.string(forKey: "NSFileViewer")?.hasPrefix("com.jinghaoshe.qspace") == true
    }

    private static func parentURLs(for urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.compactMap {
            let parent = $0.deletingLastPathComponent().standardizedFileURL
            return seen.insert(parent).inserted ? parent : nil
        }
    }

    private static func revealInFinder(_ urls: [URL]) {
        let workspace = NSWorkspace.shared
        if urls.count == 1, let url = urls.first {
            let parentPath = url.deletingLastPathComponent().standardizedFileURL.path
            if workspace.selectFile(url.standardizedFileURL.path, inFileViewerRootedAtPath: parentPath) {
                return
            }
        }
        workspace.activateFileViewerSelecting(urls)
    }

    private static func revealInQSpace(_ urls: [URL]) -> Bool {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("FindAllQSpaceReveal"))
        pasteboard.clearContents()
        guard pasteboard.writeObjects(urls.map { $0 as NSURL }) else { return false }
        for serviceName in ["QSpace/Reveal", "Reveal in QSpace Pro", "Reveal in QSpace"] {
            if NSPerformService(serviceName, pasteboard) { return true }
        }
        return false
    }

    private static func open(_ urls: [URL], with applicationURL: URL, workspace: NSWorkspace) {
        workspace.open(urls, withApplicationAt: applicationURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

enum SearchPreferences {
    static let didChangeNotification = Notification.Name("FindAllSearchPreferencesDidChange")

    private enum Key {
        static let category = "search.category"
        static let scopePath = "search.scopePath"
        static let matchMode = "search.matchMode"
        static let sortMode = "results.sortMode"
        static let prioritizeFolderRules = "results.prioritizeFolderRules"
        static let foldersFirst = "results.foldersFirst"
        static let folderRules = "results.folderRules"
    }

    static var category: SearchCategory {
        get { SearchCategory(rawValue: UserDefaults.standard.string(forKey: Key.category) ?? "") ?? .all }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Key.category)
            notify()
        }
    }

    static var scopePath: String? {
        get { UserDefaults.standard.string(forKey: Key.scopePath) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: Key.scopePath) }
            else { UserDefaults.standard.removeObject(forKey: Key.scopePath) }
            notify()
        }
    }

    static var matchMode: SearchMatchMode {
        get { SearchMatchMode(rawValue: UserDefaults.standard.string(forKey: Key.matchMode) ?? "") ?? .contains }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Key.matchMode)
            notify()
        }
    }

    static var sortMode: ResultSortMode {
        get { ResultSortMode(rawValue: UserDefaults.standard.string(forKey: Key.sortMode) ?? "") ?? .smart }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Key.sortMode)
            notify()
        }
    }

    static var prioritizeFolderRules: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.prioritizeFolderRules) != nil else { return true }
            return UserDefaults.standard.bool(forKey: Key.prioritizeFolderRules)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.prioritizeFolderRules)
            notify()
        }
    }

    static var foldersFirst: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.foldersFirst) != nil else { return true }
            return UserDefaults.standard.bool(forKey: Key.foldersFirst)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.foldersFirst)
            notify()
        }
    }

    static var folderRules: [FolderRule] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Key.folderRules),
                  let rules = try? JSONDecoder().decode([FolderRule].self, from: data) else { return [] }
            return rules
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Key.folderRules)
            }
            notify()
        }
    }

    static func addFolder(path: String, priority: FolderPriority = .normal) {
        var rules = folderRules
        if let index = rules.firstIndex(where: { $0.path == path }) {
            rules[index].priority = priority
        } else {
            rules.append(FolderRule(path: path, priority: priority))
        }
        folderRules = rules
    }

    static func ranking(for url: URL, rules: [FolderRule]) -> (priority: Int, ruleOrder: Int)? {
        let itemComponents = url.standardizedFileURL.pathComponents
        return rules.enumerated().compactMap { index, rule -> (priority: Int, ruleOrder: Int)? in
            guard rule.priority != .normal else { return nil }
            let folderComponents = URL(fileURLWithPath: rule.path).standardizedFileURL.pathComponents
            guard itemComponents.count >= folderComponents.count,
                  Array(itemComponents.prefix(folderComponents.count)) == folderComponents else { return nil }
            return (rule.priority.rank, index)
        }
        .sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.ruleOrder < $1.ruleOrder
        }
        .first
    }

    private static func notify() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

enum FullDiskAccessSupport {
    enum Status {
        case granted
        case denied
        case unknown
    }

    static func currentStatus() -> Status {
        let fileManager = FileManager.default
        let library = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        let protectedFolders = [
            library.appendingPathComponent("Mail", isDirectory: true),
            library.appendingPathComponent("Messages", isDirectory: true),
            library.appendingPathComponent("Safari", isDirectory: true)
        ]

        for folder in protectedFolders {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            do {
                _ = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                return .granted
            } catch {
                if isPermissionDenied(error) { return .denied }
            }
        }
        return .unknown
    }

    static func openSystemSettings() {
        let workspace = NSWorkspace.shared
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"),
           workspace.open(url) {
            return
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
           workspace.open(url) {
            return
        }
        workspace.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           error.code == CocoaError.fileReadNoPermission.rawValue {
            return true
        }
        return error.domain == NSPOSIXErrorDomain
            && [Int(POSIXErrorCode.EACCES.rawValue), Int(POSIXErrorCode.EPERM.rawValue)].contains(error.code)
    }
}
