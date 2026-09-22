import XCTest
import FindAnythingCore
@testable import FindAnythingApp

final class ResultGroupTests: XCTestCase {
    private func result(_ id: Int64, _ name: String, _ path: String) -> SearchResult {
        SearchResult(fileID: id, sourceID: "s", sourceName: "Source", filename: name, path: path, fileExtension: (name as NSString).pathExtension, modifiedAt: Date())
    }

    func testGroupsFullNamesPreservingRankAndDistinctLocations() {
        let values = [result(1, "Report.md", "/a/Report.md"), result(2, "notes.md", "/notes.md"), result(3, "report.md", "/b/report.md"), result(4, "Report.pdf", "/Report.pdf"), result(5, "Report.md", "/a/Report.md")]
        let groups = ResultGroup.make(values)
        XCTAssertEqual(groups.map(\.id), ["report.md", "notes.md", "report.pdf"])
        XCTAssertEqual(groups[0].results.map(\.fileID), [1, 3])
        XCTAssertEqual(ResultGroup.make(Array(values.reversed())).first { $0.id == "report.md" }?.id, groups[0].id)
    }

    @MainActor
    func testQuickSearchExpansionResetsForNewQuery() {
        let model = QuickSearchModel(library: AppModel())
        // Grouping and expansion state share stable filename keys across streamed batches.
        model.toggleGroup("report.md")
        XCTAssertTrue(model.expandedGroups.contains("report.md"))
        model.toggleGroup("report.md")
        XCTAssertFalse(model.expandedGroups.contains("report.md"))
        model.toggleGroup("report.md")
        model.setQuery("new search")
        XCTAssertTrue(model.expandedGroups.isEmpty)
    }
}
