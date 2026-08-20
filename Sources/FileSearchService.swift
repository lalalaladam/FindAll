import Foundation

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
}

enum SearchFailure {
    case couldNotStart
    case timedOut
}

enum SearchUpdate {
    case idle
    case started
    case gathering(Int)
    case results([SearchResult])
    case failed(SearchFailure)
}

final class FileSearchService: NSObject {
    var onUpdate: ((SearchUpdate) -> Void)?

    private let resultLimit = 2_000
    private let queryTimeout: TimeInterval = 12
    private var generation = 0
    private var timeoutWorkItem: DispatchWorkItem?
    private var activeQuery: NSMetadataQuery?
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

        let normalizedRequest = SearchRequest(text: trimmed, category: request.category, scopePath: request.scopePath)
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
        let terms = request.text.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard !terms.isEmpty else {
            onUpdate?(.idle)
            return
        }

        let query = NSMetadataQuery()
        query.predicate = Self.makePredicate(terms: terms, category: request.category)
        query.notificationBatchingInterval = 0.2
        if let scopePath = request.scopePath {
            // Foundation accepts file URLs or path strings here. A path string avoids
            // Swift/Objective-C bridging issues seen with search-scope values on macOS.
            query.searchScopes = [URL(fileURLWithPath: scopePath).standardizedFileURL.path]
        }
        // An empty/default scope searches all locations. Do not assign
        // NSMetadataQueryLocalComputerScope: on the affected macOS runtime,
        // setSearchScopes: raises NSInvalidArgumentException for that value.

        activeQuery = query
        observe(query, generation: generation)
        NSLog(
            "FindAll Spotlight query %d starting (terms=%d, category=%@, customScope=%@)",
            generation,
            terms.count,
            request.category.rawValue,
            request.scopePath == nil ? "no" : "yes"
        )
        onUpdate?(.started)
        guard query.start() else {
            NSLog("FindAll Spotlight query %d failed to start", generation)
            stopActiveQuery()
            onUpdate?(.failed(.couldNotStart))
            return
        }
        let timeoutWorkItem = DispatchWorkItem { [weak self, weak query] in
            guard let self, let query, generation == self.generation, query === self.activeQuery else { return }
            self.handleTimeout(for: query, generation: generation)
        }
        self.timeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + queryTimeout, execute: timeoutWorkItem)
    }

    private static func makePredicate(terms: [String], category: SearchCategory) -> NSPredicate {
        let namePredicates = terms.map { term in
            let pattern = "*\(escapeLikePattern(term))*"
            return NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, pattern),
                NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemDisplayNameKey, pattern)
            ])
        }
        var predicates: [NSPredicate] = namePredicates
        if let categoryPredicate = category.metadataPredicate {
            predicates.append(categoryPredicate)
        }
        // NSMetadataQuery rejects an AND compound predicate containing only one
        // subpredicate. This is the common single-term + All category case.
        if predicates.count == 1, let predicate = predicates.first {
            return predicate
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }

    private static func escapeLikePattern(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
    }

    private func observe(_ query: NSMetadataQuery, generation: Int) {
        let center = NotificationCenter.default
        let started = center.addObserver(
            forName: NSNotification.Name.NSMetadataQueryDidStartGathering,
            object: query,
            queue: .main
        ) { [weak self, weak query] _ in
            guard let self, let query, self.isCurrent(query, generation: generation) else { return }
            NSLog("FindAll Spotlight query %d began gathering", generation)
            self.onUpdate?(.gathering(0))
        }
        let progress = center.addObserver(
            forName: NSNotification.Name.NSMetadataQueryGatheringProgress,
            object: query,
            queue: .main
        ) { [weak self, weak query] _ in
            guard let self, let query, self.isCurrent(query, generation: generation) else { return }
            self.onUpdate?(.gathering(min(query.resultCount, self.resultLimit)))
        }
        let finished = center.addObserver(
            forName: NSNotification.Name.NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self, weak query] _ in
            guard let self, let query, self.isCurrent(query, generation: generation) else { return }
            self.timeoutWorkItem?.cancel()
            self.timeoutWorkItem = nil
            NSLog("FindAll Spotlight query %d finished with %d candidates", generation, query.resultCount)
            self.publishResults(from: query, generation: generation)
        }
        let updated = center.addObserver(
            forName: NSNotification.Name.NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self, weak query] _ in
            guard let self, let query, self.isCurrent(query, generation: generation), !query.isGathering else { return }
            self.publishResults(from: query, generation: generation)
        }
        notificationTokens = [started, progress, finished, updated]
    }

    private func isCurrent(_ query: NSMetadataQuery, generation: Int) -> Bool {
        generation == self.generation && query === activeQuery
    }

    private func handleTimeout(for query: NSMetadataQuery, generation: Int) {
        let resultCount = query.resultCount
        NSLog(
            "FindAll Spotlight query %d timed out (started=%@, gathering=%@, candidates=%d)",
            generation,
            query.isStarted ? "yes" : "no",
            query.isGathering ? "yes" : "no",
            resultCount
        )
        if resultCount > 0 {
            publishResults(from: query, generation: generation)
        } else {
            stopActiveQuery()
            onUpdate?(.failed(.timedOut))
        }
    }

    private func publishResults(from query: NSMetadataQuery, generation: Int) {
        guard isCurrent(query, generation: generation) else { return }
        query.disableUpdates()
        defer {
            if query === activeQuery { query.enableUpdates() }
        }

        let count = min(query.resultCount, resultLimit)
        var results: [SearchResult] = []
        results.reserveCapacity(count)
        for index in 0..<count {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let result = Self.makeResult(item) else { continue }
            results.append(result)
        }
        onUpdate?(.results(results))
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

        let displayName = item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String
            ?? item.value(forAttribute: NSMetadataItemFSNameKey) as? String
            ?? url.lastPathComponent
        let typeTree = item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []
        return SearchResult(
            url: url,
            displayName: displayName,
            kind: item.value(forAttribute: NSMetadataItemKindKey) as? String ?? "",
            size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value,
            modifiedAt: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
            isDirectory: typeTree.contains("public.folder")
        )
    }

    private func stopActiveQuery() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        activeQuery?.stop()
        activeQuery = nil
    }

    deinit {
        stopActiveQuery()
    }
}
