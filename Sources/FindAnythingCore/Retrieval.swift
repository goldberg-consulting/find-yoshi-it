import Foundation
import Darwin

extension SearchEngine {
    private var resultColumns: String {
        "f.*,s.name AS source_name,s.path AS source_path,s.availability,s.offline_content"
    }
    private var joins: String { "files f JOIN sources s ON s.id=f.source_id" }

    public func search(_ request: SearchRequest) throws -> [SearchResult] {
        try Task.checkCancellation()
        return try database.withQueryBudget(seconds: request.namesOnly ? 2 : 15) { try retrieve(request) }
    }

    private func retrieve(_ request: SearchRequest) throws -> [SearchResult] {
        let query = String(request.query.trimmingCharacters(in:.whitespacesAndNewlines).prefix(512))
        let limit = max(1,min(100,request.limit))
        // Apply category precedence before channel candidate limits, so dependency/code hits cannot crowd out documents.
        if request.category == .all {
            var documents = request
            documents.category = .documents
            documents.limit = limit
            let first = try retrieve(documents)
            guard first.count < limit else { return first }
            var other = request
            other.category = .other
            other.limit = limit - first.count
            return first + (try retrieve(other))
        }
        let (filters,args) = filter(request)
        if query.isEmpty {
            return try database.rows("SELECT \(resultColumns) FROM \(joins) WHERE \(filters) ORDER BY f.mtime DESC LIMIT ?",args+[.integer(Int64(limit))]).compactMap { try makeResult($0,includePreview:true) }
        }
        var matches: [Int64:SearchResult] = [:]
        var channelScores: [Int64:[String:Double]] = [:]
        func merge(_ value: SearchResult, score: Double, kind: String) {
            var value = value
            value.nameMatched = kind == "Filename match"
            let previousContribution = channelScores[value.fileID]?[kind] ?? 0
            let contribution = max(previousContribution,score)
            channelScores[value.fileID,default:[:]][kind] = contribution
            value.score = contribution
            value.matchKind = kind
            if var old = matches[value.fileID] {
                // Repeated passages in a long file do not drown out a strong match in a short file.
                old.nameMatched = old.nameMatched || value.nameMatched
                old.score += contribution-previousContribution
                let preferMatchedPassage = kind == "Text match" || (kind == "Meaning match" && channelScores[value.fileID]?["Text match"] == nil)
                if preferMatchedPassage && score > previousContribution {
                    old.passages = Array((value.passages + old.passages.filter { oldPassage in !value.passages.contains(where:{$0.id == oldPassage.id}) }).prefix(3))
                } else {
                    for passage in value.passages where !old.passages.contains(where:{$0.id == passage.id}) && old.passages.count < 3 { old.passages.append(passage) }
                }
                if old.matchKind != kind { old.matchKind = "Hybrid match" }
                matches[value.fileID] = old
            } else { matches[value.fileID] = value }
        }
        let contentRequest = request
        if request.mode != .semantic {
            let expression = lexicalExpression(query,phrase:request.mode == .exact)
            if !expression.isEmpty {
                let explicitPath = query.contains("/") || SearchPresentation.dependencyDirectories.contains { SearchPresentation.explicitlyRequests($0, query: query) }
                let nameTerms = lexicalExpression(query, phrase: request.mode == .exact, prefix: request.mode != .exact)
                let nameExpression = !explicitPath ? "name : (" + nameTerms + ")" : nameTerms
                let names = try database.rows("SELECT \(resultColumns) FROM file_fts JOIN files f ON f.id=file_fts.rowid JOIN sources s ON s.id=f.source_id WHERE file_fts MATCH ? AND \(filters) ORDER BY bm25(file_fts) LIMIT 180",[.text(nameExpression)]+args)
                for (rank,row) in names.enumerated() {
                    if let value = try makeResult(row,includePreview:!request.namesOnly) { merge(value,score:3.0/Double(60+rank),kind:"Filename match") }
                }
                // Literal substring paths and identifiers retain their punctuation, independent of FTS tokenization.
                let literal = unquoted(query).lowercased()
                let pathCondition = !explicitPath ? "0" : "instr(lower(f.relative_path),?)>0"
                let literalArguments: [SQLValue] = [.text(literal)] + (!explicitPath ? [] : [.text(literal)]) + [.text(literal)]
                let exactNames: [SQLRow]
                if !explicitPath {
                    if literal.count >= 3 {
                        let grams = "\"" + literal.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                        exactNames = try database.rows("SELECT \(resultColumns) FROM file_name_grams JOIN files f ON f.id=file_name_grams.rowid JOIN sources s ON s.id=f.source_id WHERE file_name_grams MATCH ? AND \(filters) ORDER BY CASE WHEN lower(f.name)=? THEN 0 ELSE 1 END,f.mtime DESC LIMIT 100", [.text(grams)] + args + [.text(literal)])
                    } else {
                        exactNames = try database.rows("SELECT \(resultColumns) FROM \(joins) WHERE lower(f.name)>=? AND lower(f.name)<? AND \(filters) ORDER BY lower(f.name) LIMIT 100", [.text(literal), .text(literal + "􏿿")] + args)
                    }
                } else {
                    exactNames = try database.rows("SELECT \(resultColumns) FROM \(joins) WHERE \(filters) AND (instr(lower(f.name),?)>0 OR \(pathCondition)) ORDER BY CASE WHEN lower(f.name)=? THEN 0 ELSE 1 END,f.mtime DESC LIMIT 100",args+literalArguments)
                }
                for (rank,row) in exactNames.enumerated() {
                    if let value = try makeResult(row,includePreview:!request.namesOnly) { merge(value,score:0.08+1.0/Double(60+rank),kind:"Filename match") }
                }
                if !request.namesOnly {
                let (contentFilters, contentArgs) = filter(contentRequest)
                let passages = try database.rows("""
                    WITH matched AS MATERIALIZED (
                        SELECT p.*,bm25(passage_fts) AS relevance
                        FROM passage_fts JOIN passages p ON p.id=passage_fts.rowid
                        WHERE passage_fts MATCH ? AND EXISTS(SELECT 1 FROM \(joins) WHERE f.content_id=p.content_id AND \(contentFilters) AND (s.availability<>'offline' OR s.offline_content=1))
                    ), representatives AS (
                        SELECT *,ROW_NUMBER() OVER(PARTITION BY content_id ORDER BY relevance,id) AS passage_rank FROM matched
                    )
                    SELECT \(resultColumns),p.id AS p_id,p.text AS p_text,p.location AS p_location,p.page AS p_page,p.line AS p_line,p.sheet AS p_sheet,p.cell AS p_cell
                    FROM representatives p JOIN files f ON f.content_id=p.content_id JOIN sources s ON s.id=f.source_id
                    WHERE p.passage_rank=1 AND \(contentFilters) AND (s.availability<>'offline' OR s.offline_content=1)
                    ORDER BY p.relevance,f.id LIMIT 360
                    """,[.text(expression)]+contentArgs+contentArgs)
                for (rank,row) in passages.enumerated() {
                    if let value = try makeResult(row,includePreview:false) { merge(value,score:1.8/Double(60+rank),kind:"Text match") }
                }
                }
            }
        }
        if !request.namesOnly && request.mode != .exact && request.mode != .names, let vector = encoder.encode(query) {
            for (rank,entry) in try semanticCandidates(vector,request:contentRequest).enumerated() {
                var value = entry.0
                value.score = entry.1
                merge(value,score:1.3/Double(60+rank),kind:"Meaning match")
            }
        }
        return Array(matches.values.sorted {
            let leftName = channelScores[$0.fileID]?["Filename match"] != nil
            let rightName = channelScores[$1.fileID]?["Filename match"] != nil
            if leftName != rightName { return leftName }
            if abs($0.score-$1.score) > 0.0000001 { return $0.score > $1.score }; return $0.fileID < $1.fileID }.prefix(limit))
    }

    public func preview(fileID: Int64, matchingPassageID: Int64? = nil) throws -> [Passage] {
        guard let row = try database.rows("SELECT \(resultColumns) FROM \(joins) WHERE f.id=? AND f.status<>'denied'",[.integer(fileID)]).first,
              let result = try makeResult(row,includePreview:false), result.availability != .offline || result.offlineContentAllowed else { return [] }
        var firstOrdinal: Int64 = 0
        if let matchingPassageID, let match = try database.rows("SELECT p.ordinal FROM passages p JOIN files f ON f.content_id=p.content_id WHERE f.id=? AND p.id=?",[.integer(fileID),.integer(matchingPassageID)]).first {
            firstOrdinal = max(0,match.int("ordinal")-30)
        }
        return try database.rows("SELECT p.* FROM passages p JOIN files f ON f.content_id=p.content_id WHERE f.id=? AND p.ordinal>=? ORDER BY p.ordinal LIMIT 300",[.integer(fileID),.integer(firstOrdinal)]).map(passage)
    }

    public func related(fileID: Int64) throws -> [SearchResult] {
        try database.withQueryBudget(seconds: 5) { try retrieveRelated(fileID: fileID) }
    }

    private func retrieveRelated(fileID: Int64) throws -> [SearchResult] {
        guard encoder.isAvailable,
              let row = try database.rows("SELECT \(resultColumns) FROM \(joins) WHERE f.id=? AND f.status<>'denied'",[.integer(fileID)]).first,
              let value = try makeResult(row,includePreview:false), value.availability != .offline || value.offlineContentAllowed,
              let vectorRow = try database.rows("SELECT v.vector FROM vectors v JOIN passages p ON p.id=v.passage_id JOIN files f ON f.content_id=p.content_id WHERE f.id=? AND v.model=? ORDER BY p.ordinal LIMIT 1",[.integer(fileID),.text(encoder.modelID)]).first,
              let blob = vectorRow.data("vector") else { return [] }
        var seen = Set<Int64>()
        return try semanticCandidates(SemanticEncoder.unpack(blob),request:SearchRequest(query:"",limit:6)).compactMap { entry in
            guard entry.0.fileID != fileID, seen.insert(entry.0.fileID).inserted else { return nil }
            var result = entry.0; result.matchKind = "Related by meaning"; result.score = entry.1; return result
        }.prefix(6).map { $0 }
    }

    private func semanticCandidates(_ vector: [Float], request: SearchRequest) throws -> [(SearchResult,Double)] {
        let (filters,args) = filter(request)
        let ranked = try database.exactVectorCandidates("""
            SELECT v.passage_id,p.content_id,v.vector
            FROM (SELECT DISTINCT f.content_id FROM \(joins) WHERE f.content_id IS NOT NULL AND \(filters) AND (s.availability<>'offline' OR s.offline_content=1)) eligible
            JOIN passages p ON p.content_id=eligible.content_id
            JOIN vectors v ON v.passage_id=p.id WHERE v.model=?
            """, args + [.text(encoder.modelID)], query: vector, limit: 180)
        var output: [(SearchResult,Double)] = []
        for (id,cosine) in ranked {
            let rows = try database.rows("""
                SELECT \(resultColumns),p.id AS p_id,p.text AS p_text,p.location AS p_location,p.page AS p_page,p.line AS p_line,p.sheet AS p_sheet,p.cell AS p_cell
                FROM passages p JOIN files f ON f.content_id=p.content_id JOIN sources s ON s.id=f.source_id WHERE p.id=? AND \(filters) AND (s.availability<>'offline' OR s.offline_content=1) LIMIT 50
                """,[.integer(id)]+args)
            for row in rows { if let result = try makeResult(row,includePreview:false) { output.append((result,cosine)) } }
        }
        return output.sorted { $0.1 > $1.1 }
    }

    private func filter(_ request: SearchRequest) -> (String,[SQLValue]) {
        var clauses = ["f.status<>'denied'"]
        var arguments: [SQLValue] = []
        let extensions = SearchPresentation.documentExtensions.sorted()
        let placeholders = extensions.map { _ in "?" }.joined(separator: ",")
        if request.category != .all {
            clauses.append("lower(f.ext) \(request.category == .documents ? "IN" : "NOT IN") (\(placeholders))")
            arguments += extensions.map(SQLValue.text)
        }
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let exactFilename = unquoted(query)
        for component in SearchPresentation.dependencyDirectories where !SearchPresentation.explicitlyRequests(component, query: query) {
            clauses.append("(instr('/' || lower(s.path || '/' || f.relative_path) || '/', ?)=0 OR lower(f.name)=?)")
            arguments += [.text("/" + component + "/"), .text(exactFilename)]
        }
        if !SearchPresentation.explicitlyRequests(".node", query: query) {
            clauses.append("(lower(f.ext)<>'node' OR lower(f.name)=?)")
            arguments.append(.text(exactFilename))
        }
        for prefix in ["/.nofollow/", "/.resolve/", "/System/", "/Library/", "/Applications/"] where !query.contains(prefix.lowercased()) {
            clauses.append("(substr(replace(s.path || '/' || f.relative_path,'//','/'),1,length(?))<>? OR lower(f.name)=?)")
            arguments += [.text(prefix), .text(prefix), .text(exactFilename)]
        }
        if let ids = request.candidateFileIDs {
            clauses.append(ids.isEmpty ? "0" : "f.id IN (" + ids.map { _ in "?" }.joined(separator: ",") + ")")
            arguments += ids.map(SQLValue.integer)
        }
        if let id = request.sourceID { clauses.append("f.source_id=?"); arguments.append(.text(id)) }
        if let ext = request.fileExtension, !ext.isEmpty { clauses.append("f.ext=?"); arguments.append(.text(ext.lowercased())) }
        if let after = request.modifiedAfter { clauses.append("f.mtime>=?"); arguments.append(.real(after.timeIntervalSince1970)) }
        return (clauses.joined(separator:" AND "),arguments)
    }

    func lexicalExpression(_ value: String, phrase: Bool, prefix: Bool = false) -> String {
        let phrase = phrase || (value.count >= 2 && value.first == "\"" && value.last == "\"")
        let value = unquoted(value)
        guard value.contains(where:{$0.isLetter || $0.isNumber}) else { return "" }
        if phrase { return "\""+value.replacingOccurrences(of:"\"",with:"\"\"")+"\"" }
        // Quoted phrases stay together; user input is data, never executable FTS syntax.
        let regex = try! NSRegularExpression(pattern:"\"([^\"]+)\"|([^\\s]+)")
        let ns = value as NSString
        return regex.matches(in:value,range:NSRange(location:0,length:ns.length)).prefix(24).compactMap { match -> String? in
            let token = ns.substring(with:match.range(at:match.range(at:1).location == NSNotFound ? 2:1))
            guard token.contains(where:{$0.isLetter || $0.isNumber}) else { return nil }
            return "\""+token.replacingOccurrences(of:"\"",with:"\"\"")+"\"" + (prefix ? "*" : "")
        }.joined(separator:" OR ")
    }

    private func unquoted(_ value: String) -> String {
        if value.count >= 2, value.first == "\"", value.last == "\"" { return String(value.dropFirst().dropLast()) }
        return value
    }

    private func makeResult(_ row: SQLRow, includePreview: Bool) throws -> SearchResult? {
        let fileID = row.int("id")
        if let revokedAt = revokedFiles[fileID] {
            guard let indexedAt = row.date("indexed_at"), indexedAt > revokedAt else { return nil }
            revokedFiles.removeValue(forKey: fileID)
        }
        let path = URL(fileURLWithPath:row.string("source_path"),isDirectory:true).appendingPathComponent(row.string("relative_path")).path
        var availability = SourceAvailability(rawValue:row.string("availability")) ?? .offline
        var stale = row.date("indexed_mtime").map { abs($0.timeIntervalSince1970-row.double("mtime")) > 0.000001 } ?? false
        if availability != .offline {
            if URL(fileURLWithPath:path).resolvingSymlinksInPath().path != URL(fileURLWithPath:path).standardizedFileURL.path {
                if !database.readOnly { try revokeFile(fileID) } else { revokedFiles[fileID] = Date(); onAccessRevoked?(fileID) }; return nil
            }
            if access(path,R_OK) != 0 {
                if errno == EACCES || errno == EPERM { if !database.readOnly { try revokeFile(fileID) } else { revokedFiles[fileID] = Date(); onAccessRevoked?(fileID) }; return nil }
                stale = true
                availability = .offline
            }
        }
        let offlineAllowed = row.int("offline_content") != 0
        if availability == .offline && !offlineAllowed && row.optionalInt("p_id") != nil { return nil }
        var passages: [Passage] = []
        if availability != .offline || offlineAllowed {
            if row.optionalInt("p_id") != nil {
                passages = [Passage(id:row.int("p_id"),text:row.string("p_text"),location:row.string("p_location"),page:row.optionalInt("p_page"),line:row.optionalInt("p_line"),sheet:row.optionalString("p_sheet"),cell:row.optionalString("p_cell"))]
            } else if includePreview {
                passages = try database.rows("SELECT p.* FROM passages p JOIN files f ON f.content_id=p.content_id WHERE f.id=? ORDER BY p.ordinal LIMIT 1",[.integer(fileID)]).map(passage)
            }
        }
        return SearchResult(fileID:fileID,sourceID:row.string("source_id"),sourceName:row.string("source_name"),filename:row.string("name"),path:path,fileExtension:row.string("ext"),modifiedAt:Date(timeIntervalSince1970:row.double("mtime")),indexedAt:row.date("indexed_at"),availability:availability,status:ContentStatus(rawValue:row.string("status")) ?? .failed,detail:row.optionalString("detail"),passages:passages,offlineContentAllowed:offlineAllowed).withStale(stale)
    }

    private func passage(_ row: SQLRow) -> Passage {
        Passage(id:row.int("id"),text:row.string("text"),location:row.string("location"),page:row.optionalInt("page"),line:row.optionalInt("line"),sheet:row.optionalString("sheet"),cell:row.optionalString("cell"))
    }
}

private extension SearchResult {
    func withStale(_ stale: Bool) -> SearchResult { var value = self; value.isStale = stale; return value }
}
