import CoreServices
import FindAnythingCore
import Foundation

/// One persistent stream per source keeps checkpoints independent of source-list changes.
@MainActor
final class SourceWatcher {
    private let journal: ChangeJournal
    private let onChange: (String) -> Void
    private let onError: (String) -> Void
    private var workers: [String: WatcherWorker] = [:]
    private var signatures: [String: String] = [:]
    private var pending: [String: Task<Void, Never>] = [:]

    init(journal: ChangeJournal, onChange: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.journal = journal
        self.onChange = onChange
        self.onError = onError
    }

    static let applicationPrefix = "applications:"

    func configure(sources: [SourceRecord], indexDirectory: URL?) {
        var targets = sources.filter { $0.kind != .network && $0.availability != .offline && $0.availability != .paused }
            .map { WatchTarget(key: $0.id, path: $0.path, exclusions: $0.exclusions, indexPath: indexDirectory?.path ?? "") }
        targets += ApplicationCatalog.defaultRoots.map { root in
            let path = root.pathExtension == "app" ? root.deletingLastPathComponent().path : root.path
            return WatchTarget(key: Self.applicationPrefix + path, path: path, exclusions: [], indexPath: "")
        }
        let keys = Set(targets.map(\.key))
        for key in Array(workers.keys) where !keys.contains(key) {
            workers.removeValue(forKey: key)?.shutdown()
            signatures.removeValue(forKey: key)
            pending.removeValue(forKey: key)?.cancel()
        }
        for target in targets {
            let signature = target.path + "|" + target.exclusions.joined(separator: "|")
            guard signatures[target.key] != signature else { continue }
            workers.removeValue(forKey: target.key)?.shutdown()
            signatures[target.key] = signature
            let worker = WatcherWorker()
            workers[target.key] = worker
            worker.start(target: target, journal: journal) { [weak self, weak worker] error in
                Task { @MainActor [weak self, weak worker] in
                    guard let self, let worker, self.workers[target.key] === worker else { return }
                    if let error { self.signatures.removeValue(forKey: target.key); self.onError(error); return }
                    // A fixed deadline prevents continuous writes from starving indexing.
                    guard self.pending[target.key] == nil else { return }
                    self.pending[target.key] = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        guard let self else { return }
                        self.pending[target.key] = nil
                        self.onChange(target.key)
                    }
                }
            }
        }
    }

    func forget(_ key: String) async throws {
        pending.removeValue(forKey: key)?.cancel()
        if let worker = workers.removeValue(forKey: key) { await worker.stopAndWait() }
        signatures.removeValue(forKey: key)
        try journal.forget(key: key)
    }

    func stop() async {
        for task in pending.values { task.cancel() }
        pending.removeAll()
        let stopping = Array(workers.values)
        workers.removeAll()
        signatures.removeAll()
        for worker in stopping { await worker.stopAndWait() }
    }

    deinit {
        for task in pending.values { task.cancel() }
        for worker in workers.values { worker.shutdown() }
    }
}

private struct WatchTarget: Sendable {
    let key: String
    let path: String
    let exclusions: [String]
    let indexPath: String
}

private final class WatcherWorker: @unchecked Sendable {
    // Serial teardown/start also prevents an old stream writing into a replacement stream's checkpoint.
    private static let eventQueue = DispatchQueue(label: "local.findanything.persistent-events", qos: .utility)
    private let queue = WatcherWorker.eventQueue
    private var stream: FSEventStreamRef?
    private var target: WatchTarget?
    private var journal: ChangeJournal?
    private var checkpoint: UInt64 = 0
    private var notify: (@Sendable (String?) -> Void)?

    func start(target: WatchTarget, journal: ChangeJournal, notify: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            self.target = target
            self.journal = journal
            self.notify = notify
            do {
                let root = URL(fileURLWithPath: target.path)
                let values = try? root.resourceValues(forKeys: [.volumeUUIDStringKey])
                let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
                let identity = target.path + "|" + (values?.volumeUUIDString ?? "missing") + "|" + String(describing: attributes?[.systemFileNumber]) + "|" + target.exclusions.joined(separator: "|")
                checkpoint = try journal.prepare(key: target.key, identity: identity, current: FSEventsGetCurrentEventId())
                var watched = root
                while !FileManager.default.fileExists(atPath: watched.path), watched.path != "/" { watched.deleteLastPathComponent() }
                var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
                let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, ids in
                    guard let info else { return }
                    let worker = Unmanaged<WatcherWorker>.fromOpaque(info).takeUnretainedValue()
                    let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                    worker.receive((0..<count).map { (String(cString: paths[$0]), flags[$0], ids[$0]) })
                }
                let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
                guard let created = FSEventStreamCreate(nil, callback, &context, [watched.path] as CFArray, checkpoint, 1, flags) else {
                    throw NSError(domain: "File watching", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create change tracking for \(target.path). Periodic reconciliation remains active."])
                }
                stream = created
                FSEventStreamSetDispatchQueue(created, queue)
                guard FSEventStreamStart(created) else {
                    stopStream()
                    throw NSError(domain: "File watching", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not start change tracking for \(target.path). Periodic reconciliation remains active."])
                }
                // Stream is active before the baseline scan or recovery queue is dispatched.
                if try journal.pending(key: target.key) != nil { notify(nil) }
            } catch { notify(error.localizedDescription) }
        }
    }

    private func receive(_ events: [(String, FSEventStreamEventFlags, FSEventStreamEventId)]) {
        guard let target, let journal else { return }
        var scopes: [String] = []
        var next = checkpoint
        for (raw, flags, id) in events {
            if flags & UInt32(kFSEventStreamEventFlagEventIdsWrapped) != 0 { next = FSEventsGetCurrentEventId() }
            else if id > 0 { next = max(next, id) }
            if let scope = FileChangeRouting.scope(path: raw, flags: flags, root: target.path, indexPath: target.indexPath, exclusions: target.exclusions) {
                scopes.append(scope)
            }
        }
        do {
            try journal.capture(key: target.key, scopes: scopes, checkpoint: next)
            checkpoint = next
            if !scopes.isEmpty { notify?(nil) }
        } catch {
            // Stop before a later batch can advance beyond work that failed to persist.
            stopStream()
            notify?("Change tracking paused: \(error.localizedDescription). Restart the app to replay changes; periodic reconciliation remains active.")
        }
    }

    func stopAndWait() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in stopStream(); notify = nil; continuation.resume() }
        }
    }

    func shutdown() { queue.async { [self] in stopStream(); notify = nil } }

    private func stopStream() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}
