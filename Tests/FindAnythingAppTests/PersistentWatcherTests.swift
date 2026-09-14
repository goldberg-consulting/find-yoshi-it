import XCTest
import FindAnythingCore
@testable import FindAnythingApp

final class PersistentWatcherTests: XCTestCase {
    @MainActor
    func testLiveEventsAndReplayAfterWatcherStops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Watcher-" + UUID().uuidString).resolvingSymlinksInPath()
        let documents = root.appendingPathComponent("documents")
        let index = root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ChangeJournal(url: index.appendingPathComponent("changes.sqlite"))
        let source = SourceRecord(name: "Test", path: documents.path, kind: .local)
        var errors: [String] = []
        let watcher = SourceWatcher(journal: journal, onChange: { _ in }, onError: { errors.append($0) })
        watcher.configure(sources: [source], indexDirectory: index)
        let baseline = try await waitForPending(journal, key: source.id)
        try journal.acknowledge(key: source.id, through: baseline.through)
        try Data("live".utf8).write(to: documents.appendingPathComponent("live.txt"))
        let live = try await waitForPending(journal, key: source.id)
        XCTAssertEqual(live.scopes, [""])
        await watcher.stop()
        // Drain events already delivered, then mutate while there is no active stream.
        if let remainder = try journal.pending(key: source.id) {
            try journal.acknowledge(key: source.id, through: remainder.through)
        }
        try Data("while stopped".utf8).write(to: documents.appendingPathComponent("offline.txt"))
        // FSEvents batches its on-disk log; replay may include a coalesced directory invalidation.
        try await Task.sleep(for: .seconds(2))
        let restarted = SourceWatcher(journal: journal, onChange: { _ in }, onError: { errors.append($0) })
        restarted.configure(sources: [source], indexDirectory: index)
        let replay = try await waitForPending(journal, key: source.id)
        XCTAssertGreaterThan(replay.through, live.through)
        XCTAssertEqual(replay.scopes, [""])
        await restarted.stop()
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
    }

    @MainActor
    private func waitForPending(_ journal: ChangeJournal, key: String) async throws -> ChangeJournal.Batch {
        for _ in 0..<150 {
            if let batch = try journal.pending(key: key) { return batch }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "Watcher test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for a filesystem change"])
    }
}
