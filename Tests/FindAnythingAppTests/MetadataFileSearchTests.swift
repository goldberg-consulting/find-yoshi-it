import XCTest
import FindAnythingCore
@testable import FindAnythingApp

final class MetadataFileSearchTests: XCTestCase {
    @MainActor
    func testSingleWordAndMultipleWordQueriesRunThroughMacOSWithoutException() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = [SourceRecord(name: "Test", path: root.path)]
        for query in ["samplenotes", "sample notes"] {
            _ = await MetadataFileSearch.search(SearchRequest(query: query, mode: .names), sources: sources)
        }
    }

    @MainActor
    func testMetadataRespectsExclusionsCategoryAndSourceScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.md")
        try Data("notes".utf8).write(to: file)
        var source = SourceRecord(name: "Test", path: root.path, exclusions: [])
        let request = SearchRequest(query: "notes", mode: .names, category: .documents)
        XCTAssertEqual(MetadataFileSearch.result(path: file.path, request: request, sources: [source])?.nameMatched, true)
        source.exclusions = ["*.md"]
        XCTAssertNil(MetadataFileSearch.result(path: file.path, request: request, sources: [source]))
        source.exclusions = []
        source.availability = .paused
        XCTAssertNil(MetadataFileSearch.result(path: file.path, request: request, sources: [source]))
        source.availability = .online
        XCTAssertNil(MetadataFileSearch.result(path: file.path, request: SearchRequest(query: "notes", sourceID: "different"), sources: [source]))
        XCTAssertNil(MetadataFileSearch.result(path: file.path, request: SearchRequest(query: "notes", category: .other), sources: [source]))
    }
}
