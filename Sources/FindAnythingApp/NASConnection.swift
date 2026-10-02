import AppKit
import Combine
import FindAnythingCore
import Foundation
import NetFS

/// Connects through the macOS sign-in and share chooser, then lets the user select indexing scopes.
@MainActor
final class NASConnection: ObservableObject {
    @Published var address: String
    @Published private(set) var isConnecting = false
    @Published private(set) var message: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var mountedShares: [MountedNetworkShare] = []
    @Published var selectedIDs: Set<String> = []

    var selectedShares: [MountedNetworkShare] {
        mountedShares.filter { selectedIDs.contains($0.id) }
    }

    private let worker = NASMountWorker()
    private var notificationTasks: [Task<Void, Never>] = []
    private var catalogTask: Task<Void, Never>?
    private var catalogGeneration = 0
    private var connectionGeneration = 0
    private var pendingSelectionPaths: Set<String> = []
    private var isStarted = false
    private static let savedAddressKey = "FindAnything.lastSMBServer"

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.savedAddressKey),
           let parsed = try? SMBAddress(saved) {
            address = parsed.url.absoluteString
        } else {
            address = ""
        }
    }

    /// Observe mount changes only while the source chooser is open.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        refreshShares()
        let center = NSWorkspace.shared.notificationCenter
        for notification in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            notificationTasks.append(Task { [weak self] in
                for await _ in center.notifications(named: notification) {
                    guard !Task.isCancelled else { return }
                    self?.refreshShares()
                }
            })
        }
    }

    /// Stop observing and cancel an unfinished connection without unmounting existing shares.
    func stop() {
        isStarted = false
        for task in notificationTasks { task.cancel() }
        notificationTasks.removeAll()
        catalogTask?.cancel()
        catalogTask = nil
        catalogGeneration += 1
        pendingSelectionPaths.removeAll()
        cancelConnection()
    }

    /// Pass a validated SMB address to macOS. Credentials stay in the system sign-in flow.
    func connect() {
        guard !isConnecting else { return }
        let server: SMBAddress
        do {
            server = try SMBAddress(address)
        } catch {
            errorMessage = error.localizedDescription
            message = nil
            return
        }
        connectionGeneration += 1
        let requested = connectionGeneration
        isConnecting = true
        errorMessage = nil
        message = "Use the macOS window to sign in and choose shares on \(server.host)."
        worker.connect(url: server.url) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.connectionGeneration == requested else { return }
                self.isConnecting = false
                switch result.status {
                case 0:
                    UserDefaults.standard.set(server.url.absoluteString, forKey: Self.savedAddressKey)
                    self.message = "Connected to \(server.host). Choose the shares to add below."
                    self.refreshShares(selectingPaths: result.paths)
                case -128, ECANCELED:
                    self.message = "Connection canceled."
                case EEXIST:
                    self.message = "This share is already connected. Choose it below."
                    self.refreshShares()
                default:
                    self.message = nil
                    self.errorMessage = Self.connectionError(status: result.status, host: server.host)
                    self.refreshShares()
                }
            }
        }
    }

    func cancelConnection() {
        connectionGeneration += 1
        worker.cancel()
        if isConnecting {
            message = "Connection canceled."
            isConnecting = false
        }
    }

    /// Read the cached mount table without contacting the servers or opening remote folders.
    func refreshShares() {
        refreshShares(selectingPaths: [])
    }

    private func refreshShares(selectingPaths: [String]) {
        pendingSelectionPaths.formUnion(selectingPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        catalogGeneration += 1
        let requested = catalogGeneration
        catalogTask?.cancel()
        catalogTask = Task { [weak self] in
            let shares = await Task.detached(priority: .utility) { MountedNetworkShare.mounted() }.value
            guard !Task.isCancelled, let self, self.catalogGeneration == requested else { return }
            self.mountedShares = shares
            let available = Set(shares.map(\.id))
            self.selectedIDs.formIntersection(available)
            let newlyMounted = shares.filter { self.pendingSelectionPaths.contains($0.path) }
            self.selectedIDs.formUnion(newlyMounted.map(\.id))
            self.pendingSelectionPaths.subtract(newlyMounted.map(\.path))
            self.catalogTask = nil
        }
    }

    private static func connectionError(status: Int32, host: String) -> String {
        switch status {
        case EACCES, EPERM, -5999, -6004:
            return "Access to \(host) was denied. Try again with an account that can open its shared folders."
        case -5998, -6003:
            return "No shared folders are available on \(host) for this account. Check the NAS sharing settings."
        case EHOSTUNREACH, ENETUNREACH, ETIMEDOUT, ECONNREFUSED, ENOENT:
            return "Could not reach \(host). Check the address and make sure the NAS is awake and connected to your network."
        case -5996, -5997:
            return "The server could not establish a supported SMB connection. Check its SMB and sign-in settings."
        case -5045, -5046:
            return "The server requires an account password change. Update it in the NAS settings, then connect again."
        default:
            return "Could not connect to \(host) (code \(status)). Check the server address, network connection, and account access, then try again."
        }
    }

    deinit {
        for task in notificationTasks { task.cancel() }
        catalogTask?.cancel()
        worker.cancel()
    }
}

struct NASMountResult: Sendable {
    let status: Int32
    let paths: [String]
}

/// NetFS requires a dispatch callback queue. Its request pointer stays confined to that queue.
final class NASMountWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.findanything.nas-connection", qos: .utility)
    private let lock = NSLock()
    private var generation = 0
    private var requestID: AsyncRequestID?

    func connect(url: URL, silently: Bool = false, completion: @escaping @Sendable (NASMountResult) -> Void) {
        lock.lock()
        generation += 1
        let requested = generation
        lock.unlock()
        queue.async { [self] in
            guard isCurrent(requested) else { return }
            cancelActiveRequest()
            var startedRequest: AsyncRequestID?
            let options = silently ? NSMutableDictionary(dictionary: [kNAUIOptionKey as String: kNAUIOptionNoUI as String]) : nil
            let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, options, nil,
                                           &startedRequest, queue) { [weak self] status, completedRequest, mountpoints in
                guard let self else { return }
                // A completion can already be queued when Cancel is clicked. Retire its
                // request before suppressing stale UI delivery; only pending requests may cancel.
                if self.requestID == completedRequest { self.requestID = nil }
                guard self.isCurrent(requested) else { return }
                completion(NASMountResult(status: status, paths: mountpoints as? [String] ?? []))
            }
            requestID = startedRequest
            guard isCurrent(requested) else {
                cancelActiveRequest()
                return
            }
            if status != 0 {
                cancelActiveRequest()
                completion(NASMountResult(status: status, paths: []))
            }
        }
    }

    func cancel() {
        lock.lock()
        generation += 1
        lock.unlock()
        // Retain the worker through queued teardown, including when its model is deallocated.
        queue.async { [self] in cancelActiveRequest() }
    }

    private func isCurrent(_ requested: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == requested
    }

    private func cancelActiveRequest() {
        if let requestID {
            NetFSMountURLCancel(requestID)
            self.requestID = nil
        }
    }
}
