import Foundation

struct SearchResult: Hashable {
    let url: URL
    let displayName: String
    let kind: String
    let size: Int64?
    let modifiedAt: Date?

    var path: String { url.deletingLastPathComponent().path }
}

final class FileSearchService: NSObject {
    var onResultsChanged: (([SearchResult], Bool) -> Void)?

    private var generation = 0
    private var debounceTimer: Timer?
    private var runningProcess: Process?

    func search(text: String) {
        generation += 1
        let currentGeneration = generation
        debounceTimer?.invalidate()
        stopRunningProcess()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onResultsChanged?([], false)
            return
        }

        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            guard let self, currentGeneration == self.generation else { return }
            self.startSearch(text: trimmed, generation: currentGeneration)
        }
    }

    func cancel() {
        generation += 1
        debounceTimer?.invalidate()
        stopRunningProcess()
    }

    private func startSearch(text: String, generation: Int) {
        let terms = text.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard !terms.isEmpty else {
            onResultsChanged?([], false)
            return
        }

        let expression = terms.map {
            let value = escapeMetadataValue($0)
            return "((kMDItemFSName == \"*\(value)*\"cd) || (kMDItemDisplayName == \"*\(value)*\"cd))"
        }.joined(separator: " && ")

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = [expression]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        runningProcess = process
        onResultsChanged?([], true)

        do {
            try process.run()
        } catch {
            runningProcess = nil
            NSLog("FindAll could not launch mdfind: %@", error.localizedDescription)
            onResultsChanged?([], false)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak process] in
            guard let self, let process else { return }
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let paths = String(data: output, encoding: .utf8)?
                .split(separator: "\n", omittingEmptySubsequences: true)
                .prefix(2_000)
                .map(String.init) ?? []
            let results = paths.compactMap(Self.makeResult(path:))
            let errorText = String(data: errorOutput, encoding: .utf8) ?? ""

            DispatchQueue.main.async { [weak self, weak process] in
                guard let self, let process,
                      generation == self.generation,
                      process === self.runningProcess else { return }
                self.runningProcess = nil
                if process.terminationStatus == 0 {
                    self.onResultsChanged?(results, false)
                } else {
                    NSLog("FindAll mdfind failed (%d): %@", process.terminationStatus, errorText)
                    self.onResultsChanged?([], false)
                }
            }
        }
    }

    private static func makeResult(path: String) -> SearchResult? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .nameKey,
            .localizedTypeDescriptionKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let values = try? url.resourceValues(forKeys: keys)
        return SearchResult(
            url: url,
            displayName: values?.name ?? url.lastPathComponent,
            kind: values?.localizedTypeDescription ?? "",
            size: values?.fileSize.map(Int64.init),
            modifiedAt: values?.contentModificationDate
        )
    }

    private func stopRunningProcess() {
        guard let process = runningProcess else { return }
        runningProcess = nil
        if process.isRunning {
            process.terminate()
        }
    }

    private func escapeMetadataValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
    }

    deinit {
        debounceTimer?.invalidate()
        stopRunningProcess()
    }
}
