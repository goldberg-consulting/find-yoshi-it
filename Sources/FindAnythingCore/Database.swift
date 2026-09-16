import Foundation
import CSQLite
import VectorMath

enum SQLValue {
    case text(String), integer(Int64), real(Double), blob(Data), null
    static func date(_ value: Date?) -> SQLValue { value.map { .real($0.timeIntervalSince1970) } ?? .null }
}

public enum SearchInterruption: Error, Sendable {
    case timedOut
}

struct DatabaseError: LocalizedError {
    var code: Int32 = 0
    var message: String
    var errorDescription: String? { message }
}

/// Confined to SearchEngine's actor. Prepared statements never escape a synchronous call.
final class Database {
    let url: URL
    let readOnly: Bool
    private var budgetActive = false
    var profiling = false
    var queryTimings: [QueryTiming] = []
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, readOnly: Bool = false) throws {
        self.url = url
        self.readOnly = readOnly
        if readOnly {
            let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
            guard result == SQLITE_OK else { throw error() }
            sqlite3_busy_timeout(handle, 250)
            try executeScript("PRAGMA query_only=ON; PRAGMA cache_size=-8192;")
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else { throw error() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_busy_timeout(handle, 5000)
        try executeScript("""
            PRAGMA foreign_keys=ON;
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            PRAGMA secure_delete=ON;
            PRAGMA cache_size=-32768;
            PRAGMA mmap_size=0;
            PRAGMA temp_store=FILE;
            CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS sources(
                id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL, kind TEXT NOT NULL,
                availability TEXT NOT NULL, last_scan REAL, last_error TEXT, exclusions TEXT NOT NULL,
                offline_content INTEGER NOT NULL DEFAULT 1, ocr INTEGER NOT NULL DEFAULT 1,
                identity TEXT NOT NULL, bookmark BLOB, paused INTEGER NOT NULL DEFAULT 0, scan_generation TEXT, scan_incomplete INTEGER NOT NULL DEFAULT 0
            );
            CREATE UNIQUE INDEX IF NOT EXISTS sources_identity ON sources(identity);
            CREATE TABLE IF NOT EXISTS contents(
                id INTEGER PRIMARY KEY, fingerprint TEXT NOT NULL, extractor TEXT NOT NULL,
                status TEXT NOT NULL, detail TEXT, UNIQUE(fingerprint,extractor)
            );
            CREATE TABLE IF NOT EXISTS files(
                id INTEGER PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                relative_path TEXT NOT NULL, name TEXT NOT NULL, ext TEXT NOT NULL, size INTEGER NOT NULL,
                mtime REAL NOT NULL, generation TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'queued',
                detail TEXT, content_id INTEGER REFERENCES contents(id), fingerprint TEXT,
                indexed_at REAL, indexed_mtime REAL, UNIQUE(source_id,relative_path)
            );
            CREATE INDEX IF NOT EXISTS files_source ON files(source_id,generation);
            CREATE INDEX IF NOT EXISTS files_content ON files(content_id);
            CREATE INDEX IF NOT EXISTS files_filter ON files(source_id,ext,mtime);
            CREATE INDEX IF NOT EXISTS files_recent ON files(mtime DESC);
            CREATE TABLE IF NOT EXISTS passages(
                id INTEGER PRIMARY KEY AUTOINCREMENT, content_id INTEGER NOT NULL REFERENCES contents(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL, text TEXT NOT NULL, location TEXT NOT NULL,
                page INTEGER, line INTEGER, sheet TEXT, cell TEXT
            );
            CREATE INDEX IF NOT EXISTS passages_content ON passages(content_id,ordinal);
            CREATE VIRTUAL TABLE IF NOT EXISTS passage_fts USING fts5(text,content='passages',content_rowid='id',tokenize='unicode61 remove_diacritics 2');
            CREATE TRIGGER IF NOT EXISTS passages_insert AFTER INSERT ON passages BEGIN
                INSERT INTO passage_fts(rowid,text) VALUES(new.id,new.text);
            END;
            CREATE TRIGGER IF NOT EXISTS passages_delete AFTER DELETE ON passages BEGIN
                INSERT INTO passage_fts(passage_fts,rowid,text) VALUES('delete',old.id,old.text);
            END;
            CREATE VIRTUAL TABLE IF NOT EXISTS file_fts USING fts5(name,relative_path,content='files',content_rowid='id',tokenize='unicode61 remove_diacritics 2');
            CREATE TRIGGER IF NOT EXISTS files_insert AFTER INSERT ON files BEGIN
                INSERT INTO file_fts(rowid,name,relative_path) VALUES(new.id,new.name,new.relative_path);
            END;
            CREATE TRIGGER IF NOT EXISTS files_delete AFTER DELETE ON files BEGIN
                INSERT INTO file_fts(file_fts,rowid,name,relative_path) VALUES('delete',old.id,old.name,old.relative_path);
            END;
            CREATE TRIGGER IF NOT EXISTS files_update AFTER UPDATE OF name,relative_path ON files BEGIN
                INSERT INTO file_fts(file_fts,rowid,name,relative_path) VALUES('delete',old.id,old.name,old.relative_path);
                INSERT INTO file_fts(rowid,name,relative_path) VALUES(new.id,new.name,new.relative_path);
            END;
            CREATE TABLE IF NOT EXISTS jobs(
                file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
                phase TEXT NOT NULL DEFAULT 'text', attempts INTEGER NOT NULL DEFAULT 0, retry_at REAL NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS jobs_ready ON jobs(phase,retry_at,file_id);
            CREATE TABLE IF NOT EXISTS scan_directories(
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE, relative_path TEXT NOT NULL,
                done INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source_id,relative_path)
            );
            CREATE TABLE IF NOT EXISTS vectors(
                passage_id INTEGER PRIMARY KEY REFERENCES passages(id) ON DELETE CASCADE,
                model TEXT NOT NULL, vector BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS vector_buckets(
                bucket INTEGER NOT NULL, passage_id INTEGER NOT NULL REFERENCES vectors(passage_id) ON DELETE CASCADE,
                PRIMARY KEY(bucket,passage_id)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS vector_buckets_passage ON vector_buckets(passage_id);
            PRAGMA user_version=1;
            """)
        try execute("UPDATE sources SET availability=CASE WHEN paused=1 THEN 'paused' ELSE 'offline' END WHERE availability='scanning'")
        if try !rows("PRAGMA table_info(sources)").contains(where:{$0.string("name") == "scan_generation"}) {
            try execute("ALTER TABLE sources ADD COLUMN scan_generation TEXT")
        }
        if try !rows("PRAGMA table_info(sources)").contains(where:{$0.string("name") == "scan_incomplete"}) {
            try execute("ALTER TABLE sources ADD COLUMN scan_incomplete INTEGER NOT NULL DEFAULT 0")
        }
        if try !rows("PRAGMA table_info(sources)").contains(where: { $0.string("name") == "scan_scopes" }) {
            try execute("ALTER TABLE sources ADD COLUMN scan_scopes TEXT")
        }
        if try !rows("PRAGMA table_info(files)").contains(where: { $0.string("name") == "ctime" }) {
            try execute("ALTER TABLE files ADD COLUMN ctime REAL NOT NULL DEFAULT 0")
        }
        if try rows("SELECT key FROM settings WHERE key='dependency-search-defaults-v1'").isEmpty {
            try transaction {
                for row in try rows("SELECT id,exclusions FROM sources") {
                    guard let data = row.string("exclusions").data(using: .utf8),
                          let exclusions = try? JSONDecoder().decode([String].self, from: data),
                          Set(exclusions) == Set([".git", "node_modules", ".build", ".DS_Store"]) else { continue }
                    let updated = String(decoding: try JSONEncoder().encode(exclusions.filter { $0 != "node_modules" }), as: UTF8.self)
                    try execute("UPDATE sources SET exclusions=? WHERE id=?", [.text(updated), .text(row.string("id"))])
                }
                try execute("INSERT INTO settings(key,value) VALUES('dependency-search-defaults-v1','1')")
            }
        }
        try executeScript("""
            CREATE INDEX IF NOT EXISTS files_name_lower ON files(lower(name));
            CREATE VIRTUAL TABLE IF NOT EXISTS file_name_grams USING fts5(name,content='files',content_rowid='id',tokenize='trigram');
            CREATE TRIGGER IF NOT EXISTS files_grams_insert AFTER INSERT ON files BEGIN
                INSERT INTO file_name_grams(rowid,name) VALUES(new.id,new.name);
            END;
            CREATE TRIGGER IF NOT EXISTS files_grams_delete AFTER DELETE ON files BEGIN
                INSERT INTO file_name_grams(file_name_grams,rowid,name) VALUES('delete',old.id,old.name);
            END;
            CREATE TRIGGER IF NOT EXISTS files_grams_update AFTER UPDATE OF name ON files BEGIN
                INSERT INTO file_name_grams(file_name_grams,rowid,name) VALUES('delete',old.id,old.name);
                INSERT INTO file_name_grams(rowid,name) VALUES(new.id,new.name);
            END;
            """)
        if try rows("SELECT key FROM settings WHERE key='filename-grams-v1'").isEmpty {
            try transaction {
                try execute("INSERT INTO file_name_grams(file_name_grams) VALUES('rebuild')")
                try execute("INSERT INTO settings(key,value) VALUES('filename-grams-v1','1')")
            }
        }
        try enableFTSSecureDeletion()
    }

    deinit { sqlite3_close(handle) }

    /// Removes deleted search terms from FTS segments and the write-ahead log.
    /// Call after the deletion transaction commits. Retained documents stay searchable.
    func purgeDeletedText() throws {
        guard sqlite3_get_autocommit(handle) != 0 else {
            throw DatabaseError(message: "Cache erasure requires a committed transaction.")
        }
        // Compaction also removes old segments written before FTS secure deletion was enabled.
        try transaction {
            try execute("INSERT INTO passage_fts(passage_fts) VALUES('optimize')")
            try execute("INSERT INTO file_fts(file_fts) VALUES('optimize')")
            try execute("INSERT INTO file_name_grams(file_name_grams) VALUES('optimize')")
        }
        let checkpoint = try rows("PRAGMA wal_checkpoint(TRUNCATE)").first
        guard checkpoint?.int("busy") == 0 else {
            throw DatabaseError(message: "Cached results were removed, but another reader is delaying local cache erasure. Close other instances and retry.")
        }
    }

    private func enableFTSSecureDeletion() throws {
        for sql in [
            "INSERT INTO passage_fts(passage_fts,rank) VALUES('secure-delete',1)",
            "INSERT INTO file_fts(file_fts,rank) VALUES('secure-delete',1)",
            "INSERT INTO file_name_grams(file_name_grams,rank) VALUES('secure-delete',1)"
        ] {
            let statement = try prepare(sql, [])
            let code = sqlite3_step(statement)
            sqlite3_finalize(statement)
            // Older macOS SQLite versions reject this option; explicit purges still compact FTS.
            guard code == SQLITE_DONE || code == SQLITE_ERROR else { throw error() }
        }
    }

    func executeScript(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    func execute(_ sql: String, _ arguments: [SQLValue] = []) throws {
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw error() }
    }

    func rows(_ sql: String, _ arguments: [SQLValue] = []) throws -> [SQLRow] {
        let started = Date()
        var result: [SQLRow] = []
        defer {
            if profiling {
                let stage = sql.contains("vector_buckets") ? "vector buckets" : sql.contains("FROM vectors") ? "vector eligibility" : sql.contains("passage_fts") ? "content FTS" : sql.contains("file_name_grams") ? "filename trigram" : sql.contains("file_fts") ? "filename FTS" : sql.contains("instr(lower(f.name)") ? "filename substring" : "result hydration"
                queryTimings.append(QueryTiming(stage: stage, milliseconds: Date().timeIntervalSince(started) * 1000, rows: result.count))
            }
        }
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw error() }
            var row: [String: SQLValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement,index))
                switch sqlite3_column_type(statement,index) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement,index))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement,index))
                case SQLITE_TEXT: row[name] = .text(String(cString:sqlite3_column_text(statement,index)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement,index))
                    if let bytes = sqlite3_column_blob(statement,index) { row[name] = .blob(Data(bytes:bytes,count:count)) }
                    else { row[name] = .blob(Data()) }
                default: row[name] = .null
                }
            }
            result.append(SQLRow(values:row))
        }
    }

    /// Stream packed vectors directly from SQLite. Keep one strongest passage per content,
    /// so long spreadsheets and duplicate locations cannot consume the candidate budget.
    func exactVectorCandidates(_ sql: String, _ arguments: [SQLValue], query: [Float], limit: Int) throws -> [(Int64, Double)] {
        let start = Date()
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        var best: [Int64: (Int64, Double)] = [:]
        var count = 0
        let queryNorm = sqrt(query.reduce(0.0) { $0 + Double($1) * Double($1) })
        try query.withUnsafeBufferPointer { buffer in
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw error() }
                count += 1
                guard let blob = sqlite3_column_blob(statement, 2) else { continue }
                let score = fy_packed_cosine_with_norm(blob.assumingMemoryBound(to: UInt8.self), Int(sqlite3_column_bytes(statement, 2)), buffer.baseAddress, buffer.count, queryNorm)
                guard score >= 0.30 else { continue }
                let content = sqlite3_column_int64(statement, 1)
                if score > (best[content]?.1 ?? -1) { best[content] = (sqlite3_column_int64(statement, 0), score) }
            }
        }
        if profiling { queryTimings.append(QueryTiming(stage: "exact packed vectors", milliseconds: Date().timeIntervalSince(start)*1000, rows: count)) }
        return Array(best.values.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.prefix(limit))
    }

    func withQueryBudget<T>(seconds: Double, _ operation: () throws -> T) throws -> T {
        if budgetActive { return try operation() }
        budgetActive = true
        defer { budgetActive = false }
        let budget = QueryBudget(deadline: Date().addingTimeInterval(seconds))
        let context = Unmanaged.passUnretained(budget).toOpaque()
        sqlite3_progress_handler(handle, 1000, { context in
            guard let context else { return 0 }
            let budget = Unmanaged<QueryBudget>.fromOpaque(context).takeUnretainedValue()
            return Task.isCancelled || Date() >= budget.deadline ? 1 : 0
        }, context)
        defer { sqlite3_progress_handler(handle, 0, nil, nil) }
        try Task.checkCancellation()
        do {
            return try withExtendedLifetime(budget) { try operation() }
        } catch let failure as DatabaseError where failure.code == SQLITE_INTERRUPT {
            if Task.isCancelled { throw CancellationError() }
            throw SearchInterruption.timedOut
        }
    }

    var lastID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private func prepare(_ sql: String, _ arguments: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle,sql,-1,&statement,nil) == SQLITE_OK, let statement else { throw error() }
        for (offset,value) in arguments.enumerated() {
            let index = Int32(offset+1)
            let code: Int32
            switch value {
            case .text(let text): code = sqlite3_bind_text(statement,index,text,-1,transient)
            case .integer(let value): code = sqlite3_bind_int64(statement,index,value)
            case .real(let value): code = sqlite3_bind_double(statement,index,value)
            case .null: code = sqlite3_bind_null(statement,index)
            case .blob(let data): code = data.withUnsafeBytes { sqlite3_bind_blob(statement,index,$0.baseAddress,Int32(data.count),transient) }
            }
            if code != SQLITE_OK { sqlite3_finalize(statement); throw error() }
        }
        return statement
    }

    private func error() -> DatabaseError { DatabaseError(code: handle.map { sqlite3_errcode($0) } ?? SQLITE_ERROR, message:handle.map { String(cString:sqlite3_errmsg($0)) } ?? "Could not open the local index.") }
}

struct SQLRow {
    var values: [String: SQLValue]
    func string(_ key: String) -> String { if case .text(let v) = values[key] { return v }; return "" }
    func optionalString(_ key: String) -> String? { if case .text(let v) = values[key] { return v }; return nil }
    func int(_ key: String) -> Int64 { if case .integer(let v) = values[key] { return v }; return Int64(double(key)) }
    func double(_ key: String) -> Double { if case .real(let v) = values[key] { return v }; if case .integer(let v) = values[key] { return Double(v) }; return 0 }
    func date(_ key: String) -> Date? { switch values[key] { case .real(let v): return Date(timeIntervalSince1970:v); case .integer(let v): return Date(timeIntervalSince1970:Double(v)); default: return nil } }
    func data(_ key: String) -> Data? { if case .blob(let v) = values[key] { return v }; return nil }
    func optionalInt(_ key: String) -> Int? { if case .integer(let v) = values[key] { return Int(v) }; return nil }
}

private final class QueryBudget {
    let deadline: Date
    init(deadline: Date) { self.deadline = deadline }
}
