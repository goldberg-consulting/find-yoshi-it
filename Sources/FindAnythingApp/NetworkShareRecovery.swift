import Foundation
import Network
import CoreWLAN

/// Rechecks remembered servers after route/interface changes and while the NAS boots.
/// NetFS uses saved system credentials and never displays background sign-in dialogs.
@MainActor
final class NetworkShareRecovery {
    private let monitor = NWPathMonitor()
    private var timer: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var connected = false
    private var usesWiFi = false
    private var homeSSID: String
    private var attempts: [URL: NASMountWorker] = [:]
    private var deadlines: [URL: Task<Void, Never>] = [:]
    private var lastAttempt: [URL: Date] = [:]
    private let targets: () async -> [URL]
    private let refresh: () async -> Void

    init(homeSSID: String, targets: @escaping () async -> [URL], refresh: @escaping () async -> Void) {
        self.homeSSID = homeSSID
        self.targets = targets
        self.refresh = refresh
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.connected = available
                self.usesWiFi = wifi
                // Old requests belong to the old route, including Ethernet-to-Wi-Fi switches.
                self.cancelAttempts()
                self.lastAttempt.removeAll()
                self.checkTask?.cancel()
                self.checkTask = nil
                self.check()
            }
        }
        monitor.start(queue: DispatchQueue(label: "local.findanything.network-path"))
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self?.check()
            }
        }
    }

    func updateHomeSSID(_ name: String) {
        guard homeSSID != name else { return }
        homeSSID = name
        cancelAttempts()
        lastAttempt.removeAll()
        checkTask?.cancel()
        checkTask = nil
        check()
    }

    func check() {
        guard checkTask == nil else { return }
        checkTask = Task { [weak self] in
            // Let routes and mount notifications settle; coalesce bursts into one check.
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self else { return }
            await self.refresh()
            guard !Task.isCancelled else { return }
            let ssid = self.usesWiFi ? CWWiFiClient.shared().interface()?.ssid() : nil
            if self.connected && Self.permitsRecovery(usesWiFi: self.usesWiFi, ssid: ssid, homeSSID: self.homeSSID) {
                let urls = await self.targets()
                guard !Task.isCancelled else { return }
                let wanted = Set(urls)
                for url in Array(self.attempts.keys) where !wanted.contains(url) { self.finish(url) }
                for url in urls where self.attempts[url] == nil {
                    guard Date().timeIntervalSince(self.lastAttempt[url] ?? .distantPast) >= 60 else { continue }
                    // Bound simultaneous requests even with many disconnected shares.
                    guard self.attempts.count < 2 else { break }
                    self.lastAttempt[url] = Date()
                    guard await NASReachability().check(url), !Task.isCancelled else {
                        if Task.isCancelled { return }
                        continue
                    }
                    let worker = NASMountWorker()
                    self.attempts[url] = worker
                    worker.connect(url: url, silently: true) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self, self.attempts[url] === worker else { return }
                            self.finish(url)
                            self.check()
                        }
                    }
                    self.deadlines[url] = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(20)) } catch { return }
                        self?.finish(url)
                    }
                }
            }
            self.checkTask = nil
        }
    }

    static func permitsRecovery(usesWiFi: Bool, ssid: String?, homeSSID: String) -> Bool {
        // macOS can redact the SSID. A bounded server probe remains required in that case.
        !usesWiFi || ssid == nil || ssid == homeSSID
    }

    private func finish(_ url: URL) {
        deadlines.removeValue(forKey: url)?.cancel()
        attempts.removeValue(forKey: url)?.cancel()
    }

    private func cancelAttempts() {
        for task in deadlines.values { task.cancel() }
        deadlines.removeAll()
        for worker in attempts.values { worker.cancel() }
        attempts.removeAll()
    }

    deinit {
        monitor.cancel()
        timer?.cancel()
        checkTask?.cancel()
        for task in deadlines.values { task.cancel() }
        for worker in attempts.values { worker.cancel() }
    }
}

@MainActor
private final class NASReachability {
    private var connection: NWConnection?
    private var deadline: Task<Void, Never>?
    private var continuation: CheckedContinuation<Bool, Never>?

    func check(_ url: URL) async -> Bool {
        guard let rawHost = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 445)) else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
                self.connection = connection
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor [weak self] in
                        switch state {
                        case .ready: self?.finish(true)
                        case .failed, .cancelled: self?.finish(false)
                        default: break
                        }
                    }
                }
                connection.start(queue: DispatchQueue(label: "local.findanything.nas-probe"))
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    self?.finish(false)
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(false) }
        }
    }

    private func finish(_ reachable: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel()
        deadline = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        continuation.resume(returning: reachable)
    }
}
