import CoreServices
import Foundation
import UniformTypeIdentifiers

enum FilePathSupport {
    private static let dataVolumeMappings: [(physical: String, logical: String)] = [
        ("/System/Volumes/Data/System/Library/PreinstalledAssetsV2", "/System/Library/PreinstalledAssetsV2"),
        ("/System/Volumes/Data/System/Library/PreinstalledAssets", "/System/Library/PreinstalledAssets"),
        ("/System/Volumes/Data/System/Library/CoreServices/CoreTypes.bundle/Contents/Library", "/System/Library/CoreServices/CoreTypes.bundle/Contents/Library"),
        ("/System/Volumes/Data/System/Library/AssetsV2", "/System/Library/AssetsV2"),
        ("/System/Volumes/Data/System/Library/Assets", "/System/Library/Assets"),
        ("/System/Volumes/Data/System/Library/Caches", "/System/Library/Caches"),
        ("/System/Volumes/Data/System/Library/Speech", "/System/Library/Speech"),
        ("/System/Volumes/Data/usr/libexec/cups", "/usr/libexec/cups"),
        ("/System/Volumes/Data/usr/share/snmp", "/usr/share/snmp"),
        ("/System/Volumes/Data/AppleInternal", "/AppleInternal"),
        ("/System/Volumes/Data/Applications", "/Applications"),
        ("/System/Volumes/Data/usr/local", "/usr/local"),
        ("/System/Volumes/Data/Library", "/Library"),
        ("/System/Volumes/Data/Users", "/Users"),
        ("/System/Volumes/Data/Volumes", "/Volumes"),
        ("/System/Volumes/Data/private", "/private"),
        ("/System/Volumes/Data/cores", "/cores"),
        ("/System/Volumes/Data/opt", "/opt"),
        ("/System/Volumes/Data/pkg", "/pkg")
    ]

    static func userFacingPath(_ path: String) -> String {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        for mapping in dataVolumeMappings {
            if standardizedPath == mapping.physical { return mapping.logical }
            let prefix = mapping.physical + "/"
            if standardizedPath.hasPrefix(prefix) {
                return mapping.logical + standardizedPath.dropFirst(mapping.physical.count)
            }
        }
        return standardizedPath
    }

    static func userFacingURL(_ url: URL) -> URL {
        URL(fileURLWithPath: userFacingPath(url.path))
    }
}

struct SearchResult: Hashable {
    let url: URL
    let displayName: String
    let kind: String
    let fullKind: String
    let contentTypeIdentifier: String?
    let size: Int64?
    let modifiedAt: Date?
    let isDirectory: Bool

    var path: String { url.path }
}

struct SearchRequest: Equatable {
    let text: String
    let category: SearchCategory
    let scopePath: String?
    let matchMode: SearchMatchMode
}

enum SearchFailure {
    case couldNotStart
    case timedOut
}

enum SearchResultCoverage {
    case complete
    case candidateLimitReached
    case timedOut
}

enum SearchUpdate {
    case idle
    case started
    case gathering(Int)
    case results([SearchResult], coverage: SearchResultCoverage)
    case failed(SearchFailure)
}

final class FileSearchService: NSObject {
    var onUpdate: ((SearchUpdate) -> Void)?

    /// Keeps broad searches bounded while allowing the UI to rank a substantially
    /// larger candidate set than it displays.
    private let candidateLimit = 20_000
    private let queryTimeout: TimeInterval = 30
    private var generation = 0
    private var timeoutWorkItem: DispatchWorkItem?
    private var activeQuery: NSMetadataQuery?
    private var activeRequest: SearchRequest?
    private var notificationTokens: [NSObjectProtocol] = []

    func search(_ request: SearchRequest) {
        precondition(Thread.isMainThread)
        generation += 1
        let currentGeneration = generation
        stopActiveQuery()

        let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onUpdate?(.idle)
            return
        }

        let normalizedRequest = SearchRequest(
            text: trimmed,
            category: request.category,
            scopePath: request.scopePath,
            matchMode: request.matchMode
        )
        startQuery(normalizedRequest, generation: currentGeneration)
    }

    func cancel() {
        precondition(Thread.isMainThread)
        generation += 1
        stopActiveQuery()
        onUpdate?(.idle)
    }

    private func startQuery(_ request: SearchRequest, generation: Int) {
        guard generation == self.generation else { return }
        let query = NSMetadataQuery()
        query.predicate = Self.makePredicate(for: request)
        query.notificationBatchingInterval = 0.2
        if let scopePath = request.scopePath {
            query.searchScopes = [URL(fileURLWithPath: scopePath).standardizedFileURL.path]
        }
        // The default empty scope is intentionally retained for "All Locations".
        // It avoids restricting results to kMDQueryScopeAllIndexed and also avoids
        // the runtime exception seen with NSMetadataQueryLocalComputerScope on an
        // affected macOS version.

        activeQuery = query
        activeRequest = request
        observe(query, request: request, generation: generation)
        NSLog(
            "FindAll Spotlight query %d starting (mode=%@, category=%@, customScope=%@, candidateLimit=%d)",
            generation,
            request.matchMode.rawValue,
            request.category.rawValue,
            request.scopePath == nil ? "no" : "yes",
            candidateLimit
        )
        onUpdate?(.started)
        guard query.start() else {
            stopActiveQuery()
            onUpdate?(.failed(.couldNotStart))
            return
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self, weak query] in
            guard let self, let query,
                  self.isCurrent(query, request: request, generation: generation) else { return }
            if query.resultCount > 0 {
                self.finishQuery(query, request: request, generation: generation, coverage: .timedOut)
            } else {
                self.generation += 1
                self.stopActiveQuery()
                NSLog("FindAll Spotlight query %d timed out without results", generation)
                self.onUpdate?(.failed(.timedOut))
            }
        }
        self.timeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + queryTimeout, execute: timeoutWorkItem)
    }

    private func observe(_ query: NSMetadataQuery, request: SearchRequest, generation: Int) {
        let center = NotificationCenter.default
        let progress = center.addObserver(
            forName: .NSMetadataQueryGatheringProgress,
            object: query,
            queue: .main
        ) { [weak self, weak query] _ in
            guard let self, let query,
                  self.isCurrent(query, request: request, generation: generation) else { return }
            self.onUpdate?(.gathering(query.resultCount))
        }
        let finished = center.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self, weak query] _ in
            guard let self, let query,
                  self.isCurrent(query, request: request, generation: generation) else { return }
            self.finishQuery(query, request: request, generation: generation, coverage: .complete)
        }
        notificationTokens = [progress, finished]
    }

    private func finishQuery(
        _ query: NSMetadataQuery,
        request: SearchRequest,
        generation: Int,
        coverage requestedCoverage: SearchResultCoverage
    ) {
        guard isCurrent(query, request: request, generation: generation) else { return }
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        query.disableUpdates()
        let rawCount = query.resultCount
        let conversion = Self.makeResults(from: query, request: request, limit: candidateLimit)
        let coverage: SearchResultCoverage = conversion.reachedLimit ? .candidateLimitReached : requestedCoverage

        activeQuery = nil
        activeRequest = nil
        removeNotificationObservers()
        query.stop()
        NSLog(
            "FindAll Spotlight query %d finished (raw=%d, converted=%d, missingPath=%d, literalRejected=%d, coverage=%@)",
            generation,
            rawCount,
            conversion.results.count,
            conversion.missingPathCount,
            conversion.literalRejectedCount,
            String(describing: coverage)
        )
        onUpdate?(.results(conversion.results, coverage: coverage))
    }

    private func isCurrent(_ query: NSMetadataQuery, request: SearchRequest, generation: Int) -> Bool {
        generation == self.generation
            && query === activeQuery
            && request == activeRequest
    }

    private func stopActiveQuery() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        removeNotificationObservers()
        guard let query = activeQuery else {
            activeRequest = nil
            return
        }
        activeQuery = nil
        activeRequest = nil
        query.stop()
    }

    private func removeNotificationObservers() {
        let center = NotificationCenter.default
        notificationTokens.forEach(center.removeObserver)
        notificationTokens.removeAll()
    }

    private static func makePredicate(for request: SearchRequest) -> NSPredicate {
        let nameKey = NSMetadataItemDisplayNameKey
        let namePredicate: NSPredicate
        switch request.matchMode {
        case .contains:
            namePredicate = NSPredicate(format: "%K CONTAINS[cd] %@", nameKey, request.text)
        case .prefix:
            namePredicate = NSPredicate(format: "%K BEGINSWITH[cd] %@", nameKey, request.text)
        case .exact:
            namePredicate = NSPredicate(format: "%K ==[cd] %@", nameKey, request.text)
        }
        guard let categoryPredicate = request.category.metadataPredicate else { return namePredicate }
        return NSCompoundPredicate(andPredicateWithSubpredicates: [namePredicate, categoryPredicate])
    }

    private struct ResultConversion {
        var results: [SearchResult]
        var reachedLimit: Bool
        var missingPathCount: Int
        var literalRejectedCount: Int
    }

    private static func makeResults(
        from query: NSMetadataQuery,
        request: SearchRequest,
        limit: Int
    ) -> ResultConversion {
        var results: [SearchResult] = []
        var seenURLs = Set<URL>()
        var missingPathCount = 0
        var literalRejectedCount = 0
        results.reserveCapacity(min(query.resultCount, limit))

        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let result = makeResult(item) else {
                missingPathCount += 1
                continue
            }
            guard matchesLiteralName(result.displayName, request: request) else {
                literalRejectedCount += 1
                continue
            }
            guard seenURLs.insert(result.url.standardizedFileURL).inserted else { continue }
            if results.count == limit {
                return ResultConversion(
                    results: results,
                    reachedLimit: true,
                    missingPathCount: missingPathCount,
                    literalRejectedCount: literalRejectedCount
                )
            }
            results.append(result)
        }
        return ResultConversion(
            results: results,
            reachedLimit: false,
            missingPathCount: missingPathCount,
            literalRejectedCount: literalRejectedCount
        )
    }

    private static func matchesLiteralName(_ name: String, request: SearchRequest) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        switch request.matchMode {
        case .contains:
            return name.range(of: request.text, options: options) != nil
        case .prefix:
            return name.range(of: request.text, options: options.union(.anchored)) != nil
        case .exact:
            return name.compare(request.text, options: options) == .orderedSame
        }
    }

    private static func makeResult(_ item: NSMetadataItem) -> SearchResult? {
        let url: URL?
        if let itemURL = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
            url = itemURL
        } else if let itemURL = item.value(forAttribute: NSMetadataItemURLKey) as? NSURL {
            url = itemURL as URL
        } else if let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
            url = URL(fileURLWithPath: path)
        } else {
            url = nil
        }
        guard let url else { return nil }
        let normalizedURL = FilePathSupport.userFacingURL(url)
        let displayName = item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String
            ?? item.value(forAttribute: NSMetadataItemFSNameKey) as? String
            ?? normalizedURL.lastPathComponent
        let typeTree = item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []
        let contentTypeIdentifier = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
        let fullKind = item.value(forAttribute: NSMetadataItemKindKey) as? String ?? ""
        let isDirectory = typeTree.contains("public.folder")
        return SearchResult(
            url: normalizedURL,
            displayName: displayName,
            kind: SearchResultKindSupport.displayKind(
                for: normalizedURL,
                contentTypeIdentifier: contentTypeIdentifier,
                fullKind: fullKind,
                isDirectory: isDirectory
            ),
            fullKind: fullKind,
            contentTypeIdentifier: contentTypeIdentifier,
            size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value,
            modifiedAt: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
            isDirectory: isDirectory
        )
    }

    deinit {
        removeNotificationObservers()
        activeQuery?.stop()
    }
}

private enum SearchResultKindSupport {
    private static let conciseExtensions: [String: String] = [
        "doc": "Word", "docx": "Word", "docm": "Word", "dot": "Word", "dotx": "Word",
        "xls": "Excel", "xlsx": "Excel", "xlsm": "Excel", "xlt": "Excel", "xltx": "Excel",
        "ppt": "PowerPoint", "pptx": "PowerPoint", "pptm": "PowerPoint", "pot": "PowerPoint", "potx": "PowerPoint",
        "pages": "Pages", "numbers": "Numbers", "key": "Keynote",
        "pdf": "PDF", "rtf": "RTF", "csv": "CSV", "tsv": "TSV",
        "txt": "Text", "text": "Text", "md": "Markdown", "markdown": "Markdown",
        "json": "JSON", "xml": "XML", "yaml": "YAML", "yml": "YAML", "toml": "TOML", "plist": "Property List",
        "html": "HTML", "htm": "HTML", "css": "CSS", "scss": "SCSS", "sass": "Sass", "less": "Less",
        "js": "JavaScript", "mjs": "JavaScript", "cjs": "JavaScript", "jsx": "JavaScript",
        "ts": "TypeScript", "tsx": "TypeScript", "swift": "Swift", "py": "Python", "rb": "Ruby",
        "sh": "Shell", "bash": "Shell", "zsh": "Shell", "fish": "Shell", "sql": "SQL",
        "c": "C", "h": "C Header", "cc": "C++", "cpp": "C++", "cxx": "C++", "hpp": "C++ Header",
        "java": "Java", "kt": "Kotlin", "kts": "Kotlin", "go": "Go", "rs": "Rust",
        "png": "PNG", "jpg": "JPEG", "jpeg": "JPEG", "gif": "GIF", "heic": "HEIC", "heif": "HEIF",
        "svg": "SVG", "webp": "WebP", "tif": "TIFF", "tiff": "TIFF", "bmp": "BMP", "ico": "ICO",
        "mp3": "MP3", "aac": "AAC", "m4a": "M4A", "flac": "FLAC", "wav": "WAV", "aiff": "AIFF", "ogg": "Ogg",
        "mp4": "MP4", "mov": "MOV", "m4v": "M4V", "mkv": "MKV", "avi": "AVI", "webm": "WebM",
        "zip": "ZIP", "rar": "RAR", "7z": "7Z", "tar": "TAR", "gz": "GZIP", "bz2": "BZIP2", "xz": "XZ",
        "dmg": "Disk Image", "iso": "Disk Image"
    ]

    static func displayKind(
        for url: URL,
        contentTypeIdentifier: String?,
        fullKind: String,
        isDirectory: Bool
    ) -> String {
        if isDirectory { return L10n.string("Folder") }

        let pathExtension = url.pathExtension.lowercased()
        if pathExtension == "app" { return L10n.string("Application") }
        if let conciseKind = conciseExtensions[pathExtension] {
            return localizedKind(conciseKind)
        }

        if let contentTypeIdentifier, let type = UTType(contentTypeIdentifier) {
            if type.conforms(to: .applicationBundle) { return L10n.string("Application") }
            if type.conforms(to: .folder) { return L10n.string("Folder") }
            if type.conforms(to: .plainText) { return L10n.string("Text") }
            if type.conforms(to: .pdf) { return "PDF" }
        }

        if !fullKind.isEmpty { return fullKind }
        if !pathExtension.isEmpty { return pathExtension.uppercased() }
        return L10n.string("File")
    }

    private static func localizedKind(_ kind: String) -> String {
        switch kind {
        case "Text", "Property List", "Disk Image", "Application":
            return L10n.string(kind)
        default:
            return kind
        }
    }
}
