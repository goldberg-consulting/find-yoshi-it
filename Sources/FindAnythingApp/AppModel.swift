import AppKit
import Combine
import FindAnythingCore
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var sources: [SourceRecord] = []
    @Published var statistics = IndexStatistics()
    @Published var query = ""
    @Published var mode: SearchMode = .names
    @Published var sourceID: String?
    @Published var fileType = ""
    @Published var dateFilter = "any"
    @Published var results: [SearchResult] = []
    @Published var selectedID: Int64?
    @Published var passages: [Passage] = []
    @Published var relatedResults: [SearchResult] = []
    @Published var selectedPassageID: Int64?
    @Published var showHealth = false
    @Published var isSearching = false
    @Published var searchStatus: String?
    @Published var progress: IndexProgress?
    @Published var queuedSources: [String] = []
    @Published var errorMessage: String?
    @Published var settingsSource: SourceRecord?
    @Published var sourceToRemove: SourceRecord?
    @Published var showAddSource = false
    @Published var ready = false
    @Published var applicationResults: [ApplicationRecord] = []
    @Published var shortcutAvailable = false
    @Published var shortcutStatus = "Starting Quick Search…"

    let applications: ApplicationCatalog
    private var searchHistory: SearchHistory?

    init(applications: ApplicationCatalog = ApplicationCatalog()) { self.applications = applications }
    @Published private(set) var applicationCatalogRevision = 0
    private var changeJournal: ChangeJournal?
    private var fullScanSources = Set<String>()
    private var volumeNotifications: AnyCancellable?
    var showQuickSearch: (() -> Void)?
    var showShortcutSettings: (() -> Void)?

    private var engine: SearchEngine?
    private var nameReader: SearchEngine?
    private var contentReader: SearchEngine?
    private var previewReader: SearchEngine?
    private var searchTask: Task<Void, Never>?
    private var applicationSearchTask: Task<Void, Never>?
    private var readerTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var searchRevision = 0
    private var didStart = false
    private var verificationSources = Set<String>()
    private var lastProgressRefresh = Date.distantPast
    private var lastProgressSearch = Date.distantPast
    private var dataDirectory: URL?
    private var watcher: SourceWatcher?
    private var folderPanel: NSOpenPanel?
    private var pendingFolderPicker = false
    private var pendingFolderURL: URL?

    var selectedResult: SearchResult? { results.first { $0.id == selectedID } }
    var scopedSource: SourceRecord? { sources.first { $0.id == sourceID } }
    var isIndexing: Bool { scanTask != nil }
    var selectedPassage: Passage? {
        passages.first { $0.id == selectedPassageID } ?? selectedResult?.passages.first ?? passages.first
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        Task { [weak self] in
            guard let self else { return }
            await self.applications.refresh()
            self.scheduleApplicationSearch()
        }
        do {
            let arguments = ProcessInfo.processInfo.arguments
            let directory: URL
            if let position = arguments.firstIndex(of: "--data-dir"), arguments.indices.contains(position + 1) {
                directory = URL(fileURLWithPath: arguments[position + 1], isDirectory: true)
            } else {
                directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("FindAnything", isDirectory: true)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            dataDirectory = directory
            searchHistory = try SearchHistory(url: directory.appendingPathComponent("SearchHistory.sqlite"))
            let journal = try ChangeJournal(url: directory.appendingPathComponent("Changes.sqlite"))
            changeJournal = journal
            watcher = SourceWatcher(journal: journal, onChange: { [weak self] key in
                self?.processChanges(key)
            }, onError: { [weak self] error in self?.errorMessage = error })
            let databaseURL = directory.appendingPathComponent("Library.sqlite")
            let writer = try await Task.detached(priority: .utility) { try SearchEngine(databaseURL: databaseURL) }.value
            engine = writer
            let revoke: @Sendable (Int64) -> Void = { fileID in
                Task { try? await writer.invalidateAccess(fileID: fileID) }
            }
            nameReader = try SearchEngine(databaseURL: databaseURL, readOnly: true, onAccessRevoked: revoke)
            contentReader = try SearchEngine(databaseURL: databaseURL, readOnly: true, onAccessRevoked: revoke)
            previewReader = try SearchEngine(databaseURL: databaseURL, readOnly: true, onAccessRevoked: revoke)
            if let position = arguments.firstIndex(of: "--search"), arguments.indices.contains(position + 1) {
                query = arguments[position + 1]
            }
            let prioritized = try await engine?.prioritizePersonalSources() ?? []
            await refresh(checkAvailability: true)
            ready = true
            for id in prioritized { enqueueScan(id) }
            let center = NSWorkspace.shared.notificationCenter
            volumeNotifications = center.publisher(for: NSWorkspace.didMountNotification)
                .merge(with: center.publisher(for: NSWorkspace.didUnmountNotification), center.publisher(for: NSWorkspace.didWakeNotification))
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.refresh(checkAvailability: true)
                        for source in self.sources where source.kind == .network && source.availability != .paused && source.availability != .offline {
                            self.enqueueScan(source.id)
                        }
                    }
                }
            if arguments.contains("--smoke-test") {
                let report: [String: Any] = [
                    "app": "Find Yoshi IT", "ready": true, "sourceCount": sources.count,
                    "semanticAvailable": statistics.semanticAvailable, "modelDescription": statistics.modelDescription,
                    "files": statistics.files, "passages": statistics.passages
                ]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: directory.appendingPathComponent("smoke-test.json"), options: .atomic)
            }
            for position in arguments.indices where arguments[position] == "--index-folder" && arguments.indices.contains(position + 1) {
                await add(url: URL(fileURLWithPath: arguments[position + 1], isDirectory: true))
            }
            // Network volumes have no reliable local replay log; reconcile immediately on reconnect/startup.
            for source in sources where source.kind == .network && source.availability != .paused && source.availability != .offline {
                enqueueScan(source.id)
            }
            scheduleSearch(immediate: true)
            reconciliationTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15 * 60)) } catch { return }
                    guard let self else { return }
                    await self.refresh(checkAvailability: true)
                    await self.applications.refresh(force: true)
                    self.applicationCatalogRevision += 1
                    self.scheduleApplicationSearch()
                    for source in self.sources where source.availability != .paused && source.availability != .offline {
                        self.enqueueScan(source.id)
                    }
                }
            }
        } catch { errorMessage = "The local library could not be opened. \(error.localizedDescription)" }
    }

    func refresh(checkAvailability: Bool = false) async {
        guard let engine else { return }
        do {
            if checkAvailability { try await engine.refreshAvailability() }
            let updated = try await engine.sources()
            let evidenceChanged = sources.map { "\($0.id)|\($0.availability)|\($0.allowsOfflineContent)|\($0.name)" } != updated.map { "\($0.id)|\($0.availability)|\($0.allowsOfflineContent)|\($0.name)" }
            sources = updated
            statistics = try await engine.statistics()
            watcher?.configure(sources: updated, indexDirectory: dataDirectory)
            if evidenceChanged && ready { scheduleSearch(immediate: true) }
        } catch { errorMessage = error.localizedDescription }
    }

    func chooseSources() {
        guard ready, folderPanel == nil, settingsSource == nil, !pendingFolderPicker else { return }
        showAddSource = true
    }

    func chooseFolders(at directory: URL? = nil) {
        guard ready, folderPanel == nil, settingsSource == nil, !pendingFolderPicker else { return }
        if showAddSource {
            pendingFolderPicker = true
            pendingFolderURL = directory
            showAddSource = false
            return
        }
        presentFolderPicker(at: directory)
    }

    func sourceChooserDismissed() {
        guard pendingFolderPicker else { return }
        let directory = pendingFolderURL
        pendingFolderPicker = false
        pendingFolderURL = nil
        // Present only after the SwiftUI sheet has finished dismissing.
        Task { @MainActor in
            await Task.yield()
            presentFolderPicker(at: directory)
        }
    }

    private func presentFolderPicker(at directory: URL?) {
        guard folderPanel == nil, !showAddSource, settingsSource == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose folders to search"
        panel.message = "Only selected folders are indexed. To connect a NAS first, use Add a source → Connect."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Library"
        panel.directoryURL = directory
        folderPanel = panel
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            let urls = response == .OK ? panel?.urls ?? [] : []
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.folderPanel = nil
                if let error = await self.addSources(urls) { self.errorMessage = error }
            }
        }
        if let window = NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func add(url: URL) async {
        if let error = await addSources([url]) { errorMessage = error }
    }

    func addSources(_ urls: [URL]) async -> String? {
        guard !urls.isEmpty else { return nil }
        guard let engine else { return "The library is still opening. Please try again in a moment." }
        var failures: [String] = []
        var added: [SourceRecord] = []
        for url in urls {
            do {
                try Task.checkCancellation()
                let source = try await engine.addSource(url: url)
                added.append(source)
            } catch is CancellationError {
                break
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        await finishAdding(added)
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func addNetworkSources(_ shares: [MountedNetworkShare]) async -> String? {
        guard let engine else { return "The library is still opening. Please try again in a moment." }
        var failures: [String] = []
        var added: [SourceRecord] = []
        for share in shares {
            do {
                try Task.checkCancellation()
                let source = try await engine.addSource(url: URL(fileURLWithPath: share.path, isDirectory: true), expectedNetworkShare: share)
                added.append(source)
            } catch is CancellationError {
                break
            } catch { failures.append("\(share.name): \(error.localizedDescription)") }
        }
        await finishAdding(added)
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    private func finishAdding(_ added: [SourceRecord]) async {
        guard let last = added.last else { return }
        await refresh()
        sourceID = last.id
        showHealth = false
        for source in added { enqueueScan(source.id) }
    }

    private func processChanges(_ key: String) {
        if key.hasPrefix(SourceWatcher.applicationPrefix) {
            Task { [weak self] in
                guard let self, let journal = self.changeJournal else { return }
                do {
                    guard let batch = try journal.pending(key: key) else { return }
                    await self.applications.refresh(force: true)
                    try journal.acknowledge(key: key, through: batch.through)
                    self.applicationCatalogRevision += 1
                    self.scheduleApplicationSearch()
                    if try journal.pending(key: key) != nil { self.processChanges(key) }
                } catch { self.errorMessage = error.localizedDescription }
            }
        } else {
            enqueueScan(key, changesOnly: true)
        }
    }

    func enqueueScan(_ id: String, verifyAll: Bool = false, changesOnly: Bool = false) {
        if !changesOnly { fullScanSources.insert(id) }
        if verifyAll { verificationSources.insert(id) }
        guard !queuedSources.contains(id) else { return }
        queuedSources.append(id)
        guard scanTask == nil else { return }
        scanTask = Task { [weak self] in
            guard let self, let engine = self.engine else { return }
            while !self.queuedSources.isEmpty && !Task.isCancelled {
                let next = self.queuedSources.removeFirst()
                self.progress = IndexProgress(sourceID: next, phase: "Preparing")
                do {
                    let verify = self.verificationSources.remove(next) != nil
                    let full = self.fullScanSources.remove(next) != nil
                    let batch = try self.changeJournal?.pending(key: next)
                    try await engine.scan(sourceID: next, verifyAll: verify, scopes: full ? (batch == nil ? nil : [""]) : batch?.scopes) { [weak self] update in
                        await self?.receive(update)
                    }
                    if let batch, try await engine.sources().first(where: { $0.id == next })?.availability == .online {
                        try self.changeJournal?.acknowledge(key: next, through: batch.through)
                    }
                } catch is CancellationError {
                    break
                } catch {
                    if !Task.isCancelled { self.errorMessage = error.localizedDescription }
                }
                await self.refresh()
                self.scheduleSearch(immediate: true)
            }
            self.progress = nil
            self.scanTask = nil
            await self.refresh()
            self.scheduleSearch(immediate: true)
            if !self.queuedSources.isEmpty {
                let pending = self.queuedSources
                self.queuedSources.removeAll()
                for id in pending { self.enqueueScan(id, verifyAll: self.verificationSources.contains(id)) }
            }
        }
    }

    private func receive(_ update: IndexProgress) async {
        progress = update
        if Date().timeIntervalSince(lastProgressRefresh) >= 1 {
            lastProgressRefresh = Date()
            await refresh()
        }
        if Date().timeIntervalSince(lastProgressSearch) >= 3 {
            lastProgressSearch = Date()
            scheduleSearch(immediate: true)
        }
    }

    func stopIndexing() {
        queuedSources.removeAll()
        verificationSources.removeAll()
        scanTask?.cancel()
    }

    func scanAll() {
        for source in sources where source.availability != .paused { enqueueScan(source.id) }
    }

    func reconcileSource(_ id: String, verifyAll: Bool = false) {
        Task {
            guard let engine else { return }
            do {
                try await engine.setSourcePaused(id: id, paused: false)
                await refresh()
                enqueueScan(id, verifyAll: verifyAll)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func togglePause(_ source: SourceRecord) {
        Task {
            guard let engine else { return }
            do {
                let paused = source.availability != .paused
                try await engine.setSourcePaused(id: source.id, paused: paused)
                if paused {
                    queuedSources.removeAll { $0 == source.id }
                    if progress?.sourceID == source.id { scanTask?.cancel() }
                }
                await refresh()
                if !paused { enqueueScan(source.id) }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func save(_ source: SourceRecord) async {
        guard let engine else { return }
        do {
            if !source.allowsOfflineContent || source.exclusions != sources.first(where: { $0.id == source.id })?.exclusions {
                readerTask?.cancel()
                results.removeAll { $0.sourceID == source.id }
                passages = []
                relatedResults = []
                selectedPassageID = nil
            }
            try await engine.updateSource(source)
            await refresh()
            scheduleSearch(immediate: true)
            enqueueScan(source.id)
        } catch { errorMessage = error.localizedDescription }
    }

    func remove(_ source: SourceRecord) {
        let activeScan = progress?.sourceID == source.id ? scanTask : nil
        if progress?.sourceID == source.id { stopIndexing() }
        queuedSources.removeAll { $0 == source.id }
        Task {
            guard let engine else { return }
            do {
                await activeScan?.value
                try await watcher?.forget(source.id)
                try await engine.removeSource(id: source.id)
                if sourceID == source.id { sourceID = nil }
                await refresh()
                scheduleSearch(immediate: true)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func scheduleSearch(immediate: Bool = false) {
        searchStatus = nil
        scheduleApplicationSearch()
        searchTask?.cancel()
        searchRevision += 1
        let revision = searchRevision
        searchTask = Task { [weak self] in
            guard let self, self.engine != nil else { return }
            if !immediate {
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            self.isSearching = true
            let after: Date?
            switch self.dateFilter {
            case "week": after = Calendar.current.date(byAdding: .day, value: -7, to: Date())
            case "month": after = Calendar.current.date(byAdding: .month, value: -1, to: Date())
            case "year": after = Calendar.current.date(byAdding: .year, value: -1, to: Date())
            default: after = nil
            }
            do {
                let request = SearchRequest(query: self.query, mode: self.mode, sourceID: self.sourceID, fileExtension: self.fileType.isEmpty ? nil : self.fileType, modifiedAfter: after)
                let found = self.fileType == "app" ? [] : try await self.searchFiles(request, onUpdate: { [weak self] partial in
                    guard let self, !Task.isCancelled, revision == self.searchRevision else { return }
                    self.results = partial
                    if !partial.contains(where: { $0.id == self.selectedID }) { self.selectedID = partial.first?.id }
                })
                guard !Task.isCancelled, revision == self.searchRevision else { return }
                let previousSelection = self.selectedID
                let ranked = (try? await self.searchHistory?.rank(found, query: request.query)) ?? found
                guard !Task.isCancelled, revision == self.searchRevision else { return }
                self.results = ranked
                if !found.contains(where: { $0.id == self.selectedID }) { self.selectedID = found.first?.id }
                if self.selectedID == previousSelection { self.loadReader() }
                self.isSearching = false
            } catch {
                guard !Task.isCancelled, revision == self.searchRevision else { return }
                self.isSearching = false
                if error is CancellationError { return }
                if error as? SearchInterruption == .timedOut {
                    self.searchStatus = "Content search took too long. Results may be incomplete. Narrow your search or press Return to retry."
                } else { self.errorMessage = error.localizedDescription }
            }
        }
    }

    private func scheduleApplicationSearch() {
        applicationSearchTask?.cancel()
        let query = query
        let scope = scopedSource?.path
        let includeApps = (fileType.isEmpty || fileType == "app") && dateFilter == "any"
        applicationSearchTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            if !includeApps || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.applicationResults = []
                return
            }
            let found = await self.findApplications(query, limit: scope == nil ? 8 : 50)
            guard !Task.isCancelled else { return }
            self.applicationResults = Array(found.filter { application in
                guard let scope else { return true }
                return application.path == scope || application.path.hasPrefix(scope == "/" ? "/" : scope + "/")
            }.prefix(8))
        }
    }

    func quickSearchDocuments(_ query: String, category: FileSearchCategory = .all, onUpdate: (([SearchResult]) -> Void)? = nil) async throws -> [SearchResult] {
        guard engine != nil, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        try Task.checkCancellation()
        let found = try await searchFiles(SearchRequest(query: query, mode: .names, limit: 60, category: category), onUpdate: onUpdate)
        let ranked = (try? await searchHistory?.rank(found, query: query)) ?? found
        try Task.checkCancellation()
        return Array(ranked.prefix(12))
    }

    private func searchFiles(_ request: SearchRequest, onUpdate: (([SearchResult]) -> Void)? = nil) async throws -> [SearchResult] {
        guard let nameReader, let contentReader else { return [] }
        let sources = sources
        let pipeline = FileSearchPipeline(
            names: { try await nameReader.search($0) },
            content: { try await contentReader.search($0) },
            metadata: { await MetadataFileSearch.search($0, sources: sources) }
        )
        return try await pipeline.search(request, onUpdate: onUpdate)
    }

    func findApplications(_ query: String, limit: Int = 6) async -> [ApplicationRecord] {
        let found = await applications.search(query, limit: 50)
        let ranked = (try? await searchHistory?.rank(found, query: query)) ?? found
        return Array(ranked.prefix(limit))
    }

    func recordSuccessfulOpen(query: String, path: String) {
        Task { try? await searchHistory?.record(query: query, path: path) }
    }

    func launchApplication(_ application: ApplicationRecord) {
        let openedQuery = query
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: application.path, isDirectory: true), configuration: configuration) { [weak self] _, error in
            Task { @MainActor [weak self] in
                if let error { self?.errorMessage = "Could not open \(application.name). \(error.localizedDescription)" }
                else { self?.recordSuccessfulOpen(query: openedQuery, path: application.path) }
            }
        }
    }

    func loadReader() {
        readerTask?.cancel()
        let result = selectedResult
        readerTask = Task { [weak self] in
            // Selection observers can run during SwiftUI's view update. Publish reader state
            // after that transaction, and only if this selection is still current.
            await Task.yield()
            guard !Task.isCancelled, let self, self.selectedResult == result else { return }
            self.passages = result?.passages ?? []
            self.relatedResults = []
            self.selectedPassageID = result?.passages.first?.id
            guard let result, let engine = self.previewReader else { return }
            do {
                let loaded = try await engine.preview(fileID: result.fileID, matchingPassageID: result.passages.first?.id)
                guard !Task.isCancelled, self.selectedResult == result else { return }
                self.passages = loaded
                if self.selectedPassageID == nil { self.selectedPassageID = loaded.first?.id }
                let related: [SearchResult]
                do { related = try await engine.related(fileID: result.fileID) }
                catch SearchInterruption.timedOut { return } // Optional suggestions must not block the preview.
                guard !Task.isCancelled, self.selectedResult == result else { return }
                self.relatedResults = related
            } catch {
                guard !Task.isCancelled, self.selectedResult == result else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func open(_ result: SearchResult) {
        guard result.availability != .offline, FileManager.default.fileExists(atPath: result.path) else { return }
        let openedQuery = query
        NSWorkspace.shared.open(URL(fileURLWithPath: result.path), configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            Task { @MainActor [weak self] in
                if let error { self?.errorMessage = error.localizedDescription }
                else { self?.recordSuccessfulOpen(query: openedQuery, path: result.path) }
            }
        }
    }

    func reveal(_ result: SearchResult) {
        guard result.availability != .offline, FileManager.default.fileExists(atPath: result.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.path)])
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func showRelated(_ result: SearchResult) {
        if !results.contains(where: { $0.id == result.id }) { results.append(result) }
        selectedID = result.id
    }
}
