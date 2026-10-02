import Foundation
import Darwin

public actor SearchEngine {
    let database: Database
    let encoder = SemanticEncoder()
    var activeScans = Set<String>()
    var pendingScanScopes: [String: [String]] = [:]
    var priorityScanScopes: [String: [String]] = [:]
    let databaseURL: URL
    let onAccessRevoked: (@Sendable (Int64) -> Void)?
    var revokedFiles: [Int64: Date] = [:]

    public init(databaseURL: URL, readOnly: Bool = false, onAccessRevoked: (@Sendable (Int64) -> Void)? = nil) throws {
        self.onAccessRevoked = onAccessRevoked
        self.databaseURL = databaseURL
        self.database = try Database(url:databaseURL, readOnly: readOnly)
    }

    public func invalidateAccess(fileID: Int64) throws {
        try revokeFile(fileID)
    }

    public func sourceIsPaused(_ id: String) throws -> Bool {
        try rawSource(id).int("paused") != 0
    }

    public func sourceIsOnline(_ id: String) throws -> Bool {
        try rawSource(id).string("availability") == "online"
    }

    public func sources() throws -> [SourceRecord] {
        let counts = try database.rows("""
            SELECT source_id, COUNT(*) AS files,
                SUM(CASE WHEN status IN ('indexed','partial','needsOCR') THEN 1 ELSE 0 END) AS indexed,
                SUM(CASE WHEN status IN ('queued','needsOCR') THEN 1 ELSE 0 END) AS pending,
                SUM(CASE WHEN status IN ('failed','locked','denied','partial') THEN 1 ELSE 0 END) AS failed,
                SUM(CASE WHEN status='unsupported' THEN 1 ELSE 0 END) AS unsupported FROM files GROUP BY source_id
            """)
        let byID = Dictionary(uniqueKeysWithValues:counts.map { ($0.string("source_id"),$0) })
        return try database.rows("SELECT * FROM sources ORDER BY name COLLATE NOCASE").map { row in
            let counts = byID[row.string("id")]
            return SourceRecord(id:row.string("id"),name:row.string("name"),path:row.string("path"),kind:SourceKind(rawValue:row.string("kind")) ?? .local,availability:SourceAvailability(rawValue:row.string("availability")) ?? .offline,lastScan:row.date("last_scan"),lastError:row.optionalString("last_error"),exclusions:decodeExclusions(row.string("exclusions")),allowsOfflineContent:row.int("offline_content") != 0,ocrEnabled:row.int("ocr") != 0,fileCount:Int(counts?.int("files") ?? 0),indexedCount:Int(counts?.int("indexed") ?? 0),pendingCount:Int(counts?.int("pending") ?? 0),failedCount:Int(counts?.int("failed") ?? 0),unsupportedCount:Int(counts?.int("unsupported") ?? 0))
        }
    }

    /// Register an explicitly selected location, with bounded filesystem probing and cancellation.
    public func addSource(url: URL, expectedNetworkShare: MountedNetworkShare? = nil) async throws -> SourceRecord {
        try await addSource(url: url, expectedNetworkShare: expectedNetworkShare, registration: .shared)
    }

    func addSource(url: URL, expectedNetworkShare: MountedNetworkShare? = nil, registration: SourceRegistration) async throws -> SourceRecord {
        try Task.checkCancellation()
        if let expectedNetworkShare {
            guard url.path == expectedNetworkShare.path,
                  MountedNetworkShare.mounted().contains(expectedNetworkShare) else {
                throw DatabaseError(message: "This share disconnected or changed. Connect it again before adding it.")
            }
        }
        let inspected = try await registration.inspect(url)
        try Task.checkCancellation()
        let root = inspected.root
        let identity = inspected.identity
        if let expectedNetworkShare {
            guard identity.kind == .network, root.path == expectedNetworkShare.path,
                  MountedNetworkShare.mounted().contains(expectedNetworkShare) else {
                throw DatabaseError(message: "This share disconnected or changed. Connect it again before adding it.")
            }
        }
        // Adding a remounted share reuses its catalog and independent permission scope.
        if let existing = try database.rows("SELECT id FROM sources WHERE identity=?",[.text(identity.identity)]).first {
            try database.execute("UPDATE sources SET path=?,bookmark=?,availability='online',last_error=NULL WHERE id=?",[.text(root.path),bookmark(root),.text(existing.string("id"))])
            return try source(existing.string("id"))
        }
        let value = SourceRecord(name:root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent,path:root.path,kind:identity.kind)
        try database.execute("INSERT INTO sources(id,name,path,kind,availability,exclusions,identity,bookmark) VALUES(?,?,?,?,?,?,?,?)",[.text(value.id),.text(value.name),.text(value.path),.text(value.kind.rawValue),.text(value.availability.rawValue),.text(encodeExclusions(value.exclusions)),.text(identity.identity),bookmark(root)])
        return value
    }

    public func updateSource(_ source: SourceRecord) throws {
        let previous = try self.source(source.id)
        try database.execute("UPDATE sources SET name=?,exclusions=?,offline_content=?,ocr=? WHERE id=?",[.text(source.name),.text(encodeExclusions(source.exclusions)),.integer(source.allowsOfflineContent ? 1:0),.integer(source.ocrEnabled ? 1:0),.text(source.id)])
        if previous.exclusions != source.exclusions {
            var cursor: Int64 = 0
            while true {
                let batch = try database.rows("SELECT id,relative_path FROM files WHERE source_id=? AND id>? ORDER BY id LIMIT 500",[.text(source.id),.integer(cursor)])
                guard !batch.isEmpty else { break }
                try database.transaction {
                    for file in batch where LocalFiles.excluded(file.string("relative_path"),patterns:source.exclusions) {
                        try database.execute("DELETE FROM files WHERE id=?",[.integer(file.int("id"))])
                    }
                }
                cursor = batch.last!.int("id")
            }
            try cleanOrphans()
            try database.purgeDeletedText()
        }
    }

    public func removeSource(id: String) throws {
        try database.transaction {
            try database.execute("DELETE FROM sources WHERE id=?",[.text(id)])
            try cleanOrphans()
        }
        try database.purgeDeletedText()
    }

    public func setSourcePaused(id: String, paused: Bool) throws {
        try database.execute("UPDATE sources SET paused=? WHERE id=?",[.integer(paused ? 1:0),.text(id)])
        _ = try probe(try rawSource(id))
    }

    /// Saved identities survive disconnects and restarts; paused scopes never reconnect.
    public func networkReconnectURLs() throws -> [URL] {
        let rows = try database.rows("SELECT identity FROM sources WHERE kind='network' AND paused=0")
        return Array(Set(rows.compactMap { row -> URL? in
            guard LocalFiles.networkRemounts(identity: row.string("identity")).isEmpty else { return nil }
            return RememberedNetworkShare.reconnectURL(identity: row.string("identity"))
        })).sorted { $0.absoluteString < $1.absoluteString }
    }

    public func refreshAvailability() async throws {
        let registration = SourceRegistration(timeout: .seconds(3)) { url in
            let identity = try FolderIdentity.read(url)
            guard access(url.path, R_OK | X_OK) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return RegisteredSource(root: url, identity: identity)
        }
        for row in try database.rows("SELECT * FROM sources") where !activeScans.contains(row.string("id")) {
            guard row.string("kind") == "network" else { _ = try probe(row); continue }
            let id = row.string("id")
            let candidates = LocalFiles.networkRemounts(identity: row.string("identity"))
            var available: URL?
            var denied = false
            for url in candidates {
                do {
                    let inspected = try await registration.inspect(url)
                    if inspected.identity.identity == row.string("identity") { available = url; break }
                } catch is CancellationError { throw CancellationError() }
                catch { denied = denied || LocalFiles.permissionError(error) }
            }
            // The actor was released during the bounded filesystem probe.
            guard !activeScans.contains(id),
                  let current = try database.rows("SELECT * FROM sources WHERE id=?", [.text(id)]).first,
                  current.string("identity") == row.string("identity") else { continue }
            if let available {
                try database.execute("UPDATE sources SET path=?,availability=?,last_error=NULL WHERE id=?", [.text(available.path), .text(current.int("paused") == 1 ? "paused" : "online"), .text(id)])
            } else {
                if denied { try revokeSource(id) }
                try database.execute("UPDATE sources SET availability=? WHERE id=?", [.text(current.int("paused") == 1 ? "paused" : "offline"), .text(id)])
            }
        }
    }

    public func statistics() throws -> IndexStatistics {
        let count = try database.rows("SELECT (SELECT COUNT(*) FROM files) AS files,(SELECT COUNT(*) FROM passages) AS passages,(SELECT COUNT(*) FROM vectors WHERE model=?) AS vectors",[.text(encoder.modelID)]).first!
        var bytes: Int64 = 0
        for path in [databaseURL.path,databaseURL.path+"-wal",databaseURL.path+"-shm"] { bytes += ((try? FileManager.default.attributesOfItem(atPath:path)[.size]) as? NSNumber)?.int64Value ?? 0 }
        return IndexStatistics(files:Int(count.int("files")),passages:Int(count.int("passages")),vectors:Int(count.int("vectors")),databaseBytes:bytes,semanticAvailable:encoder.isAvailable,modelDescription:encoder.isAvailable ? "Apple sentence embeddings · English · entirely on this Mac" : "English sentence model unavailable; exact search works")
    }

    func source(_ id: String) throws -> SourceRecord {
        let row = try rawSource(id)
        return SourceRecord(id:row.string("id"),name:row.string("name"),path:row.string("path"),kind:SourceKind(rawValue:row.string("kind")) ?? .local,availability:SourceAvailability(rawValue:row.string("availability")) ?? .offline,lastScan:row.date("last_scan"),lastError:row.optionalString("last_error"),exclusions:decodeExclusions(row.string("exclusions")),allowsOfflineContent:row.int("offline_content") != 0,ocrEnabled:row.int("ocr") != 0)
    }

    func rawSource(_ id: String) throws -> SQLRow {
        guard let value = try database.rows("SELECT * FROM sources WHERE id=?",[.text(id)]).first else { throw DatabaseError(message:"This source has been removed.") }
        return value
    }

    // This app is not sandboxed. Optional Foundation bookmarks can hang in FileProvider getxattr;
    // selected paths and verified filesystem identities are the authoritative source handles.
    func bookmark(_ url: URL) -> SQLValue { .null }
    func decodeExclusions(_ value: String) -> [String] { (try? JSONDecoder().decode([String].self,from:Data(value.utf8))) ?? [] }
    func encodeExclusions(_ value: [String]) -> String { String(data:(try? JSONEncoder().encode(value)) ?? Data("[]".utf8),encoding:.utf8) ?? "[]" }

    /// An existing mountpoint is insufficient: verify its volume/share identity before reconciling.
    func probe(_ row: SQLRow) throws -> URL? {
        var candidates = [URL(fileURLWithPath:row.string("path"),isDirectory:true)]
        if row.string("kind") == "network" {
            // Never touch a stale mountpoint or an unrelated local replacement.
            candidates = LocalFiles.networkRemounts(identity:row.string("identity"))
        }
        for url in candidates {
            do {
                let identity = try FolderIdentity.read(url)
                guard identity.identity == row.string("identity") else { continue }
                guard access(url.path,R_OK | X_OK) == 0 else {
                    if errno == EACCES || errno == EPERM { try revokeSource(row.string("id")) }
                    continue
                }
                try database.execute("UPDATE sources SET path=?,availability=?,last_error=NULL WHERE id=?",[.text(url.path),.text(row.int("paused") == 1 ? "paused":"online"),.text(row.string("id"))])
                return url
            } catch {
                if LocalFiles.permissionError(error) { try revokeSource(row.string("id")) }
            }
        }
        try database.execute("UPDATE sources SET availability='offline' WHERE id=?",[.text(row.string("id"))])
        return nil
    }

    func revokeSource(_ id: String) throws {
        try database.transaction {
            try database.execute("UPDATE files SET content_id=NULL,fingerprint=NULL,status='denied',detail='Access revoked; cached content removed.' WHERE source_id=?",[.text(id)])
            try database.execute("DELETE FROM jobs WHERE file_id IN (SELECT id FROM files WHERE source_id=?)",[.text(id)])
            try database.execute("UPDATE sources SET last_error='Access denied. Cached content has been removed.' WHERE id=?",[.text(id)])
            try cleanOrphans()
        }
        try database.purgeDeletedText()
    }

    func cleanOrphans() throws { try database.execute("DELETE FROM contents WHERE NOT EXISTS(SELECT 1 FROM files WHERE files.content_id=contents.id)") }
}
