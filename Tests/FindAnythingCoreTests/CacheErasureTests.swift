import Foundation
import XCTest
@testable import FindAnythingCore

final class CacheErasureTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("FindAnythingErasure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspace { try FileManager.default.removeItem(at: workspace) }
    }

    func testRemovingSourceErasesItsTextAndFilenameFromDatabaseAndWAL() async throws {
        let deletedSource = workspace.appendingPathComponent("deleted")
        let keptSource = workspace.appendingPathComponent("kept")
        for folder in [deletedSource, keptSource] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let contentMarker = "confidentialerasuremarkerzulu"
        let filenameMarker = "privatefilenameerasurexray"
        try Data(contentMarker.utf8).write(to: deletedSource.appendingPathComponent(filenameMarker + ".txt"))
        try Data("survivingdocumentmarker remains searchable".utf8)
            .write(to: keptSource.appendingPathComponent("retained.txt"))
        let databaseURL = workspace.appendingPathComponent("index/library.sqlite")
        let engine = try SearchEngine(databaseURL: databaseURL)
        let deleted = try await engine.addSource(url: deletedSource)
        let kept = try await engine.addSource(url: keptSource)
        try await engine.scan(sourceID: deleted.id)
        try await engine.scan(sourceID: kept.id)

        let indexed = try await engine.search(SearchRequest(query: contentMarker, mode: .exact))
        XCTAssertEqual(indexed.count, 1)
        XCTAssertNotNil(try storedBytes(databaseURL).range(of: Data(contentMarker.utf8)))
        try await engine.removeSource(id: deleted.id)

        let removed = try await engine.search(SearchRequest(query: contentMarker, mode: .exact))
        let retained = try await engine.search(SearchRequest(query: "survivingdocumentmarker", mode: .exact))
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(retained.count, 1)
        let bytes = try storedBytes(databaseURL)
        XCTAssertNil(bytes.range(of: Data(contentMarker.utf8)))
        XCTAssertNil(bytes.range(of: Data(filenameMarker.utf8)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: deletedSource.appendingPathComponent(filenameMarker + ".txt").path))
    }

    func testPurgeErasesLegacyFTSSegmentsAndPreservesRemainingMatches() throws {
        let databaseURL = workspace.appendingPathComponent("library.sqlite")
        let database = try Database(url: databaseURL)
        // Existing indexes can contain segments created without FTS secure deletion.
        try? database.execute("INSERT INTO passage_fts(passage_fts,rank) VALUES('secure-delete',0)")
        let marker = "legacyconfidentialerasuremarker"
        try database.execute("INSERT INTO contents(id,fingerprint,extractor,status) VALUES(1,'removed','test','indexed'),(2,'retained','test','indexed')")
        try database.execute("INSERT INTO passages(content_id,ordinal,text,location) VALUES(1,0,?,'line 1'),(2,0,'retainedsearchmarker','line 1')", [.text(marker)])
        try database.execute("DELETE FROM contents WHERE id=1")
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        XCTAssertNotNil(try storedBytes(databaseURL).range(of: Data(marker.utf8)))

        try database.purgeDeletedText()

        XCTAssertNil(try storedBytes(databaseURL).range(of: Data(marker.utf8)))
        XCTAssertEqual(try database.rows("SELECT rowid FROM passage_fts WHERE passage_fts MATCH 'retainedsearchmarker'").count, 1)
        XCTAssertTrue(try database.rows("SELECT rowid FROM passage_fts WHERE passage_fts MATCH ?", [.text(marker)]).isEmpty)
    }

    private func storedBytes(_ databaseURL: URL) throws -> Data {
        var bytes = Data()
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                bytes.append(try Data(contentsOf: url))
            }
        }
        return bytes
    }
}
