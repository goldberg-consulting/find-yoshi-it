import XCTest
@testable import FindAnythingCore

final class SearchHistoryTests: XCTestCase {
    func testHistoryPersistsQueryPreferenceWithoutCrossingCategories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("History-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.sqlite")
        let history = try SearchHistory(url: url)
        let apps = [ApplicationRecord(path: "/Calculator.app", name: "Calculator"), ApplicationRecord(path: "/Calendar.app", name: "Calendar")]
        try await history.record(query: "ca", path: apps[1].path)
        let reopened = try SearchHistory(url: url)
        let ranked = try await reopened.rank(apps, query: "ca")
        XCTAssertEqual(ranked.first?.name, "Calendar")
        var name = SearchResult(fileID: 1, sourceID: "s", sourceName: "s", filename: "notes.md", path: "/notes.md", fileExtension: "md", modifiedAt: Date())
        name.nameMatched = true
        let content = SearchResult(fileID: 2, sourceID: "s", sourceName: "s", filename: "other.md", path: "/other.md", fileExtension: "md", modifiedAt: Date())
        let code = SearchResult(fileID: 3, sourceID: "s", sourceName: "s", filename: "notes.py", path: "/notes.py", fileExtension: "py", modifiedAt: Date())
        for _ in 0..<5 { try await history.record(query: "notes", path: content.path); try await history.record(query: "notes", path: code.path) }
        let files = try await history.rank([code, content, name], query: "notes")
        XCTAssertEqual(files.map(\.fileID), [1,2,3])
    }
}
