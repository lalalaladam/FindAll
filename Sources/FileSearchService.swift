import CoreServices
import Foundation

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

enum SearchUpdate {
    case idle
    case started
    case results([SearchResult], reachedLimit: Bool)
    case failed(SearchFailure)
}

final class FileSearchService {
    var onUpdate: ((SearchUpdate) -> Void)?

    private let resultLimit = 2_000
    private let queryTimeout: TimeInterval = 30
    private let queryQueue = DispatchQueue(
        label: "com.lalalaladam.FindAll.metadata-query",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var generation = 0
    private var timeoutWorkItem: DispatchWorkItem?
    private var activeQuery: MDQuery?

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
        let expression = Self.makeQueryExpression(for: request)
        guard let query = MDQueryCreate(kCFAllocatorDefault, expression as NSString, nil, nil) else {
            onUpdate?(.failed(.couldNotStart))
            return
        }

        MDQuerySetMaxCount(query, resultLimit)
        let scopes: NSArray
        if let scopePath = request.scopePath {
            scopes = [URL(fileURLWithPath: scopePath).standardizedFileURL.path]
        } else {
            scopes = [kMDQueryScopeAllIndexed!]
        }
        MDQuerySetSearchScope(query, scopes, 0)

        activeQuery = query
        NSLog(
            "FindAll bounded Spotlight query %d starting (mode=%@, category=%@, customScope=%@, limit=%d)",
            generation,
            request.matchMode.rawValue,
            request.category.rawValue,
            request.scopePath == nil ? "no" : "yes",
            resultLimit
        )
        onUpdate?(.started)

        let timeoutWorkItem = DispatchWorkItem { [weak self, weak query] in
            guard let self, let query, self.isCurrent(query, generation: generation) else { return }
            self.generation += 1
            self.stopActiveQuery()
            NSLog("FindAll bounded Spotlight query %d timed out", generation)
            self.onUpdate?(.failed(.timedOut))
        }
        self.timeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + queryTimeout, execute: timeoutWorkItem)

        queryQueue.async { [weak self] in
            let started = MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue))
            let count = max(0, Int(MDQueryGetResultCount(query)))
            let reachedLimit = count >= (self?.resultLimit ?? 2_000)
            let results = started ? Self.makeResults(from: query, count: count) : []
            DispatchQueue.main.async { [weak self] in
                self?.finishQuery(
                    query,
                    generation: generation,
                    started: started,
                    results: results,
                    reachedLimit: reachedLimit
                )
            }
        }
    }

    private func finishQuery(
        _ query: MDQuery,
        generation: Int,
        started: Bool,
        results: [SearchResult],
        reachedLimit: Bool
    ) {
        guard isCurrent(query, generation: generation) else { return }
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        activeQuery = nil
        guard started else {
            NSLog("FindAll bounded Spotlight query %d failed to execute", generation)
            onUpdate?(.failed(.couldNotStart))
            return
        }
        NSLog(
            "FindAll bounded Spotlight query %d finished with %d results (limitReached=%@)",
            generation,
            results.count,
            reachedLimit ? "yes" : "no"
        )
        onUpdate?(.results(results, reachedLimit: reachedLimit))
    }

    private func isCurrent(_ query: MDQuery, generation: Int) -> Bool {
        generation == self.generation && activeQuery.map { query === $0 } == true
    }

    private func stopActiveQuery() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        guard let query = activeQuery else { return }
        activeQuery = nil
        queryQueue.async {
            MDQueryStop(query)
        }
    }

    private static func makeQueryExpression(for request: SearchRequest) -> String {
        let escaped = escapeQueryValue(request.text)
        let pattern: String
        switch request.matchMode {
        case .contains:
            pattern = "*\(escaped)*"
        case .prefix:
            pattern = "\(escaped)*"
        case .exact:
            pattern = escaped
        }
        let nameExpression = "(kMDItemFSName == \"\(pattern)\"cd || kMDItemDisplayName == \"\(pattern)\"cd)"
        var expressions = [nameExpression]
        if let categoryExpression = request.category.metadataQueryExpression {
            expressions.append(categoryExpression)
        }
        return expressions.count == 1
            ? expressions[0]
            : "(" + expressions.joined(separator: " && ") + ")"
    }

    private static func escapeQueryValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
    }

    private static func makeResults(from query: MDQuery, count: Int) -> [SearchResult] {
        var results: [SearchResult] = []
        var seenURLs = Set<URL>()
        results.reserveCapacity(count)
        for index in 0..<count {
            guard let rawResult = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = unsafeBitCast(rawResult, to: MDItem.self)
            if let result = makeResult(item), seenURLs.insert(result.url.standardizedFileURL).inserted {
                results.append(result)
            }
        }
        return results
    }

    private static func makeResult(_ item: MDItem) -> SearchResult? {
        let names: NSArray = [
            kMDItemPath!,
            kMDItemDisplayName!,
            kMDItemFSName!,
            kMDItemKind!,
            kMDItemFSSize!,
            kMDItemContentModificationDate!,
            kMDItemContentTypeTree!
        ]
        guard let attributes = MDItemCopyAttributes(item, names) as? [String: Any],
              let path = attributes[kMDItemPath as String] as? String else { return nil }
        let url = FilePathSupport.userFacingURL(URL(fileURLWithPath: path))
        let displayName = attributes[kMDItemDisplayName as String] as? String
            ?? attributes[kMDItemFSName as String] as? String
            ?? url.lastPathComponent
        let typeTree = attributes[kMDItemContentTypeTree as String] as? [String] ?? []
        return SearchResult(
            url: url,
            displayName: displayName,
            kind: attributes[kMDItemKind as String] as? String ?? "",
            size: (attributes[kMDItemFSSize as String] as? NSNumber)?.int64Value,
            modifiedAt: attributes[kMDItemContentModificationDate as String] as? Date,
            isDirectory: typeTree.contains("public.folder")
        )
    }

    deinit {
        if let query = activeQuery {
            MDQueryStop(query)
        }
    }
}
