import XCTest
import VectorMath
@testable import FindAnythingCore

final class SearchPerformanceTests: XCTestCase {
    func testQueryTimeoutIsTypedAndConnectionRecovers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try Database(url: root.appendingPathComponent("index.sqlite"))
        XCTAssertThrowsError(try database.withQueryBudget(seconds: -1) {
            try database.rows("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000) SELECT sum(x) FROM n")
        }) { XCTAssertEqual($0 as? SearchInterruption, .timedOut) }
        let rows = try database.withQueryBudget(seconds: 1) { try database.rows("SELECT 42 AS value") }
        XCTAssertEqual(rows.first?.int("value"), 42)
        XCTAssertThrowsError(try database.withQueryBudget(seconds: 1) { try database.rows("SELECT * FROM nonexistent_table") }) {
            XCTAssertTrue($0 is DatabaseError, "Real database failures must not become timeouts")
        }
    }

    func testCanceledBudgetProducesCancellationAndClearsHandler() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let database = try Database(url: root.appendingPathComponent("index.sqlite"))
            XCTAssertThrowsError(try database.withQueryBudget(seconds: 10) { try database.rows("SELECT 1") }) {
                XCTAssertTrue($0 is CancellationError)
            }
            XCTAssertEqual(try database.rows("SELECT 42 AS value").first?.int("value"), 42)
        }
        try await task.value
    }

    func testPackedScoringAgreesWithReferenceAndRejectsMalformedVectors() {
        let query: [Float] = (0..<512).map { sin(Float($0)) }
        for offset in 0..<12 {
            let vector: [Float] = (0..<512).map { cos(Float($0 + offset)) }
            let packed = SemanticEncoder.pack(vector)
            let expected = SemanticEncoder.cosine(query, SemanticEncoder.unpack(packed))
            let actual = packed.withUnsafeBytes { bytes in query.withUnsafeBufferPointer { q in
                fy_packed_cosine(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, q.baseAddress, q.count)
            }}
            XCTAssertEqual(actual, expected, accuracy: 0.000001)
        }
        let bad = Data(repeating: 0, count: 524)
        let actual = bad.withUnsafeBytes { bytes in query.withUnsafeBufferPointer { q in
            fy_packed_cosine(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, q.baseAddress, q.count)
        }}
        XCTAssertEqual(actual, -2)
    }

    func testRepeatedPassagesCannotCrowdOtherDocumentsOutOfSemanticResults() async throws {
        let encoder = SemanticEncoder()
        guard let query = encoder.encode("The quarterly budget forecast") else { throw XCTSkip("Local embedding unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("Long document".utf8).write(to: folder.appendingPathComponent("long.md"))
        try Data("Short document".utf8).write(to: folder.appendingPathComponent("short.md"))
        let url = root.appendingPathComponent("index.sqlite")
        let engine = try SearchEngine(databaseURL: url)
        let source = try await engine.addSource(url: folder)
        try await engine.scan(sourceID: source.id)
        let db = try Database(url: url)
        let files = try db.rows("SELECT name,content_id FROM files ORDER BY name")
        try db.transaction {
            try db.execute("DELETE FROM vectors")
            try db.execute("DELETE FROM passages")
            for (index, file) in files.enumerated() {
                let count = index == 0 ? 250 : 1
                for ordinal in 0..<count {
                    try db.execute("INSERT INTO passages(content_id,ordinal,text,location) VALUES(?,?,?,?)", [.integer(file.int("content_id")), .integer(Int64(ordinal)), .text("Budget forecast"), .text("Test")])
                    var vector = query
                    if index == 1 { vector[0] += 0.01 }
                    try db.execute("INSERT INTO vectors VALUES(?,?,?)", [.integer(db.lastID), .text(encoder.modelID), .blob(SemanticEncoder.pack(vector))])
                }
            }
        }
        let results = try await engine.search(SearchRequest(query: "The quarterly budget forecast", mode: .semantic, limit: 2))
        XCTAssertEqual(Set(results.map(\.filename)), Set(["long.md", "short.md"]))
    }

    func testReadOnlyPermissionFailureRequestsPersistentCacheRevocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = folder.appendingPathComponent("private-report.md")
        try Data("Confidential synthetic test marker".utf8).write(to: file)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let url = root.appendingPathComponent("index.sqlite")
        let writer = try SearchEngine(databaseURL: url)
        let source = try await writer.addSource(url: folder)
        try await writer.scan(sourceID: source.id)
        let purged = expectation(description: "Writer purges revoked content")
        let reader = try SearchEngine(databaseURL: url, readOnly: true, onAccessRevoked: { id in
            Task { try await writer.invalidateAccess(fileID: id); purged.fulfill() }
        })
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        let results = try await reader.search(SearchRequest(query: "private-report", mode: .names))
        XCTAssertTrue(results.isEmpty)
        await fulfillment(of: [purged], timeout: 3)
        let db = try Database(url: url, readOnly: true)
        XCTAssertEqual(try db.rows("SELECT status FROM files").first?.string("status"), "denied")
        XCTAssertTrue(try db.rows("SELECT id FROM passages").isEmpty)
    }

    func testReadOnlySearchDoesNotResetWriterStateAndNamesSkipContents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("Financial details".utf8).write(to: folder.appendingPathComponent("quarterly-report.md"))
        try Data("quarterly report appears only inside this file".utf8).write(to: folder.appendingPathComponent("unrelated.md"))
        let dbURL = root.appendingPathComponent("index.sqlite")
        let writer = try SearchEngine(databaseURL: dbURL)
        let source = try await writer.addSource(url: folder)
        try await writer.scan(sourceID: source.id)
        let db = try Database(url: dbURL)
        try db.execute("UPDATE sources SET availability='scanning' WHERE id=?", [.text(source.id)])
        let reader = try SearchEngine(databaseURL: dbURL, readOnly: true)
        XCTAssertEqual(try db.rows("SELECT availability FROM sources").first?.string("availability"), "scanning")
        var fast = SearchRequest(query: "arterly", mode: .names)
        fast.namesOnly = true
        let names = try await reader.search(fast)
        XCTAssertEqual(names.map(\.filename), ["quarterly-report.md"])
        XCTAssertTrue(names.allSatisfy { $0.passages.isEmpty })
        // WAL readers see committed rows while a writer holds an uncommitted update.
        try db.execute("BEGIN IMMEDIATE")
        try db.execute("UPDATE files SET name='uncommitted.md' WHERE name='quarterly-report.md'")
        let whileWriting = try await reader.search(fast)
        XCTAssertEqual(whileWriting.map(\.filename), ["quarterly-report.md"])
        try db.execute("ROLLBACK")
    }
}
