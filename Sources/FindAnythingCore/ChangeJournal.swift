import Foundation

/// Durable handoff from filesystem notifications to indexing. All SQLite access is serialized.
public final class ChangeJournal: @unchecked Sendable {
    public struct Batch: Sendable {
        public let through: Int64
        public let scopes: [String]
    }
    private let lock = NSLock()
    private let database: Database

    public init(url: URL) throws {
        database = try Database(url: url)
        try database.executeScript("""
            PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS change_streams(key TEXT PRIMARY KEY, identity TEXT NOT NULL, checkpoint TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS dirty_scopes(id INTEGER PRIMARY KEY AUTOINCREMENT, stream TEXT NOT NULL, scope TEXT NOT NULL, UNIQUE(stream,scope));
            """)
    }

    /// Establish a baseline before starting discovery. Invalid history requires a complete reconciliation.
    public func prepare(key: String, identity: String, current: UInt64) throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        if let row = try database.rows("SELECT * FROM change_streams WHERE key=?", [.text(key)]).first,
           row.string("identity") == identity, let checkpoint = UInt64(row.string("checkpoint")), checkpoint <= current {
            return checkpoint
        }
        try database.transaction {
            try database.execute("INSERT OR REPLACE INTO change_streams VALUES(?,?,?)", [.text(key), .text(identity), .text(String(current))])
            try database.execute("DELETE FROM dirty_scopes WHERE stream=?", [.text(key)])
            try database.execute("INSERT INTO dirty_scopes(stream,scope) VALUES(?,'')", [.text(key)])
        }
        return current
    }

    /// Queue work and advance the replay cursor in the same commit, before notifying a worker.
    public func capture(key: String, scopes: [String], checkpoint: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        try database.transaction {
            for scope in Set(scopes) {
                try database.execute("INSERT OR REPLACE INTO dirty_scopes(stream,scope) VALUES(?,?)", [.text(key), .text(scope)])
            }
            // Bound a burst of changes without losing any affected descendants.
            if try database.rows("SELECT COUNT(*) AS n FROM dirty_scopes WHERE stream=?", [.text(key)]).first!.int("n") > 512 {
                try database.execute("DELETE FROM dirty_scopes WHERE stream=?", [.text(key)])
                try database.execute("INSERT INTO dirty_scopes(stream,scope) VALUES(?,'')", [.text(key)])
            }
            try database.execute("UPDATE change_streams SET checkpoint=? WHERE key=?", [.text(String(checkpoint)), .text(key)])
        }
    }

    public func pending(key: String) throws -> Batch? {
        lock.lock(); defer { lock.unlock() }
        let rows = try database.rows("SELECT id,scope FROM dirty_scopes WHERE stream=? ORDER BY id", [.text(key)])
        guard let last = rows.last else { return nil }
        return Batch(through: last.int("id"), scopes: Self.minimalScopes(rows.map { $0.string("scope") }))
    }

    /// Events arriving during a scan have newer IDs and survive its acknowledgement.
    public func acknowledge(key: String, through: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        try database.execute("DELETE FROM dirty_scopes WHERE stream=? AND id<=?", [.text(key), .integer(through)])
    }

    public func forget(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        try database.transaction {
            try database.execute("DELETE FROM dirty_scopes WHERE stream=?", [.text(key)])
            try database.execute("DELETE FROM change_streams WHERE key=?", [.text(key)])
        }
        try database.purgeDeletedText()
    }

    public static func minimalScopes(_ scopes: [String]) -> [String] {
        var result: [String] = []
        for scope in Set(scopes).sorted() {
            guard !scope.hasPrefix("/"), !scope.split(separator: "/").contains("..") else { return [""] }
            if !result.contains(where: { $0.isEmpty || scope == $0 || scope.hasPrefix($0 + "/") }) { result.append(scope) }
        }
        return result
    }
}
