import CoreServices
import XCTest
@testable import FindAnythingCore

final class ChangeJournalTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CDC-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func journal() throws -> ChangeJournal { try ChangeJournal(url: root.appendingPathComponent("changes.sqlite")) }

    func testCheckpointAndPendingWorkSurviveRestart() throws {
        do {
            let journal = try journal()
            XCTAssertEqual(try journal.prepare(key: "source", identity: "volumeA", current: 100), 100)
            let baseline = try XCTUnwrap(journal.pending(key: "source"))
            XCTAssertEqual(baseline.scopes, [""])
            try journal.acknowledge(key: "source", through: baseline.through)
            try journal.capture(key: "source", scopes: ["notes", "notes/nested", "other"], checkpoint: 110)
        }
        let restarted = try journal()
        XCTAssertEqual(try restarted.prepare(key: "source", identity: "volumeA", current: 200), 110)
        XCTAssertEqual(try restarted.pending(key: "source")?.scopes, ["notes", "other"])
    }

    func testFailedQueueWriteDoesNotAdvanceCheckpoint() throws {
        let journal = try journal()
        _ = try journal.prepare(key: "source", identity: "A", current: 1)
        let db = try Database(url: root.appendingPathComponent("changes.sqlite"))
        try db.executeScript("CREATE TRIGGER fail_capture BEFORE INSERT ON dirty_scopes BEGIN SELECT RAISE(ABORT,'simulated disk failure'); END;")
        XCTAssertThrowsError(try journal.capture(key: "source", scopes: ["notes"], checkpoint: 50))
        XCTAssertEqual(try journal.prepare(key: "source", identity: "A", current: 100), 1)
    }

    func testChangesDuringScanSurviveAcknowledgementIncludingSamePath() throws {
        let journal = try journal()
        _ = try journal.prepare(key: "source", identity: "A", current: 1)
        let batch = try XCTUnwrap(journal.pending(key: "source"))
        try journal.capture(key: "source", scopes: ["", "new"], checkpoint: 2)
        try journal.acknowledge(key: "source", through: batch.through)
        let next = try XCTUnwrap(journal.pending(key: "source"))
        XCTAssertGreaterThan(next.through, batch.through)
        XCTAssertEqual(next.scopes, [""])
        try journal.acknowledge(key: "source", through: next.through)
        XCTAssertNil(try journal.pending(key: "source"))
    }

    func testVolumeReplacementAndRegressedHistoryRequireBaseline() throws {
        let journal = try journal()
        _ = try journal.prepare(key: "source", identity: "A", current: 100)
        try journal.capture(key: "source", scopes: ["notes"], checkpoint: 120)
        XCTAssertEqual(try journal.prepare(key: "source", identity: "B", current: 150), 150)
        XCTAssertEqual(try journal.pending(key: "source")?.scopes, [""])
        let batch = try XCTUnwrap(journal.pending(key: "source"))
        try journal.acknowledge(key: "source", through: batch.through)
        XCTAssertEqual(try journal.prepare(key: "source", identity: "B", current: 3), 3)
        XCTAssertEqual(try journal.pending(key: "source")?.scopes, [""])
    }

    func testBurstCompactsToFullScanAndStreamsRemainIndependent() throws {
        let journal = try journal()
        _ = try journal.prepare(key: "A", identity: "A", current: 1)
        _ = try journal.prepare(key: "B", identity: "B", current: 1)
        try journal.capture(key: "A", scopes: (0..<600).map { "folder\($0)" }, checkpoint: 2)
        XCTAssertEqual(try journal.pending(key: "A")?.scopes, [""])
        let a = try XCTUnwrap(journal.pending(key: "A"))
        try journal.acknowledge(key: "A", through: a.through)
        XCTAssertNotNil(try journal.pending(key: "B"))
    }

    func testEventRoutingHandlesDropsAncestorsDeletesAndExclusions() {
        let root = "/Users/test/Documents"
        XCTAssertEqual(FileChangeRouting.scope(path: root + "/notes/deleted.md", flags: 0, root: root), "notes")
        XCTAssertEqual(FileChangeRouting.scope(path: "/Users/test", flags: 0, root: root), "")
        XCTAssertNil(FileChangeRouting.scope(path: root + "Other/file", flags: 0, root: root))
        XCTAssertNil(FileChangeRouting.scope(path: root + "/notes/file.tmp", flags: 0, root: root, exclusions: ["*.tmp"]))
        XCTAssertNil(FileChangeRouting.scope(path: root + "/index/Changes.sqlite-wal", flags: 0, root: root, indexPath: root + "/index"))
        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagRootChanged, kFSEventStreamEventFlagEventIdsWrapped] {
            XCTAssertEqual(FileChangeRouting.scope(path: "/", flags: UInt32(flag), root: root), "")
        }
        XCTAssertNil(FileChangeRouting.scope(path: root, flags: UInt32(kFSEventStreamEventFlagHistoryDone), root: root))
        XCTAssertEqual(FileChangeRouting.scope(path: "/private/tmp/test/notes/a", flags: 0, root: "/tmp/test"), "notes")
    }
}
