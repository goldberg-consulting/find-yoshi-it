import AppKit
import Combine
import FindAnythingCore

enum QuickSearchCategory: String, CaseIterable {
    case all, applications, documents, other

    var title: String {
        switch self {
        case .all: return "All"
        case .applications: return "Apps"
        case .documents: return "Documents"
        case .other: return "Other files"
        }
    }
    var shortcut: String {
        switch self {
        case .all: return "0"
        case .applications: return "1"
        case .documents: return "2"
        case .other: return "3"
        }
    }
    var fileCategory: FileSearchCategory {
        switch self {
        case .documents: return .documents
        case .other: return .other
        default: return .all
        }
    }
    var includesApplications: Bool { self == .all || self == .applications }
}

enum QuickSearchItem: Identifiable {
    case application(ApplicationRecord)
    case document(SearchResult)

    var id: String {
        switch self {
        case .application(let app): return "application:\(app.id)"
        case .document(let document): return "document:\(document.id)"
        }
    }
}

/// Keeps the launcher's application lookup independent of the document search queue.
@MainActor
final class QuickSearchModel: ObservableObject {
    @Published private(set) var query = ""
    @Published private(set) var category: QuickSearchCategory = .all
    @Published private(set) var applications: [ApplicationRecord] = []
    @Published private(set) var documents: [SearchResult] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var searchingDocuments = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var launching = false
    @Published private(set) var focusRequest = UUID()

    var dismiss: (() -> Void)?
    var openLibrary: (() -> Void)?

    private let library: AppModel
    typealias Opener = (QuickSearchItem, @escaping (Error?) -> Void) -> Void
    private let opener: Opener
    private var applicationTask: Task<Void, Never>?
    private var documentTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var revision = 0
    private var isVisible = false
    private var selectionWasMoved = false
    private var icons: [String: NSImage] = [:]

    private var catalogSubscription: AnyCancellable?

    init(library: AppModel, opener: Opener? = nil) {
        self.library = library
        self.opener = opener ?? Self.openSystemItem
        catalogSubscription = library.$applicationCatalogRevision.dropFirst().sink { [weak self] _ in
            guard let self, self.isVisible, !self.isEmptyQuery else { return }
            self.searchApplications(revision: self.revision)
        }
    }

    var items: [QuickSearchItem] {
        applications.map(QuickSearchItem.application) + documents.map(QuickSearchItem.document)
    }

    var isEmptyQuery: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func beginSession() {
        isVisible = true
        category = .all
        setQuery("")
        focusRequest = UUID()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.library.applications.refresh()
            guard !Task.isCancelled, self.isVisible, !self.isEmptyQuery else { return }
            self.searchApplications(revision: self.revision)
        }
    }

    func endSession() {
        isVisible = false
        revision += 1
        applicationTask?.cancel()
        documentTask?.cancel()
        refreshTask?.cancel()
    }

    func setCategory(_ value: QuickSearchCategory) {
        guard category != value else { return }
        category = value
        setQuery(query)
    }

    func setQuery(_ value: String) {
        revision += 1
        query = value
        errorMessage = nil
        applications = []
        documents = []
        selectedID = nil
        selectionWasMoved = false
        applicationTask?.cancel()
        documentTask?.cancel()
        searchingDocuments = !isEmptyQuery && category != .applications
        guard !isEmptyQuery else { return }
        searchApplications(revision: revision)
        guard category != .applications else { return }
        let requestedCategory = category.fileCategory
        let requestedQuery = query
        let requestedRevision = revision
        documentTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(220)) }
            catch { return }
            guard let self else { return }
            do {
                let results = try await self.library.quickSearchDocuments(requestedQuery, category: requestedCategory)
                guard !Task.isCancelled, self.isVisible, requestedRevision == self.revision else { return }
                self.documents = Array(results.prefix(12))
                self.searchingDocuments = false
                self.restoreSelection()
            } catch {
                guard !Task.isCancelled, self.isVisible, requestedRevision == self.revision else { return }
                self.searchingDocuments = false
                self.errorMessage = "Documents could not be searched. \(error.localizedDescription)"
            }
        }
    }

    func moveSelection(_ offset: Int) {
        let results = items
        guard !results.isEmpty else { return }
        selectionWasMoved = true
        let current = results.firstIndex { $0.id == selectedID } ?? (offset > 0 ? -1 : results.count)
        let next = min(max(current + offset, 0), results.count - 1)
        selectedID = results[next].id
    }

    func openSelection() {
        guard let item = items.first(where: { $0.id == selectedID }) ?? items.first else { return }
        open(item)
    }

    func open(_ item: QuickSearchItem) {
        guard !launching else { return }
        errorMessage = nil
        selectedID = item.id
        if case .document(let result) = item, result.availability == .offline {
            errorMessage = "\(result.sourceName) is offline. Reconnect it to open the original file."
            return
        }
        launching = true
        let requestedRevision = revision
        let openedQuery = query
        opener(item) { [weak self] error in
            guard let self else { return }
            self.launching = false
            if error == nil {
                let path: String
                switch item {
                case .application(let app): path = app.path
                case .document(let file): path = file.path
                }
                self.library.recordSuccessfulOpen(query: openedQuery, path: path)
            }
            guard self.isVisible, self.revision == requestedRevision else { return }
            if let error { self.errorMessage = "Could not open this item. \(error.localizedDescription)" }
            else { self.dismiss?() }
        }
    }

    private static func openSystemItem(_ item: QuickSearchItem, completion: @escaping (Error?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let handler: @Sendable (NSRunningApplication?, Error?) -> Void = { _, error in
            Task { @MainActor in completion(error) }
        }
        switch item {
        case .application(let app):
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: configuration, completionHandler: handler)
        case .document(let document):
            NSWorkspace.shared.open(URL(fileURLWithPath: document.path), configuration: configuration, completionHandler: handler)
        }
    }

    func applicationIcon(_ app: ApplicationRecord) -> NSImage? { icons[app.path] }

    private func searchApplications(revision requestedRevision: Int) {
        applicationTask?.cancel()
        guard category.includesApplications else { return }
        let requestedQuery = query
        applicationTask = Task { [weak self] in
            guard let self else { return }
            let results = await self.library.findApplications(requestedQuery, limit: 6)
            guard !Task.isCancelled, self.isVisible, requestedRevision == self.revision else { return }
            for app in results where self.icons[app.path] == nil {
                self.icons[app.path] = NSWorkspace.shared.icon(forFile: app.path)
            }
            self.applications = results
            if !self.selectionWasMoved { self.selectedID = self.items.first?.id }
            else { self.restoreSelection() }
        }
    }

    private func restoreSelection() {
        guard !items.contains(where: { $0.id == selectedID }) else { return }
        selectedID = items.first?.id
    }
}
