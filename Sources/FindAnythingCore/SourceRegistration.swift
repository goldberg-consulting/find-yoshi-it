import Foundation

struct RegisteredSource: Sendable {
    let root: URL
    let identity: FolderIdentity
}

enum SourceRegistrationError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        "The folder or share did not respond in time. Check its connection and try again."
    }
}

/// Blocking filesystem probes run on at most two utility workers, never the search actor.
struct SourceRegistration: Sendable {
    static let shared = SourceRegistration()
    private static let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "local.findanything.source-registration"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    private let timeout: Duration
    private let probe: @Sendable (URL) throws -> RegisteredSource

    init(timeout: Duration = .seconds(20), probe: @escaping @Sendable (URL) throws -> RegisteredSource = { url in
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        return RegisteredSource(root: root, identity: try FolderIdentity.read(root))
    }) {
        self.timeout = timeout
        self.probe = probe
    }

    /// Cancellation and deadlines release the caller without waiting for an uninterruptible syscall.
    func inspect(_ url: URL) async throws -> RegisteredSource {
        let attempt = RegistrationAttempt()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard attempt.install(continuation) else { return }
                let operation = BlockOperation {
                    guard attempt.beginWork() else { return }
                    attempt.finish(Result { try probe(url) })
                }
                guard attempt.install(operation) else { return }
                let timer = Task {
                    do { try await Task.sleep(until: deadline, clock: .continuous) }
                    catch { return }
                    attempt.finish(.failure(SourceRegistrationError.timedOut))
                }
                attempt.install(timer)
                Self.workers.addOperation(operation)
            }
        } onCancel: {
            attempt.finish(.failure(CancellationError()))
        }
        try Task.checkCancellation()
        return result
    }
}

/// Every mutable field is protected by lock; continuations resume after releasing it.
private final class RegistrationAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: Result<RegisteredSource, Error>?
    private var continuation: CheckedContinuation<RegisteredSource, Error>?
    private var operation: Operation?
    private var timer: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<RegisteredSource, Error>) -> Bool {
        lock.lock()
        if let completion {
            lock.unlock()
            continuation.resume(with: completion)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func install(_ operation: Operation) -> Bool {
        lock.lock()
        guard completion == nil else {
            lock.unlock()
            operation.cancel()
            return false
        }
        self.operation = operation
        lock.unlock()
        return true
    }

    func install(_ timer: Task<Void, Never>) {
        lock.lock()
        guard completion == nil else {
            lock.unlock()
            timer.cancel()
            return
        }
        self.timer = timer
        lock.unlock()
    }

    func beginWork() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return completion == nil
    }

    func finish(_ result: Result<RegisteredSource, Error>) {
        lock.lock()
        guard completion == nil else { lock.unlock(); return }
        completion = result
        let continuation = self.continuation
        let operation = self.operation
        let timer = self.timer
        self.continuation = nil
        self.operation = nil
        self.timer = nil
        lock.unlock()
        operation?.cancel()
        timer?.cancel()
        continuation?.resume(with: result)
    }
}
