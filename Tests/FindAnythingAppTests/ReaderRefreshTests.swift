import XCTest
import Combine
import FindAnythingCore
@testable import FindAnythingApp

@MainActor
final class ReaderRefreshTests: XCTestCase {
    private let fullPreview = (1...300).map { Passage(id: Int64($0), text: "Cell \($0)", location: "CSV") }

    private func result(_ id: Int64 = 1) -> SearchResult {
        SearchResult(fileID: id, sourceID: "s", sourceName: "Source", filename: "inventory.csv",
                     path: "/inventory\(id).csv", fileExtension: "csv", modifiedAt: .distantPast,
                     passages: [fullPreview[0]])
    }

    func testRepeatedRefreshNeverCollapsesPreviewOrResetsSelection() async {
        let preview = fullPreview
        let model = AppModel(previewLoader: { _ in preview })
        model.results = [result()]
        model.selectedID = 1
        await model.loadReader().value
        model.selectedPassageID = 42
        var counts: [Int] = []
        let observation = model.$passages.sink { counts.append($0.count) }
        for score in 1...5 {
            model.results[0].score = Double(score)
            await model.loadReader().value
        }
        XCTAssertTrue(counts.allSatisfy { $0 == 300 }, "A refresh must never publish the one-passage search snippet")
        XCTAssertEqual(model.selectedPassageID, 42)
        withExtendedLifetime(observation) {}
    }

    func testSwitchingDocumentsClearsPreviousPreviewWhileLoading() async {
        let preview = fullPreview
        var resolve: CheckedContinuation<[Passage], Error>?
        let started = expectation(description: "Second preview requested")
        let model = AppModel(previewLoader: { result in
            if result.fileID == 1 { return preview }
            return try await withCheckedThrowingContinuation {
                resolve = $0
                started.fulfill()
            }
        })
        model.results = [result(), result(2)]
        model.selectedID = 1
        await model.loadReader().value
        model.selectedID = 2
        let loading = model.loadReader()
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.passages, result(2).passages)
        resolve?.resume(returning: [preview[10]])
        await loading.value
        XCTAssertEqual(model.passages, [preview[10]])
        XCTAssertEqual(model.selectedPassageID, 11)
        model.selectedID = nil
        await model.loadReader().value
        XCTAssertTrue(model.passages.isEmpty)
    }

    func testCancelledPreviewCannotOverwriteNewSelection() async {
        let preview = fullPreview
        var resolve: CheckedContinuation<[Passage], Error>?
        let started = expectation(description: "First preview requested")
        let model = AppModel(previewLoader: { result in
            if result.fileID == 2 { return [preview[20]] }
            return try await withCheckedThrowingContinuation {
                resolve = $0
                started.fulfill()
            }
        })
        model.results = [result(), result(2)]
        model.selectedID = 1
        let oldLoad = model.loadReader()
        await fulfillment(of: [started], timeout: 2)
        model.selectedID = 2
        await model.loadReader().value
        resolve?.resume(returning: preview)
        await oldLoad.value
        XCTAssertEqual(model.passages, [preview[20]])
    }

    func testRefreshClearsEvidenceWhenOfflineContentIsDisallowed() async {
        let preview = fullPreview
        let model = AppModel(previewLoader: { _ in preview })
        model.results = [result()]
        model.selectedID = 1
        await model.loadReader().value
        model.results[0].availability = .offline
        model.results[0].offlineContentAllowed = false
        await model.loadReader().value
        XCTAssertTrue(model.passages.isEmpty)
        XCTAssertNil(model.selectedPassageID)
    }
}
