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

    private static func contentTypePredicate(_ identifiers: [String], key: String) -> NSPredicate {
        NSCompoundPredicate(orPredicateWithSubpredicates: identifiers.map {
            NSPredicate(format: "%K == %@", key, $0)
        })
    }
}

enum ResultSortMode: String, CaseIterable, Codable {
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

enum SearchPreferences {
    static let didChangeNotification = Notification.Name("FindAllSearchPreferencesDidChange")

    private enum Key {
        static let category = "search.category"
        static let scopePath = "search.scopePath"
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

    static var sortMode: ResultSortMode {
        get { ResultSortMode(rawValue: UserDefaults.standard.string(forKey: Key.sortMode) ?? "") ?? .nameAscending }
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
    static func openSystemSettings() {
        let workspace = NSWorkspace.shared
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
           workspace.open(url) {
            return
        }
        workspace.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
