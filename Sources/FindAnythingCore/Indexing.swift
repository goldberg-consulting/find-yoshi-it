import Foundation

extension SearchEngine {
    @discardableResult
    public func scan(sourceID: String, verifyAll: Bool = false, scopes requestedScopes: [String]? = nil, progress: @escaping @Sendable (IndexProgress) async -> Void = { _ in }) async throws -> Bool {
        guard !activeScans.contains(sourceID) else { return false }
        let row = try rawSource(sourceID)
        guard row.int("paused") == 0 else { return false }
        guard let root = try probe(row) else { throw DatabaseError(message:"The source is offline or inaccessible. Its existing index has been retained.") }
        activeScans.insert(sourceID)
        defer {
            activeScans.remove(sourceID)
            pendingScanScopes.removeValue(forKey: sourceID)
            priorityScanScopes.removeValue(forKey: sourceID)
        }
        // Interrupted scoped scans restart as a full reconciliation; full scans retain their durable frontier.
        let interruptedScopedScan = row.optionalString("scan_scopes") != nil
        var scopes = ChangeJournal.minimalScopes((verifyAll || interruptedScopedScan || row.optionalString("scan_generation") != nil) ? [""] : (requestedScopes ?? [""]))
        if scopes != [""] {
            scopes = ChangeJournal.minimalScopes(scopes.map { scope in
                var candidate = scope
                while !candidate.isEmpty {
                    var directory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path, isDirectory: &directory), directory.boolValue { break }
                    candidate = (candidate as NSString).deletingLastPathComponent
                }
                return candidate
            })
        }
        let generation = (verifyAll || interruptedScopedScan || requestedScopes != nil ? nil:row.optionalString("scan_generation")) ?? UUID().uuidString
        let continuing = row.optionalString("scan_generation") == generation
        var discovered = continuing ? Int(try database.rows("SELECT COUNT(*) AS count FROM files WHERE source_id=? AND generation=?",[.text(sourceID),.text(generation)]).first?.int("count") ?? 0):0
        var processed = 0
        var complete = !continuing || row.int("scan_incomplete") == 0
        var scanError: String?
        try database.execute("UPDATE sources SET availability='scanning',last_error=NULL WHERE id=?",[.text(sourceID)])
        if !continuing {
            try database.transaction {
                try database.execute("DELETE FROM scan_directories WHERE source_id=?",[.text(sourceID)])
                for scope in scopes {
                    try database.execute("INSERT INTO scan_directories(source_id,relative_path) VALUES(?,?)", [.text(sourceID), .text(scope)])
                }
                try database.execute("UPDATE sources SET scan_scopes=? WHERE id=?", [scopes == [""] ? .null : .text("scoped"), .text(sourceID)])
                try database.execute("UPDATE sources SET scan_generation=?,scan_incomplete=0 WHERE id=?",[.text(generation),.text(sourceID)])
            }
        }
        do {
            // Persist the frontier, keeping memory bounded to one directory plus small work batches.
            while let directory = try nextScanDirectory(sourceID) {
                try checkScan(sourceID)
                let relative = directory.string("relative_path")
                let folder = relative.isEmpty ? root : root.appendingPathComponent(relative,isDirectory:true)
                let exclusions = try source(sourceID).exclusions
                do {
                    let entries = try await fileIO { try LocalFiles.list(folder) }
                    for start in stride(from:0,to:entries.count,by:200) {
                        try checkScan(sourceID)
                        try database.transaction {
                            for entry in entries[start..<min(start+200,entries.count)] {
                                let path = relative.isEmpty ? entry.url.lastPathComponent : relative+"/"+entry.url.lastPathComponent
                                guard !entry.isSymlink, !LocalFiles.excluded(path,patterns:exclusions) else { continue }
                                // Never index the app's own database, WAL or caches when its parent is selected.
                                let indexRoot = databaseURL.deletingLastPathComponent().standardizedFileURL.path
                                if entry.url.path == indexRoot || entry.url.path.hasPrefix(indexRoot+"/") { continue }
                                if entry.isDirectory {
                                    guard ![".app", ".framework", ".bundle", ".xpc", ".appex"].contains("." + entry.url.pathExtension.lowercased()),
                                          !["/.nofollow", "/.resolve", "/.vol"].contains(entry.url.path) else { continue }
                                    try database.execute("INSERT OR IGNORE INTO scan_directories(source_id,relative_path) VALUES(?,?)",[.text(sourceID),.text(path)])
                                } else if entry.isRegular {
                                    do { try observe(entry.url,relative:path,sourceID:sourceID,generation:generation,verifyAll:verifyAll); discovered += 1 }
                                    catch {
                                        complete = false; scanError = error.localizedDescription
                                        try database.execute("UPDATE sources SET scan_incomplete=1 WHERE id=?",[.text(sourceID)])
                                    }
                                }
                            }
                        }
                        await progress(IndexProgress(sourceID:sourceID,phase:"Discovering files",discovered:discovered,processed:processed,currentPath:relative))
                        await Task.yield()
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    complete = false
                    try database.execute("UPDATE sources SET scan_incomplete=1 WHERE id=?",[.text(sourceID)])
                    scanError = "Could not enumerate \(relative.isEmpty ? root.lastPathComponent:relative): \(error.localizedDescription)"
                    if LocalFiles.permissionError(error) {
                        if relative.isEmpty { try revokeSource(sourceID) }
                        else { try revokeScope(sourceID,relative:relative) }
                    }
                }
                try database.execute("UPDATE scan_directories SET done=1 WHERE source_id=? AND relative_path=?",[.text(sourceID),.text(relative)])
                // Publish useful content and vectors during discovery, not after the entire tree finishes.
                processed += try await drainTextJobs(root: root, sourceID: sourceID, generation: generation, verifyAll: verifyAll, maximum: 12, preferredScope: relative)

            }
            try checkScan(sourceID)
            // A failed or partial enumeration cannot turn into deletion, even when a mount remains present.
            if complete {
                guard let _ = try probe(try rawSource(sourceID)) else { throw DatabaseError(message:"Source disconnected during reconciliation. Nothing was deleted.") }
                try database.transaction {
                    for scope in scopes {
                        try database.execute("DELETE FROM files WHERE source_id=? AND generation<>? AND (?='' OR relative_path=? OR substr(relative_path,1,length(?))=?)", [.text(sourceID), .text(generation), .text(scope), .text(scope), .text(scope + "/"), .text(scope + "/")])
                    }
                    try cleanOrphans()
                }
                try database.execute("UPDATE sources SET availability='scanning' WHERE id=?",[.text(sourceID)])
            }
            // Metadata is searchable before any document extraction starts. OCR is its own lower-priority pass.
            for phase in ["text","ocr"] {
                if phase == "ocr", !(try source(sourceID).ocrEnabled) { continue }
                while let job = try database.rows("""
                    SELECT f.*,j.phase,j.attempts FROM jobs j JOIN files f ON f.id=j.file_id
                    WHERE f.source_id=? AND j.phase=? AND j.retry_at<=? AND f.generation=? ORDER BY f.id LIMIT 1
                    """,[.text(sourceID),.text(phase),.real(Date().timeIntervalSince1970),.text(generation)]).first {
                    try checkScan(sourceID)
                    await progress(IndexProgress(sourceID:sourceID,phase:phase == "ocr" ? "Recognizing scanned text":"Indexing documents",discovered:discovered,processed:processed,currentPath:job.string("relative_path")))
                    do { try await process(job,root:root,sourceID:sourceID,ocr:phase == "ocr",verifyAll:verifyAll) }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        if LocalFiles.permissionError(error) { try revokeFile(job.int("id")) }
                        else {
                            let delay = min(86400.0,30 * pow(2,Double(min(12,job.int("attempts")))))
                            try database.execute("UPDATE files SET status='failed',detail=? WHERE id=?",[.text(error.localizedDescription),.integer(job.int("id"))])
                            try database.execute("UPDATE jobs SET attempts=attempts+1,retry_at=? WHERE file_id=?",[.real(Date().timeIntervalSince1970+delay),.integer(job.int("id"))])
                        }
                    }
                    processed += 1
                    await Task.yield()
                }
            }
            // Backfill changed local model versions in bounded batches; current citations always own vectors.
            try await backfillVectors(sourceID:sourceID,progress:progress,discovered:discovered,processed:processed)
            let fresh = try rawSource(sourceID)
            if complete {
                try database.execute("UPDATE sources SET availability=?,last_scan=?,last_error=NULL WHERE id=?",[.text(fresh.int("paused") == 1 ? "paused":"online"),.real(Date().timeIntervalSince1970),.text(sourceID)])
            } else {
                try database.execute("UPDATE sources SET availability='error',last_error=? WHERE id=?",[.text(scanError ?? "The scan was incomplete; missing files were retained."),.text(sourceID)])
            }
            try database.execute("UPDATE sources SET scan_generation=NULL,scan_scopes=NULL,scan_incomplete=0 WHERE id=?",[.text(sourceID)])
            try database.execute("DELETE FROM scan_directories WHERE source_id=?",[.text(sourceID)])
            await progress(IndexProgress(sourceID:sourceID,phase:complete ? "Up to date":"Scan incomplete",discovered:discovered,processed:processed))
        } catch {
            if let row = try? rawSource(sourceID) {
                if error is CancellationError {
                    try? database.execute("UPDATE sources SET availability='paused',paused=1 WHERE id=?",[.text(sourceID)])
                } else if row.string("availability") != "offline" {
                    try? database.execute("UPDATE sources SET availability='error',last_error=? WHERE id=?",[.text(error.localizedDescription),.text(sourceID)])
                }
            }
            throw error
        }
        return true
    }

    /// Move changed subtrees ahead of an active full scan, including folders it
    /// already visited. The durable change journal remains authoritative until
    /// a completed reconciliation acknowledges its batch.
    public func prioritizeScanScopes(sourceID: String, scopes: [String]) throws {
        guard activeScans.contains(sourceID), try rawSource(sourceID).optionalString("scan_scopes") == nil else { return }
        pendingScanScopes[sourceID] = ChangeJournal.minimalScopes((pendingScanScopes[sourceID] ?? []) + scopes)
    }

    private func nextScanDirectory(_ sourceID: String) throws -> SQLRow? {
        if let changed = pendingScanScopes.removeValue(forKey: sourceID) {
            try database.transaction {
                for scope in changed {
                    try database.execute("UPDATE scan_directories SET done=0 WHERE source_id=? AND (?='' OR relative_path=? OR substr(relative_path,1,length(?))=?)", [.text(sourceID), .text(scope), .text(scope), .text(scope + "/"), .text(scope + "/")])
                    try database.execute("INSERT OR IGNORE INTO scan_directories(source_id,relative_path) VALUES(?,?)", [.text(sourceID), .text(scope)])
                }
            }
            priorityScanScopes[sourceID] = ChangeJournal.minimalScopes((priorityScanScopes[sourceID] ?? []) + changed)
        }
        while let scope = priorityScanScopes[sourceID]?.first {
            if let next = try database.rows("SELECT relative_path FROM scan_directories WHERE source_id=? AND done=0 AND (?='' OR relative_path=? OR substr(relative_path,1,length(?))=?) ORDER BY length(relative_path),relative_path LIMIT 1", [.text(sourceID), .text(scope), .text(scope), .text(scope + "/"), .text(scope + "/")]).first { return next }
            priorityScanScopes[sourceID]?.removeFirst()
        }
        return try database.rows("SELECT relative_path FROM scan_directories WHERE source_id=? AND done=0 ORDER BY CASE WHEN relative_path='Documents' OR relative_path LIKE 'Documents/%' THEN 0 WHEN relative_path='Desktop' OR relative_path LIKE 'Desktop/%' THEN 1 ELSE 2 END,length(relative_path),relative_path LIMIT 1", [.text(sourceID)]).first
    }

    private func drainTextJobs(root: URL, sourceID: String, generation: String, verifyAll: Bool, maximum: Int, preferredScope: String) async throws -> Int {
        var processed = 0
        while processed < maximum, let job = try database.rows("SELECT f.*,j.phase,j.attempts FROM jobs j JOIN files f ON f.id=j.file_id WHERE f.source_id=? AND j.phase='text' AND j.retry_at<=? AND f.generation=? ORDER BY CASE WHEN ?='' OR substr(f.relative_path,1,length(?))=? THEN 0 ELSE 1 END,f.id LIMIT 1", [.text(sourceID), .real(Date().timeIntervalSince1970), .text(generation), .text(preferredScope), .text(preferredScope + "/"), .text(preferredScope + "/")]).first {
            try checkScan(sourceID)
            do { try await process(job, root: root, sourceID: sourceID, ocr: false, verifyAll: verifyAll) }
            catch is CancellationError { throw CancellationError() }
            catch {
                if LocalFiles.permissionError(error) { try revokeFile(job.int("id")) }
                else {
                    let delay = min(86400.0, 30 * pow(2, Double(min(12, job.int("attempts")))))
                    try database.execute("UPDATE files SET status='failed',detail=? WHERE id=?", [.text(error.localizedDescription), .integer(job.int("id"))])
                    try database.execute("UPDATE jobs SET attempts=attempts+1,retry_at=? WHERE file_id=?", [.real(Date().timeIntervalSince1970 + delay), .integer(job.int("id"))])
                }
            }
            processed += 1
            await Task.yield()
        }
        return processed
    }

    func checkScan(_ id: String) throws {
        try Task.checkCancellation()
        if try rawSource(id).int("paused") == 1 { throw CancellationError() }
    }

    private func observe(_ url: URL, relative: String, sourceID: String, generation: String, verifyAll: Bool) throws {
        let stamp = try FileStamp.read(url)
        let existing = try database.rows("SELECT f.*,c.extractor FROM files f LEFT JOIN contents c ON c.id=f.content_id WHERE f.source_id=? AND f.relative_path=?",[.text(sourceID),.text(relative)]).first
        let changed = existing == nil || existing!.int("size") != stamp.size || abs(existing!.double("mtime")-stamp.modified.timeIntervalSince1970) > 0.000001 || abs(existing!.double("ctime")-stamp.changed.timeIntervalSince1970) > 0.000001
        let ext = url.pathExtension.lowercased()
        let supported = !SearchPresentation.isDependencyPath(url.path) && (DocumentExtractor.supportedExtensions.contains(ext) || ["readme","license","makefile","dockerfile","gemfile",".gitignore"].contains(url.lastPathComponent.lowercased()))
        let status = supported ? "queued":"unsupported"
        try database.execute("""
            INSERT INTO files(source_id,relative_path,name,ext,size,mtime,generation,status,detail) VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(source_id,relative_path) DO UPDATE SET size=excluded.size,mtime=excluded.mtime,generation=excluded.generation
            """,[.text(sourceID),.text(relative),.text(url.lastPathComponent),.text(ext),.integer(stamp.size),.real(stamp.modified.timeIntervalSince1970),.text(generation),.text(status),supported ? .null:.text("Content unsupported; filename and metadata are searchable.")])
        let fileID = existing?.int("id") ?? database.lastID
        try database.execute("UPDATE files SET ctime=? WHERE id=?", [.real(stamp.changed.timeIntervalSince1970), .integer(fileID)])
        let needsRetry = ["failed","denied","queued"].contains(existing?.string("status") ?? "")
        let versionChanged = existing?.optionalString("extractor").map { !$0.hasPrefix(DocumentExtractor.version+":"+ext+":") } ?? false
        if supported && (changed || verifyAll || needsRetry || versionChanged) {
            if changed || verifyAll { try database.execute("UPDATE files SET status='queued',detail=NULL WHERE id=?",[.integer(fileID)]) }
            try database.execute("INSERT INTO jobs(file_id,phase) VALUES(?,'text') ON CONFLICT(file_id) DO UPDATE SET phase=CASE WHEN ?=1 THEN 'text' ELSE jobs.phase END,retry_at=CASE WHEN ?=1 THEN 0 ELSE jobs.retry_at END",[.integer(fileID),.integer(changed || verifyAll ? 1:0),.integer(changed || verifyAll ? 1:0)])
        } else if existing?.string("status") == "needsOCR" {
            try database.execute("INSERT OR IGNORE INTO jobs(file_id,phase) VALUES(?,'ocr')",[.integer(fileID)])
        }
    }

    private func process(_ file: SQLRow, root: URL, sourceID: String, ocr: Bool, verifyAll: Bool) async throws {
        let fileID = file.int("id")
        let relative = file.string("relative_path")
        guard !LocalFiles.excluded(relative,patterns:try source(sourceID).exclusions) else {
            try database.execute("DELETE FROM files WHERE id=?",[.integer(fileID)]); return
        }
        let original = root.appendingPathComponent(relative)
        let snapshot = try await fileIO { try LocalFiles.snapshot(original,root:root) }
        defer { try? FileManager.default.removeItem(at:snapshot.url.deletingLastPathComponent()) }
        try checkScan(sourceID)
        // Preserve an already OCR-enriched version when a full byte verification finds no changes.
        let extractionFamily = DocumentExtractor.version+":"+original.pathExtension.lowercased()+":"
        if !ocr, snapshot.hash == file.optionalString("fingerprint"), let oldContent = file.optionalInt("content_id"), let old = try database.rows("SELECT * FROM contents WHERE id=?",[.integer(Int64(oldContent))]).first, old.string("extractor").hasPrefix(extractionFamily) {
            try database.execute("UPDATE files SET status=?,detail=?,mtime=?,indexed_mtime=? WHERE id=?",[.text(old.string("status")),old.optionalString("detail").map(SQLValue.text) ?? .null,.real(snapshot.stamp.modified.timeIntervalSince1970),.real(snapshot.stamp.modified.timeIntervalSince1970),.integer(fileID)])
            if old.string("status") == "needsOCR" { try database.execute("UPDATE jobs SET phase='ocr',attempts=0,retry_at=0 WHERE file_id=?",[.integer(fileID)]) }
            else { try database.execute("DELETE FROM jobs WHERE file_id=?",[.integer(fileID)]) }
            return
        }
        let extractor = extractionFamily+(ocr ? "ocr":"text")
        let cached = try database.rows("SELECT * FROM contents WHERE fingerprint=? AND extractor=?",[.text(snapshot.hash),.text(extractor)]).first
        let result: ExtractionResult
        if let cached { result = ExtractionResult(passages:[],status:ContentStatus(rawValue:cached.string("status")) ?? .failed,detail:cached.optionalString("detail")) }
        else { result = try await fileIO { try DocumentExtractor().extract(url:snapshot.url,performOCR:ocr) } }
        try checkScan(sourceID)
        // Source settings may change while extraction runs; never resurrect excluded or removed content.
        guard !LocalFiles.excluded(relative,patterns:try source(sourceID).exclusions), try !database.rows("SELECT id FROM files WHERE id=?",[.integer(fileID)]).isEmpty else { return }
        guard snapshot.stamp == (try await fileIO { try FileStamp.read(original) }) else { throw DatabaseError(message:"File changed during extraction; the existing indexed version was retained.") }
        if result.status == .failed || result.status == .locked {
            try database.execute("UPDATE files SET status=?,detail=? WHERE id=?",[.text(result.status.rawValue),result.detail.map(SQLValue.text) ?? .null,.integer(fileID)])
            try database.execute("DELETE FROM jobs WHERE file_id=?",[.integer(fileID)])
            return
        }
        try database.transaction {
            let contentID: Int64
            if let current = try database.rows("SELECT id FROM contents WHERE fingerprint=? AND extractor=?", [.text(snapshot.hash), .text(extractor)]).first {
                contentID = current.int("id")
            } else if cached != nil {
                // The cached version disappeared during the final file stamp read.
                // Retry extraction instead of publishing an empty set of passages.
                throw DatabaseError(message: "Cached content changed during indexing; retrying.")
            } else {
                try database.execute("INSERT INTO contents(fingerprint,extractor,status,detail) VALUES(?,?,?,?)",[.text(snapshot.hash),.text(extractor),.text(result.status.rawValue),result.detail.map(SQLValue.text) ?? .null])
                contentID = database.lastID
                for (ordinal,passage) in result.passages.enumerated() {
                    try database.execute("INSERT INTO passages(content_id,ordinal,text,location,page,line,sheet,cell) VALUES(?,?,?,?,?,?,?,?)",[.integer(contentID),.integer(Int64(ordinal)),.text(passage.text),.text(passage.location),passage.page.map { .integer(Int64($0)) } ?? .null,passage.line.map { .integer(Int64($0)) } ?? .null,passage.sheet.map(SQLValue.text) ?? .null,passage.cell.map(SQLValue.text) ?? .null])
                }
            }
            try database.execute("UPDATE files SET content_id=?,fingerprint=?,status=?,detail=?,indexed_at=?,indexed_mtime=?,mtime=?,size=? WHERE id=?",[.integer(contentID),.text(snapshot.hash),.text(result.status.rawValue),result.detail.map(SQLValue.text) ?? .null,.real(Date().timeIntervalSince1970),.real(snapshot.stamp.modified.timeIntervalSince1970),.real(snapshot.stamp.modified.timeIntervalSince1970),.integer(snapshot.stamp.size),.integer(fileID)])
            if result.status == .needsOCR && !ocr { try database.execute("UPDATE jobs SET phase='ocr',attempts=0,retry_at=0 WHERE file_id=?",[.integer(fileID)]) }
            else { try database.execute("DELETE FROM jobs WHERE file_id=?",[.integer(fileID)]) }
            if let previousID = file.optionalInt("content_id"), Int64(previousID) != contentID {
                try database.execute("DELETE FROM contents WHERE id=? AND NOT EXISTS(SELECT 1 FROM files WHERE content_id=?)",[.integer(Int64(previousID)),.integer(Int64(previousID))])
            }
        }
        if let contentID = try database.rows("SELECT content_id FROM files WHERE id=?", [.integer(fileID)]).first?.optionalInt("content_id") {
            try await backfillVectors(sourceID: sourceID, progress: { _ in }, discovered: 0, processed: 0, contentID: Int64(contentID))
        }
    }

    private func backfillVectors(sourceID: String, progress: @escaping @Sendable (IndexProgress) async -> Void, discovered: Int, processed: Int, contentID: Int64? = nil) async throws {
        guard encoder.isAvailable else { return }
        var cursor: Int64 = 0
        var count = 0
        while true {
            try checkScan(sourceID)
            let batch = try database.rows("""
                SELECT p.id,p.text FROM passages p WHERE p.id>? AND (? IS NULL OR p.content_id=?) AND EXISTS(SELECT 1 FROM files f WHERE f.content_id=p.content_id AND f.source_id=? AND f.status<>'denied')
                AND NOT EXISTS(SELECT 1 FROM vectors v WHERE v.passage_id=p.id AND v.model=?) ORDER BY p.id LIMIT 32
                """,[.integer(cursor), contentID.map(SQLValue.integer) ?? .null, contentID.map(SQLValue.integer) ?? .null, .text(sourceID),.text(encoder.modelID)])
            guard !batch.isEmpty else { break }
            let inputs = batch.map { EmbeddingInput(id: $0.int("id"), text: $0.string("text")) }
            let encoded = try await EmbeddingWorkers.shared.encode(inputs)
            try checkScan(sourceID)
            // Content can be removed or access revoked while workers run. Validate
            // ownership again inside the writer actor before attaching any vectors.
            try database.transaction {
                for passage in encoded where passage.modelID == encoder.modelID {
                    guard try !database.rows("""
                        SELECT p.id FROM passages p WHERE p.id=? AND EXISTS(
                            SELECT 1 FROM files f WHERE f.content_id=p.content_id
                            AND f.source_id=? AND f.status<>'denied')
                        """, [.integer(passage.id), .text(sourceID)]).isEmpty else { continue }
                    try database.execute("DELETE FROM vectors WHERE passage_id=?", [.integer(passage.id)])
                    try database.execute("INSERT INTO vectors(passage_id,model,vector) VALUES(?,?,?)", [.integer(passage.id), .text(passage.modelID), .blob(passage.data)])
                    // Search streams packed vectors directly; legacy LSH buckets
                    // are retained on disk for compatibility but no longer built.
                    count += 1
                }
            }
            cursor = batch.last!.int("id")
            await progress(IndexProgress(sourceID:sourceID,phase:"Indexing meaning · \(count) passages",discovered:discovered,processed:processed))
        }
    }

    func revokeFile(_ fileID: Int64) throws {
        try database.transaction {
            try database.execute("UPDATE files SET content_id=NULL,fingerprint=NULL,status='denied',detail='Access revoked; cached content removed.' WHERE id=?",[.integer(fileID)])
            try database.execute("DELETE FROM jobs WHERE file_id=?",[.integer(fileID)])
            try cleanOrphans()
        }
        try database.purgeDeletedText()
    }

    private func revokeScope(_ sourceID: String, relative: String) throws {
        try database.transaction {
            try database.execute("UPDATE files SET content_id=NULL,fingerprint=NULL,status='denied',detail='Access revoked; cached content removed.' WHERE source_id=? AND substr(relative_path,1,length(?))=?",[.text(sourceID),.text(relative+"/"),.text(relative+"/")])
            try database.execute("DELETE FROM jobs WHERE file_id IN (SELECT id FROM files WHERE source_id=? AND status='denied')",[.text(sourceID)])
            try cleanOrphans()
        }
        try database.purgeDeletedText()
    }

    private func fileIO<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached(priority:.utility) { try operation() }
        return try await withTaskCancellationHandler(operation:{ try await worker.value },onCancel:{ worker.cancel() })
    }
}
