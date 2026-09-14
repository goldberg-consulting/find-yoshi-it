import XCTest
import FindAnythingCore
@testable import FindAnythingApp

final class FileSearchPipelineTests: XCTestCase {
    @MainActor
    func testFastLookupFailureDoesNotCancelAuthoritativeContentResults() async throws {
        let item = SearchResult(fileID: 1, sourceID: "s", sourceName: "s", filename: "report.md", path: "/report.md", fileExtension: "md", modifiedAt: Date())
        let failed: FileSearchPipeline.Lookup = { _ in throw NSError(domain: "Lookup timeout", code: 1) }
        let pipeline = FileSearchPipeline(names: failed, content: { _ in [item] }, metadata: failed)
        let results = try await pipeline.search(SearchRequest(query: "report"))
        XCTAssertEqual(results.map(\.fileID), [1])
    }

    @MainActor
    func testMetadataAndIndexedVersionsHaveTheSameQuickSearchSelectionIdentity() {
        let indexed = SearchResult(fileID: 1, sourceID: "s", sourceName: "s", filename: "report.md", path: "/report.md", fileExtension: "md", modifiedAt: Date())
        var metadata = indexed; metadata.fileID = -100
        XCTAssertEqual(QuickSearchItem.document(indexed).id, QuickSearchItem.document(metadata).id)
    }

    @MainActor
    func testCanceledSearchDoesNotPublishLateResults() async throws {
        var published = false
        let slow: FileSearchPipeline.Lookup = { _ in
            try await Task.sleep(for: .seconds(1))
            return []
        }
        let pipeline = FileSearchPipeline(names: slow, content: slow, metadata: slow)
        let task = Task { try await pipeline.search(SearchRequest(query: "report")) { _ in published = true } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(published)
    }

    @MainActor
    func testNamesPublishBeforeSlowContentAndSurviveMetadataDeduplication() async throws {
        let name = SearchResult(fileID: 1, sourceID: "s", sourceName: "s", filename: "report.md", path: "/report.md", fileExtension: "md", modifiedAt: Date())
        var named = name; named.nameMatched = true
        var metadata = named; metadata.fileID = -1
        let fastResult = named, metadataResult = metadata
        var contentFinished = false
        var namesArrivedEarly = false
        let pipeline = FileSearchPipeline(names: { request in
            XCTAssertTrue(request.namesOnly)
            return [fastResult]
        }, content: { _ in
            try await Task.sleep(for: .milliseconds(150))
            await MainActor.run { contentFinished = true }
            return [name]
        }, metadata: { _ in [metadataResult] })
        let result = try await pipeline.search(SearchRequest(query: "report", mode: .names)) { partial in
            if !contentFinished && partial.first?.filename == "report.md" { namesArrivedEarly = true }
        }
        XCTAssertTrue(namesArrivedEarly)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.fileID, 1)
        XCTAssertEqual(result.first?.nameMatched, true)
    }
}
