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

enum PathInputParser {
    static func parse(_ text: String) -> [String] {
        let characters = Array(text)
        var results: [String] = []
        var current = ""
        var quote: Character?
        var preservesOuterWhitespace = false
        var index = 0

        func normalizedCurrent() -> String {
            preservesOuterWhitespace
                ? current
                : current.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func startsPath(at candidateIndex: Int) -> Bool {
            guard characters.indices.contains(candidateIndex) else { return false }
            var start = candidateIndex
            if characters[start] == "\"" || characters[start] == "'" {
                start += 1
                guard characters.indices.contains(start) else { return false }
            }
            if characters[start] == "/" { return true }
            if characters[start] == "~",
               characters.indices.contains(start + 1), characters[start + 1] == "/" {
                return true
            }
            let remainder = String(characters[start...]).lowercased()
            return remainder.hasPrefix("file:")
        }

        func appendCurrent() {
            let value = normalizedCurrent()
            if !value.isEmpty { results.append(value) }
            current = ""
            preservesOuterWhitespace = false
        }

        while index < characters.count {
            let character = characters[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if character == "\\", activeQuote == "\"",
                          characters.indices.contains(index + 1),
                          ["\\", "\""].contains(characters[index + 1]) {
                    index += 1
                    current.append(characters[index])
                } else {
                    current.append(character)
                }
                index += 1
                continue
            }

            if (character == "\"" || character == "'") && current.isEmpty {
                quote = character
                preservesOuterWhitespace = true
                index += 1
                continue
            }

            if character == "\n" || character == "\r" {
                appendCurrent()
                index += 1
                continue
            }

            if character.isWhitespace {
                var nextIndex = index
                while nextIndex < characters.count,
                      characters[nextIndex].isWhitespace,
                      characters[nextIndex] != "\n",
                      characters[nextIndex] != "\r" {
                    nextIndex += 1
                }
                if !normalizedCurrent().isEmpty, startsPath(at: nextIndex) {
                    appendCurrent()
                    index = nextIndex
                    continue
                }
                current.append(contentsOf: characters[index..<nextIndex])
                index = nextIndex
                continue
            }

            if character == "\\", characters.indices.contains(index + 1),
               characters[index + 1].isWhitespace || characters[index + 1] == "\\"
                    || characters[index + 1] == "\"" || characters[index + 1] == "'" {
                index += 1
                current.append(characters[index])
                index += 1
                continue
            }

            current.append(character)
            index += 1
        }

        appendCurrent()
        return results
    }
}

enum KeywordSupport {
    static let inputLimit = 20

    static func normalized(_ values: [String], limit: Int = inputLimit) -> [String] {
        var results: [String] = []
        var seen = Set<String>()
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let comparisonKey = trimmed.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: nil
            )
            guard seen.insert(comparisonKey).inserted else { continue }
            results.append(trimmed)
            if results.count == limit { break }
        }
        return results
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

    var isBrowsableDirectory: Bool {
        guard isDirectory,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return values.isDirectory == true && values.isPackage != true
    }

    static func load(from url: URL) -> Result<SearchResult, FileResultFailure> {
        let requiredKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isDirectoryKey,
            .isPackageKey
        ]
        do {
            let values = try url.resourceValues(forKeys: requiredKeys)
            let descriptiveValues = try? url.resourceValues(forKeys: [
                .contentTypeKey,
                .localizedNameKey,
                .localizedTypeDescriptionKey
            ])
            let isDirectory = values.isDirectory == true && values.isPackage != true
            let fallbackContentType: UTType? = {
                if values.isDirectory == true && values.isPackage != true { return .folder }
                guard !url.pathExtension.isEmpty else { return nil }
                return UTType(filenameExtension: url.pathExtension)
            }()
            let contentType = descriptiveValues?.contentType ?? fallbackContentType
            let displayName = descriptiveValues?.localizedName
                ?? (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
            let fullKind = descriptiveValues?.localizedTypeDescription
                ?? contentType?.localizedDescription
                ?? ""
            let contentTypeIdentifier = contentType?.identifier
            return .success(SearchResult(
                url: url,
                displayName: displayName,
                kind: SearchResultKindSupport.displayKind(
                    for: url,
                    contentTypeIdentifier: contentTypeIdentifier,
                    fullKind: fullKind,
                    isDirectory: isDirectory
                ),
                fullKind: fullKind,
                contentTypeIdentifier: contentTypeIdentifier,
                size: values.isDirectory == true ? nil : values.fileSize.map(Int64.init),
                modifiedAt: values.contentModificationDate,
                isDirectory: isDirectory
            ))
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain {
                let cocoaCode = CocoaError.Code(rawValue: nsError.code)
                if cocoaCode == .fileNoSuchFile || cocoaCode == .fileReadNoSuchFile {
                    return .failure(.notFound)
                }
                if cocoaCode == .fileReadNoPermission {
                    return .failure(.inaccessible)
                }
            }
            return FileManager.default.fileExists(atPath: url.path)
                ? .failure(.inaccessible)
                : .failure(.notFound)
        }
    }
}

enum FileResultFailure: Error {
    case notFound
    case inaccessible
}

struct SearchRequest: Equatable {
    let text: String
    let category: SearchCategory
    let scopePath: String?
    let matchMode: SearchMatchMode
    let pathInputs: [String]?
    let keywords: [String]?
    let keywordRelation: KeywordMatchRelation
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
    case pathStarted(Int)
    case pathResults([SearchResult], summary: PathSearchSummary)
    case failed(SearchFailure)
}

struct PathSearchSummary {
    let submittedCount: Int
    let notFoundCount: Int
    let inaccessibleCount: Int
    let invalidCount: Int
    let duplicateCount: Int
    let omittedCount: Int
    let issues: [PathSearchIssue]
    let hasMoreIssues: Bool
}

struct PathSearchIssue {
    enum Reason {
        case notFound
        case inaccessible
        case invalid
        case duplicate
    }

    let input: String
    let reason: Reason
}

private final class PathSearchCancellationToken {
    private let lock = NSLock()
    private var isCancelledStorage = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelledStorage
    }

    func cancel() {
        lock.lock()
        isCancelledStorage = true
        lock.unlock()
    }
}

final class FileSearchService: NSObject {
    var onUpdate: ((SearchUpdate) -> Void)?

    /// Keeps broad searches bounded while allowing the UI to rank a substantially
    /// larger candidate set than it displays.
    private let candidateLimit = 20_000
    private let pathInputLimit = 1_000
    private let queryTimeout: TimeInterval = 30
    private let pathQueue = DispatchQueue(
        label: "com.lalalaladam.FindAll.path-search",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var generation = 0
    private var timeoutWorkItem: DispatchWorkItem?
    private var activeQuery: NSMetadataQuery?
    private var activeRequest: SearchRequest?
    private var activePathSearchToken: PathSearchCancellationToken?
    private var notificationTokens: [NSObjectProtocol] = []

    func search(_ request: SearchRequest) {
        precondition(Thread.isMainThread)
        generation += 1
        let currentGeneration = generation
        stopActiveQuery()

        if request.matchMode == .path {
            let inputs = request.pathInputs ?? PathInputParser.parse(request.text)
            guard inputs.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                onUpdate?(.idle)
                return
            }
            startPathSearch(inputs, generation: currentGeneration)
            return
        }

        if request.matchMode == .keywords {
            let keywords = KeywordSupport.normalized(request.keywords ?? [])
            guard !keywords.isEmpty else {
                onUpdate?(.idle)
                return
            }
            let normalizedRequest = SearchRequest(
                text: keywords.joined(separator: "\u{1F}"),
                category: request.category,
                scopePath: request.scopePath,
                matchMode: request.matchMode,
                pathInputs: nil,
                keywords: keywords,
                keywordRelation: request.keywordRelation
            )
            startQuery(normalizedRequest, generation: currentGeneration)
            return
        }

        let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onUpdate?(.idle)
            return
        }

        let normalizedRequest = SearchRequest(
            text: trimmed,
            category: request.category,
            scopePath: request.scopePath,
            matchMode: request.matchMode,
            pathInputs: nil,
            keywords: nil,
            keywordRelation: request.keywordRelation
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

    private func startPathSearch(_ inputs: [String], generation: Int) {
        guard generation == self.generation else { return }
        let token = PathSearchCancellationToken()
        activePathSearchToken = token
        onUpdate?(.pathStarted(inputs.count))
        let limit = pathInputLimit
        pathQueue.async { [weak self] in
            let output = Self.resolvePaths(inputs, limit: limit) { token.isCancelled }
            DispatchQueue.main.async {
                guard let self, generation == self.generation,
                      self.activePathSearchToken === token else { return }
                self.activePathSearchToken = nil
                self.onUpdate?(.pathResults(output.results, summary: output.summary))
            }
        }
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
        activePathSearchToken?.cancel()
        activePathSearchToken = nil
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
        case .keywords:
            let predicates = (request.keywords ?? []).map {
                NSPredicate(format: "%K CONTAINS[cd] %@", nameKey, $0)
            }
            switch predicates.count {
            case 0:
                namePredicate = NSPredicate(value: false)
            case 1:
                // NSMetadataQuery raises an Objective-C exception when asked to
                // generate metadata syntax for a one-child compound predicate.
                namePredicate = predicates[0]
            default:
                switch request.keywordRelation {
                case .all:
                    namePredicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
                case .any:
                    namePredicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
                }
            }
        case .path:
            namePredicate = NSPredicate(value: false)
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
        case .keywords:
            let keywords = request.keywords ?? []
            switch request.keywordRelation {
            case .all:
                return !keywords.isEmpty && keywords.allSatisfy {
                    name.range(of: $0, options: options) != nil
                }
            case .any:
                return keywords.contains {
                    name.range(of: $0, options: options) != nil
                }
            }
        case .path:
            return false
        }
    }

    private struct PathSearchOutput {
        var results: [SearchResult]
        var summary: PathSearchSummary
    }

    private static func resolvePaths(
        _ inputs: [String],
        limit: Int,
        isCancelled: () -> Bool
    ) -> PathSearchOutput {
        let submittedCount = inputs.count
        let limitedInputs = Array(inputs.prefix(limit))
        var results: [SearchResult] = []
        var seenPaths = Set<String>()
        var notFoundCount = 0
        var inaccessibleCount = 0
        var invalidCount = 0
        var duplicateCount = 0
        var issues: [PathSearchIssue] = []

        func recordIssue(_ input: String, reason: PathSearchIssue.Reason) {
            if issues.count < 50 {
                issues.append(PathSearchIssue(input: input, reason: reason))
            }
        }

        for input in limitedInputs {
            if isCancelled() { break }
            guard let url = pathURL(from: input) else {
                invalidCount += 1
                recordIssue(input, reason: .invalid)
                continue
            }
            let normalizedURL = FilePathSupport.userFacingURL(url).standardizedFileURL
            guard seenPaths.insert(normalizedURL.path).inserted else {
                duplicateCount += 1
                recordIssue(input, reason: .duplicate)
                continue
            }
            switch SearchResult.load(from: normalizedURL) {
            case let .success(result):
                results.append(result)
            case let .failure(failure):
                switch failure {
                case .notFound:
                    notFoundCount += 1
                    recordIssue(input, reason: .notFound)
                case .inaccessible:
                    inaccessibleCount += 1
                    recordIssue(input, reason: .inaccessible)
                }
            }
        }

        return PathSearchOutput(
            results: results,
            summary: PathSearchSummary(
                submittedCount: submittedCount,
                notFoundCount: notFoundCount,
                inaccessibleCount: inaccessibleCount,
                invalidCount: invalidCount,
                duplicateCount: duplicateCount,
                omittedCount: max(0, submittedCount - limitedInputs.count),
                issues: issues,
                hasMoreIssues: notFoundCount + inaccessibleCount + invalidCount + duplicateCount > issues.count
            )
        )
    }

    private static func pathURL(from input: String) -> URL? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.count >= 2,
           let first = value.first,
           let last = value.last,
           (first == "\"" && last == "\"" || first == "'" && last == "'") {
            value.removeFirst()
            value.removeLast()
        }
        guard !value.isEmpty else { return nil }

        if value.lowercased().hasPrefix("file:") {
            guard let url = URL(string: value), url.isFileURL,
                  url.host == nil || url.host?.isEmpty == true || url.host == "localhost" else { return nil }
            return url.standardizedFileURL
        }

        let expanded = (value as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL
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
        activePathSearchToken?.cancel()
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
