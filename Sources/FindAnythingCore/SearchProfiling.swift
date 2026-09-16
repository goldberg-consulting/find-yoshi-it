import Foundation

public struct QueryTiming: Codable, Sendable {
    public let stage: String
    public let milliseconds: Double
    public let rows: Int
}
public struct SearchProfile: Codable, Sendable {
    public let milliseconds: Double
    public let resultCount: Int
    public let timedOut: Bool
    public let error: String?
    public let stages: [QueryTiming]
}
extension SearchEngine {
    /// Read-only callers can measure a bounded search without recording query text or filenames.
    public func profile(_ request: SearchRequest, budgetSeconds: Double = 15) throws -> SearchProfile {
        database.profiling = true
        database.queryTimings = []
        defer { database.profiling = false }
        let start = Date()
        do {
            let result = try database.withQueryBudget(seconds: budgetSeconds) { try search(request) }
            return SearchProfile(milliseconds: Date().timeIntervalSince(start)*1000, resultCount: result.count, timedOut: false, error: nil, stages: database.queryTimings)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return SearchProfile(milliseconds: Date().timeIntervalSince(start)*1000, resultCount: 0, timedOut: (error as? SearchInterruption) == .timedOut, error: error.localizedDescription, stages: database.queryTimings)
        }
    }
}
