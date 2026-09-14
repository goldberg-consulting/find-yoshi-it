import Foundation

extension SearchEngine {
    /// Replace an indiscriminate startup crawl with small, independently resumable personal sources.
    /// The old source and its cached records are retained, paused, and can be explicitly resumed.
    public func prioritizePersonalSources(home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> [String] {
        guard try database.rows("SELECT key FROM settings WHERE key='personal-sources-v1'").isEmpty,
              let broad = try database.rows("SELECT id FROM sources WHERE path='/' AND paused=0").first else { return [] }
        var added: [String] = []
        for name in ["Documents", "Desktop", "Downloads"] {
            let directory = home.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            // A failure leaves the original source active and the migration retryable.
            let source = try await addSource(url: directory)
            added.append(source.id)
        }
        guard !added.isEmpty else { return [] }
        try database.transaction {
            try database.execute("UPDATE sources SET paused=1,availability='paused' WHERE id=?", [.text(broad.string("id"))])
            try database.execute("INSERT INTO settings(key,value) VALUES('personal-sources-v1','1')")
        }
        return added
    }
}
