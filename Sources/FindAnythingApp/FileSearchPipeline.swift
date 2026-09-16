import Foundation
import FindAnythingCore

/// Independent channels publish as they finish; slow content work never holds up names.
@MainActor
struct FileSearchPipeline {
    typealias Lookup = @Sendable (SearchRequest) async throws -> [SearchResult]
    let names: Lookup
    let content: Lookup
    let metadata: Lookup

    func search(_ request: SearchRequest, onUpdate: (([SearchResult]) -> Void)? = nil) async throws -> [SearchResult] {
        return try await withThrowingTaskGroup(of: ([SearchResult], Bool).self) { group in
            if request.mode != .semantic {
                var fast = request
                fast.namesOnly = true
                let fastRequest = fast
                group.addTask { ((try? await names(fastRequest)) ?? [], false) }
                group.addTask { ((try? await metadata(request)) ?? [], false) }
            }
            group.addTask {
                do { return (try await content(request), false) }
                catch SearchInterruption.timedOut { return ([], true) }
            }
            var timedOut = false
            var combined: [String: SearchResult] = [:]
            var ranked: [SearchResult] = []
            for try await (batch, timeout) in group {
                timedOut = timedOut || timeout
                try Task.checkCancellation()
                for item in batch {
                    if let existing = combined[item.path] {
                        var best = existing
                        if item.fileID > 0 && (existing.fileID < 0 || item.passages.count > existing.passages.count) { best = item }
                        best.nameMatched = existing.nameMatched || item.nameMatched
                        best.score = max(existing.score, item.score)
                        combined[item.path] = best
                    } else { combined[item.path] = item }
                }
                ranked = Array(combined.values.sorted {
                    let a = SearchPresentation.isDocument(extension: $0.fileExtension), b = SearchPresentation.isDocument(extension: $1.fileExtension)
                    if a != b { return a }
                    if $0.nameMatched != $1.nameMatched { return $0.nameMatched }
                    if $0.score != $1.score { return $0.score > $1.score }
                    return $0.path < $1.path
                }.prefix(request.limit))
                onUpdate?(ranked)
            }
            // Drain independent channels before reporting incomplete content results.
            // Their published results remain useful even when content exceeds its budget.
            if timedOut { throw SearchInterruption.timedOut }
            return ranked
        }
    }
}
