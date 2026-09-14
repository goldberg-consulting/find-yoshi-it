import Foundation
import XCTest
@testable import FindAnythingCore

final class SourceRegistrationTests: XCTestCase {
    private let fixtureURL = URL(fileURLWithPath: "/Volumes/RegistrationFixture", isDirectory: true)

    func test_normal_completion_runs_probe_once_and_returns_result() async throws {
        let count = ProbeCounter()
        let registration = SourceRegistration { url in
            count.increment()
            return RegisteredSource(root: url, identity: FolderIdentity(identity: "fixture", kind: .network))
        }
        let result = try await registration.inspect(fixtureURL)
        XCTAssertEqual(result.root, fixtureURL)
        XCTAssertEqual(result.identity.identity, "fixture")
        XCTAssertEqual(count.value, 1)
    }

    func test_probe_error_is_delivered_once() async {
        let count = ProbeCounter()
        let registration = SourceRegistration { _ in
            count.increment()
            throw FixtureError.failed
        }
        do { _ = try await registration.inspect(fixtureURL); XCTFail("Probe errors must propagate.") }
        catch { XCTAssertTrue(error is FixtureError) }
        XCTAssertEqual(count.value, 1)
    }

    func test_cancellation_returns_before_blocked_probe_and_ignores_late_completion() async throws {
        let gate = BlockingProbeGate()
        defer { gate.release() }
        let started = expectation(description: "Probe started")
        let completed = expectation(description: "Late probe finished")
        let registration = SourceRegistration(timeout: .seconds(5)) { url in
            started.fulfill()
            gate.wait()
            completed.fulfill()
            return RegisteredSource(root: url, identity: FolderIdentity(identity: "late", kind: .network))
        }
        let task = Task { try await registration.inspect(fixtureURL) }
        await fulfillment(of: [started], timeout: 1)
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must win over a late probe.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(300))
        gate.release()
        await fulfillment(of: [completed], timeout: 1)
    }

    func test_timeout_returns_before_blocked_probe_and_late_result_cannot_insert_source() async throws {
        let workspace = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let engine = try SearchEngine(databaseURL: workspace.appendingPathComponent("library.sqlite"))
        let gate = BlockingProbeGate()
        defer { gate.release() }
        let started = expectation(description: "Probe started")
        let completed = expectation(description: "Late probe finished")
        let registration = SourceRegistration(timeout: .milliseconds(60)) { url in
            started.fulfill()
            gate.wait()
            completed.fulfill()
            return RegisteredSource(root: url, identity: FolderIdentity(identity: "late", kind: .network))
        }
        let start = ContinuousClock.now
        let task = Task { try await engine.addSource(url: fixtureURL, registration: registration) }
        await fulfillment(of: [started], timeout: 1)
        do { _ = try await task.value; XCTFail("The blocked registration must time out.") }
        catch { XCTAssertTrue(error is SourceRegistrationError) }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        let before = try await engine.sources()
        XCTAssertTrue(before.isEmpty)
        gate.release()
        await fulfillment(of: [completed], timeout: 1)
        let after = try await engine.sources()
        XCTAssertTrue(after.isEmpty)
    }

    func test_cancelled_registration_keeps_search_actor_responsive_and_creates_no_source() async throws {
        let workspace = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let engine = try SearchEngine(databaseURL: workspace.appendingPathComponent("library.sqlite"))
        let gate = BlockingProbeGate()
        defer { gate.release() }
        let started = expectation(description: "Probe started")
        let completed = expectation(description: "Late probe finished")
        let registration = SourceRegistration(timeout: .seconds(5)) { url in
            started.fulfill()
            gate.wait()
            completed.fulfill()
            return RegisteredSource(root: url, identity: FolderIdentity(identity: "cancelled", kind: .network))
        }
        let task = Task { try await engine.addSource(url: fixtureURL, registration: registration) }
        await fulfillment(of: [started], timeout: 1)
        let start = ContinuousClock.now
        let available = try await engine.sources()
        XCTAssertTrue(available.isEmpty)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(300))
        task.cancel()
        do { _ = try await task.value; XCTFail("A canceled request must not register its source.") }
        catch { XCTAssertTrue(error is CancellationError) }
        gate.release()
        await fulfillment(of: [completed], timeout: 1)
        let after = try await engine.sources()
        XCTAssertTrue(after.isEmpty)
    }

    func test_only_two_probes_run_and_cancelled_queued_work_never_starts() async throws {
        let gate = BlockingProbeGate()
        defer { gate.release() }
        let started = expectation(description: "Two probes occupied the workers")
        started.expectedFulfillmentCount = 2
        let finished = expectation(description: "Occupied workers finished")
        finished.expectedFulfillmentCount = 2
        let registration = SourceRegistration(timeout: .seconds(5)) { url in
            started.fulfill()
            gate.wait()
            finished.fulfill()
            return RegisteredSource(root: url, identity: FolderIdentity(identity: "blocked", kind: .network))
        }
        let first = Task { try await registration.inspect(fixtureURL) }
        let second = Task { try await registration.inspect(fixtureURL) }
        await fulfillment(of: [started], timeout: 1)
        let counter = ProbeCounter()
        let queued = SourceRegistration(timeout: .seconds(5)) { url in
            counter.increment()
            return RegisteredSource(root: url, identity: FolderIdentity(identity: "queued", kind: .network))
        }
        let third = Task { try await queued.inspect(fixtureURL) }
        // Give the third caller a chance to enqueue while both workers are occupied.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(counter.value, 0)
        third.cancel()
        do { _ = try await third.value; XCTFail("Queued cancellation must return promptly.") }
        catch { XCTAssertTrue(error is CancellationError) }
        gate.release()
        _ = try await first.value
        _ = try await second.value
        await fulfillment(of: [finished], timeout: 1)
        let barrier = SourceRegistration { url in RegisteredSource(root: url, identity: FolderIdentity(identity: "barrier", kind: .local)) }
        _ = try await barrier.inspect(fixtureURL)
        XCTAssertEqual(counter.value, 0)
    }

    func test_pre_cancelled_request_never_runs_probe() async {
        let counter = ProbeCounter()
        let registration = SourceRegistration { url in
            counter.increment()
            return RegisteredSource(root: url, identity: FolderIdentity(identity: "unexpected", kind: .local))
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await registration.inspect(fixtureURL)
        }
        do { _ = try await task.value; XCTFail("Pre-cancelled requests must fail.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(counter.value, 0)
    }

    func test_successful_registrations_preserve_identity_deduplication() async throws {
        let workspace = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let engine = try SearchEngine(databaseURL: workspace.appendingPathComponent("library.sqlite"))
        let registration = SourceRegistration { url in RegisteredSource(root: url, identity: FolderIdentity(identity: "same-share", kind: .network)) }
        let first = try await engine.addSource(url: fixtureURL, registration: registration)
        let second = try await engine.addSource(url: fixtureURL, registration: registration)
        XCTAssertEqual(first.id, second.id)
        let sources = try await engine.sources()
        XCTAssertEqual(sources.count, 1)
    }

    private func temporaryWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FindAnythingRegistrationTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private enum FixtureError: Error { case failed }

/// Tests deliberately model a blocking syscall; the fallback deadline prevents stuck workers.
private final class BlockingProbeGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false

    func wait() {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while !released {
            if !condition.wait(until: deadline) { break }
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
