import XCTest
@testable import FindAnythingCore

final class SearchPresentationTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SearchOrder-" + UUID().uuidString)
        folder = root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ name: String, text: String = "Example content") throws {
        let file = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    private func indexed() async throws -> SearchEngine {
        let engine = try SearchEngine(databaseURL: root.appendingPathComponent("index/db.sqlite"))
        let source = try await engine.addSource(url: folder)
        try await engine.scan(sourceID: source.id)
        return engine
    }

    func testDocumentsCannotBeCrowdedOutByOtherFilesBeforeLimit() async throws {
        for index in 0..<200 { try write("report-\(index).swift") }
        try write("report-summary.md")
        let engine = try await indexed()
        let results = try await engine.search(SearchRequest(query: "report", mode: .exact, limit: 3))
        XCTAssertEqual(results.first?.filename, "report-summary.md")
        XCTAssertEqual(results.count, 3)
        let docs = try await engine.search(SearchRequest(query: "report", category: .documents))
        XCTAssertEqual(docs.map(\.filename), ["report-summary.md"])
        let other = try await engine.search(SearchRequest(query: "report", category: .other))
        XCTAssertTrue(other.allSatisfy { $0.fileExtension == "swift" })
    }

    func testDependencyDirectoriesHiddenUnlessExplicitlyRequested() async throws {
        try write("project.md")
        for path in [".venv/project.md", "venv/project.txt", "node_modules/project.md", ".node/project.md", "project.node"] { try write(path) }
        let engine = try await indexed()
        let normal = try await engine.search(SearchRequest(query: "project", mode: .exact))
        XCTAssertEqual(normal.map(\.path), [folder.appendingPathComponent("project.md").path])
        let node = try await engine.search(SearchRequest(query: "node_modules", mode: .exact))
        XCTAssertEqual(node.map(\.path), [folder.appendingPathComponent("node_modules/project.md").path])
        let venv = try await engine.search(SearchRequest(query: ".venv", mode: .exact))
        XCTAssertEqual(venv.count, 1)
        XCTAssertTrue(venv.first?.path.contains("/.venv/") == true)
        let explicit = try await engine.search(SearchRequest(query: "project.node", mode: .exact))
        XCTAssertEqual(explicit.map(\.filename), ["project.node"])
        let recent = try await engine.search(SearchRequest(query: ""))
        XCTAssertEqual(recent.map(\.filename), ["project.md"])
    }

    func testExactDependencyFilenameIsAnExplicitRequest() async throws {
        try write(".venv/unique-module.py")
        let engine = try await indexed()
        let broad = try await engine.search(SearchRequest(query: "unique"))
        XCTAssertTrue(broad.isEmpty)
        let explicit = try await engine.search(SearchRequest(query: "unique-module.py"))
        XCTAssertEqual(explicit.count, 1)
    }

    func testNameFirstSearchRanksNamesAheadOfContentFallback() async throws {
        try write("planning.md", text: "A matching document")
        try write("unrelated.md", text: "planning planning planning")
        try write("planning/notes.md", text: "planning")
        let engine = try await indexed()
        let names = try await engine.search(SearchRequest(query: "planning", mode: .names))
        XCTAssertEqual(names.first?.filename, "planning.md")
        XCTAssertEqual(names.count, 3)
        XCTAssertTrue(names.first?.nameMatched == true)
        XCTAssertTrue(names.dropFirst().allSatisfy { !$0.nameMatched })
        let broad = try await engine.search(SearchRequest(query: "planning", mode: .hybrid))
        XCTAssertEqual(broad.count, 3)
        let missing = try await engine.search(SearchRequest(query: "matching document", mode: .names))
        XCTAssertEqual(missing.map(\.filename), ["planning.md"])
    }

    func testContentsRefineNamesThenProvideFallback() async throws {
        try write("annual-a.md", text: "Travel arrangements")
        try write("annual-b.md", text: "The budget includes a revised budget forecast.")
        try write("unrelated.md", text: "annual budget annual budget")
        let engine = try await indexed()
        let results = try await engine.search(SearchRequest(query: "annual budget", mode: .names))
        XCTAssertEqual(Set(results.map(\.filename)), ["annual-a.md", "annual-b.md", "unrelated.md"])
        XCTAssertEqual(results.last?.filename, "unrelated.md")
        XCTAssertEqual(results.first?.filename, "annual-b.md")
        XCTAssertTrue(results.first?.passages.first?.text.contains("budget") == true)
    }

    func testNameModeStillAllowsExplicitDependencyPaths() async throws {
        try write("node_modules/example/index.js")
        let engine = try await indexed()
        let results = try await engine.search(SearchRequest(query: "node_modules", mode: .names))
        XCTAssertEqual(results.map(\.filename), ["index.js"])
    }

    func testOnlyUncustomizedLegacyDependencyExclusionIsMigrated() throws {
        let path = root.appendingPathComponent("migration.sqlite")
        do {
            let db = try Database(url: path)
            for (id, exclusions) in [("old", [".git", "node_modules", ".build", ".DS_Store"]), ("custom", ["node_modules", "private"])] {
                let json = String(decoding: try JSONEncoder().encode(exclusions), as: UTF8.self)
                try db.execute("INSERT INTO sources(id,name,path,kind,availability,exclusions,identity) VALUES(?,?,?,'local','online',?,?)", [.text(id), .text(id), .text(folder.path), .text(json), .text(id)])
            }
            try db.execute("DELETE FROM settings WHERE key='dependency-search-defaults-v1'")
        }
        let reopened = try Database(url: path)
        let old = try XCTUnwrap(reopened.rows("SELECT exclusions FROM sources WHERE id='old'").first)
        XCTAssertFalse(old.string("exclusions").contains("node_modules"))
        let custom = try XCTUnwrap(reopened.rows("SELECT exclusions FROM sources WHERE id='custom'").first)
        XCTAssertTrue(custom.string("exclusions").contains("node_modules"))
    }

    func testCommonDocumentClassification() {
        for ext in ["md", "DOCX", "pptx", "pdf", "xlsx", "pages", "txt"] { XCTAssertTrue(SearchPresentation.isDocument(extension: ext)) }
        for ext in ["swift", "py", "node", "so", "json", "png"] { XCTAssertFalse(SearchPresentation.isDocument(extension: ext)) }
    }
}
