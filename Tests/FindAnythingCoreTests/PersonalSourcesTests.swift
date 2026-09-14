import XCTest
@testable import FindAnythingCore

final class PersonalSourcesTests: XCTestCase {
    func testBroadCrawlIsRetainedAndPausedOncePersonalFoldersAreRegistered() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Documents", "Desktop", "Downloads"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let url = root.appendingPathComponent("index.sqlite")
        let engine = try SearchEngine(databaseURL: url)
        let database = try Database(url: url)
        try database.execute("INSERT INTO sources(id,name,path,kind,availability,exclusions,identity) VALUES('broad','Broad','/','local','online','[]','fake-root')")
        let added = try await engine.prioritizePersonalSources(home: root)
        XCTAssertEqual(added.count, 3)
        let sources = try await engine.sources()
        XCTAssertEqual(sources.count, 4)
        XCTAssertEqual(sources.first { $0.id == "broad" }?.availability, .paused)
        let repeated = try await engine.prioritizePersonalSources(home: root)
        XCTAssertTrue(repeated.isEmpty)
    }
}
