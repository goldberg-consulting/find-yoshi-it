import AppKit
import SwiftUI

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var reopenLibrary: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { reopenLibrary?() }
        return true
    }
}

@main
@MainActor
struct FindAnythingApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @StateObject private var model: AppModel
    @StateObject private var runtime: SearchRuntime

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        _runtime = StateObject(wrappedValue: SearchRuntime(model: model))
    }

    var body: some Scene {
        Window("Find Yoshi IT", id: "library") {
            LibrarySceneView(runtime: runtime, delegate: delegate)
                .environmentObject(model)
                .frame(minWidth: 1020, minHeight: 660)
                .task { await model.start() }
        }
        .defaultSize(width: 1380, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Quick Search Settings…") { runtime.showSetup() }.keyboardShortcut(",")
                NetworkSettingsMenuButton()
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Source…") { model.chooseSources() }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(!model.ready)
                Button("Add Folder…") { model.chooseFolders() }.keyboardShortcut("o")
                Button("Connect to NAS…") { model.chooseSources() }.disabled(!model.ready)
            }
            CommandMenu("Library") {
                Button("Quick Search    ⌘ Space") { runtime.showSearch() }
                Button("Open Library") { runtime.showLibrary() }
                Divider()
                NetworkSettingsMenuButton()
                Button("Reconcile All Sources") { model.scanAll() }.disabled(model.sources.isEmpty)
                Button("Stop Indexing") { model.stopIndexing() }.disabled(!model.isIndexing)
                Divider()
                Button("Source Health") { model.showHealth = true }.keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
        Window("Home Network", id: "network-settings") {
            NetworkSettingsView().environmentObject(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

private struct LibrarySceneView: View {
    @Environment(\.openWindow) private var openWindow
    let runtime: SearchRuntime
    let delegate: ApplicationDelegate

    var body: some View {
        LibraryView().task {
            await Task.yield()
            runtime.openLibrary = { openWindow(id: "library") }
            delegate.reopenLibrary = { runtime.showLibrary() }
            runtime.start()
        }
    }
}

enum Palette {
    static let accent = Color(light: NSColor(red: 0.08, green: 0.40, blue: 0.37, alpha: 1), dark: NSColor(red: 0.39, green: 0.76, blue: 0.69, alpha: 1))
    static let canvas = Color(light: NSColor(red: 0.974, green: 0.973, blue: 0.959, alpha: 1), dark: NSColor(red: 0.105, green: 0.12, blue: 0.12, alpha: 1))
    static let sidebar = Color(light: NSColor(red: 0.939, green: 0.944, blue: 0.925, alpha: 1), dark: NSColor(red: 0.085, green: 0.10, blue: 0.10, alpha: 1))
    static let paper = Color(light: .white, dark: NSColor(red: 0.14, green: 0.155, blue: 0.155, alpha: 1))
    static let muted = Color.secondary
    static let line = Color.primary.opacity(0.09)
}

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebar().frame(width: 230)
            Divider()
            ZStack {
                HStack(spacing: 0) {
                    SearchPane(searchFocused: $searchFocused).frame(minWidth: 420, maxWidth: .infinity)
                    Divider()
                    ReaderView().frame(minWidth: 330, maxWidth: .infinity)
                }
                .opacity(model.showHealth ? 0 : 1)
                .allowsHitTesting(!model.showHealth)
                .accessibilityHidden(model.showHealth)

                HealthView().frame(minWidth: 750, maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(model.showHealth ? 1 : 0)
                    .allowsHitTesting(model.showHealth)
                    .accessibilityHidden(!model.showHealth)
            }
        }
        .background(Palette.canvas)
        .tint(Palette.accent)
        .onChange(of: model.query) { _, _ in model.scheduleSearch() }
        .onChange(of: model.mode) { _, _ in model.scheduleSearch(immediate: true) }
        .onChange(of: model.sourceID) { _, _ in model.scheduleSearch(immediate: true) }
        .onChange(of: model.fileType) { _, _ in model.scheduleSearch(immediate: true) }
        .onChange(of: model.dateFilter) { _, _ in model.scheduleSearch(immediate: true) }
        .onChange(of: model.selectedID) { _, _ in model.loadReader() }
        .sheet(item: $model.settingsSource) { source in SourceSettingsView(source: source) }
        .sheet(isPresented: $model.showAddSource, onDismiss: model.sourceChooserDismissed) { AddSourceView() }
        .alert("Library needs attention", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog("Remove \(model.sourceToRemove?.name ?? "source") from your library?", isPresented: Binding(get: { model.sourceToRemove != nil }, set: { if !$0 { model.sourceToRemove = nil } }), titleVisibility: .visible) {
            Button("Remove Source and Cached Content", role: .destructive) {
                if let source = model.sourceToRemove { model.remove(source) }
                model.sourceToRemove = nil
            }
        } message: { Text("Its local index and cached passages will be deleted. Original files stay in their current location.") }
        .background {
            Button("Focus Search") { model.showHealth = false; searchFocused = true }
                .keyboardShortcut("f").hidden().accessibilityHidden(true)
        }
    }
}

struct SectionEyebrow: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(1.5).foregroundStyle(.secondary) }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(configuration.isPressed ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

func fileSymbol(_ extensionName: String) -> String {
    switch extensionName.lowercased() {
    case "pdf": return "doc.richtext"
    case "md", "txt", "rtf": return "doc.text"
    case "xlsx", "xls", "csv", "tsv": return "tablecells"
    case "pptx", "ppt": return "rectangle.on.rectangle"
    case "jpg", "jpeg", "png", "heic", "tiff", "gif": return "photo"
    case "swift", "py", "js", "ts", "json", "html", "css": return "chevron.left.forwardslash.chevron.right"
    default: return "doc"
    }
}
