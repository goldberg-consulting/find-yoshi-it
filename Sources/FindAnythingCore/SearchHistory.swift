import Foundation

/// Successful opens only; history never introduces a nonmatching result or crosses category/name tiers.
public actor SearchHistory {
    private let database: Database
    public init(url: URL) throws {
        database = try Database(url: url)
        try database.executeScript("CREATE TABLE IF NOT EXISTS opens(query TEXT NOT NULL,path TEXT NOT NULL,count INTEGER NOT NULL,last_open REAL NOT NULL,PRIMARY KEY(query,path));")
    }
    private func normalized(_ query: String) -> String { String(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(512)) }
    public func record(query: String, path: String, at date: Date = Date()) throws {
        let query = normalized(query)
        guard !query.isEmpty else { return }
        try database.execute("INSERT INTO opens VALUES(?,?,1,?) ON CONFLICT(query,path) DO UPDATE SET count=count+1,last_open=excluded.last_open", [.text(query), .text(path), .real(date.timeIntervalSince1970)])
        try database.execute("DELETE FROM opens WHERE last_open<?", [.real(date.addingTimeInterval(-90*86400).timeIntervalSince1970)])
    }
    private func scores(_ query: String, now: Date) throws -> [String: Double] {
        var result: [String: Double] = [:]
        for row in try database.rows("SELECT * FROM opens WHERE last_open>?", [.real(now.addingTimeInterval(-90*86400).timeIntervalSince1970)]) {
            let age = max(0, now.timeIntervalSince1970 - row.double("last_open")) / 86400
            let weight = log1p(Double(row.int("count"))) * pow(0.5, age / 14)
            result[row.string("path"), default: 0] += weight * (row.string("query") == normalized(query) ? 100 : 1)
        }
        return result
    }
    public func rank(_ applications: [ApplicationRecord], query: String, now: Date = Date()) throws -> [ApplicationRecord] {
        let scores = try scores(query, now: now)
        return applications.enumerated().sorted {
            let a = scores[$0.element.path, default: 0], b = scores[$1.element.path, default: 0]
            return a == b ? $0.offset < $1.offset : a > b
        }.map(\.element)
    }
    public func rank(_ documents: [SearchResult], query: String, now: Date = Date()) throws -> [SearchResult] {
        let scores = try scores(query, now: now)
        return documents.enumerated().sorted {
            let a = $0.element, b = $1.element
            let ad = SearchPresentation.isDocument(extension: a.fileExtension), bd = SearchPresentation.isDocument(extension: b.fileExtension)
            if ad != bd { return ad }
            if a.nameMatched != b.nameMatched { return a.nameMatched }
            let av = scores[a.path, default: 0], bv = scores[b.path, default: 0]
            return av == bv ? $0.offset < $1.offset : av > bv
        }.map(\.element)
    }
}
