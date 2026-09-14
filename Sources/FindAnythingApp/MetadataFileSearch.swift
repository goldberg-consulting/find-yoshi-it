import Foundation
import FindAnythingCore

/// macOS name lookup supplements the content index only within explicitly registered local sources.
@MainActor
final class MetadataFileSearch {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<[SearchResult], Never>?
    private var sources: [SourceRecord] = []
    private var request = SearchRequest(query: "")

    static func search(_ request: SearchRequest, sources: [SourceRecord]) async -> [SearchResult] {
        let worker = MetadataFileSearch()
        return await withTaskCancellationHandler(operation: {
            await worker.run(request, sources: sources)
        }, onCancel: {
            Task { @MainActor in worker.finish() }
        })
    }

    private func run(_ request: SearchRequest, sources: [SourceRecord]) async -> [SearchResult] {
        guard !Task.isCancelled, !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.mode != .semantic else { return [] }
        self.request = request
        self.sources = sources.filter { $0.path != "/" && $0.kind != .network && $0.availability != .offline && $0.availability != .paused && (request.sourceID == nil || request.sourceID == $0.id) }
        guard !self.sources.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let query = NSMetadataQuery()
            query.searchScopes = self.sources.map { URL(fileURLWithPath: $0.path) }
            let words = request.query.split(whereSeparator: \.isWhitespace).prefix(12).map(String.init)
            let predicates = words.map { NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, $0) }
            // NSMetadataQuery rejects AND predicates with only one child.
            query.predicate = predicates.count == 1 ? predicates[0] : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            self.query = query
            observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.finish() }
            }
            guard query.start() else { finish(); return }
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                self?.finish()
            }
        }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        query?.disableUpdates()
        var results: [SearchResult] = []
        if let query {
            for index in 0..<min(query.resultCount, 200) {
                guard let item = query.result(at: index) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                      let result = Self.result(path: path, request: request, sources: sources) else { continue }
                results.append(result)
            }
            query.stop()
        }
        query = nil
        continuation.resume(returning: results)
    }

    static func result(path: String, request: SearchRequest, sources: [SourceRecord]) -> SearchResult? {
        let url = URL(fileURLWithPath: path)
        guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path,
              let source = sources.sorted(by: { $0.path.count > $1.path.count }).first(where: { path.hasPrefix($0.path + "/") && $0.availability != .offline && $0.availability != .paused && (request.sourceID == nil || request.sourceID == $0.id) }),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]), values.isRegularFile == true,
              FileManager.default.isReadableFile(atPath: path) else { return nil }
        let ext = url.pathExtension.lowercased()
        let isDocument = SearchPresentation.isDocument(extension: ext)
        if request.category == .documents && !isDocument || request.category == .other && isDocument { return nil }
        if let filter = request.fileExtension, !filter.isEmpty, filter != ext { return nil }
        let modified = values.contentModificationDate ?? .distantPast
        if let after = request.modifiedAfter, modified < after { return nil }
        let relative = String(path.dropFirst(source.path.count + 1))
        if SearchPresentation.isExcluded(relative, patterns: source.exclusions) { return nil }
        let query = request.query.lowercased()
        let exact = query.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) == url.lastPathComponent.lowercased()
        let tokens = query.split { $0.isWhitespace || $0 == "/" || $0 == "\"" }
        for component in SearchPresentation.dependencyDirectories where path.lowercased().split(separator: "/").contains(Substring(component)) {
            if !exact && !tokens.contains(Substring(component)) { return nil }
        }
        if ext == "node", !exact && !query.contains(".node") { return nil }
        if relative.split(separator: "/").contains(where: { $0.hasSuffix(".app") || $0.hasSuffix(".framework") }) { return nil }
        var hash: UInt64 = 14695981039346656037
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        var result = SearchResult(fileID: Int64(bitPattern: hash | (1 << 63)), sourceID: source.id, sourceName: source.name, filename: url.lastPathComponent, path: path, fileExtension: ext, modifiedAt: modified, status: .queued, detail: "Found by macOS; content indexing may still be in progress.", score: 1, matchKind: "Filename match")
        result.nameMatched = true
        return result
    }
}
