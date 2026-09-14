import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class SearchRuntime: NSObject, ObservableObject, NSMenuDelegate {
    @Published private(set) var shortcutReady = false
    @Published private(set) var status = "Starting Quick Search…"
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginError: String?
    var openLibrary: (() -> Void)?

    private let model: AppModel
    private var quickSearch: QuickSearchController?
    private var shortcut: GlobalSearchShortcut?
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var loginMenuItem: NSMenuItem?
    private var setupWindow: NSWindow?
    private var activationTask: Task<Void, Never>?
    private var started = false

    init(model: AppModel) { self.model = model; super.init() }

    func start() {
        guard !started else { return }
        started = true
        let quickSearch = QuickSearchController(model: model)
        quickSearch.showLibrary = { [weak self] in self?.showLibrary() }
        self.quickSearch = quickSearch
        shortcut = GlobalSearchShortcut { [weak self] in self?.quickSearch?.toggle() }
        model.showQuickSearch = { [weak self] in self?.showSearch() }
        model.showShortcutSettings = { [weak self] in self?.showSetup() }
        makeStatusMenu()
        retryShortcut()
        refreshLoginStatus()
        activationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                guard !Task.isCancelled, let self else { return }
                self.retryShortcut()
            }
        }
    }

    func retryShortcut() {
        guard let shortcut else { return }
        let result = shortcut.register()
        shortcutReady = false
        switch shortcut.systemShortcutStatus() {
        case .conflict:
            status = "A macOS shortcut still uses Command–Space. Turn off Show Spotlight search in Keyboard Settings."
        case .unknown:
            status = "Could not verify the macOS shortcut settings. Check that Show Spotlight search is off, then try again."
        case .available:
            if result == noErr {
                shortcutReady = true
                status = "Command–Space opens Quick Search."
            } else if result == eventHotKeyExistsErr {
                status = "Command–Space is already used by another search shortcut."
            } else {
                status = "Command–Space could not be registered (\(result))."
            }
        }
        model.shortcutAvailable = shortcutReady
        model.shortcutStatus = status
        statusMenuItem?.title = shortcutReady ? "Command–Space is ready" : "Command–Space needs setup"
    }

    @objc func showSearch() { quickSearch?.show() }

    @objc func showLibrary() {
        quickSearch?.hide()
        openLibrary?()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSetup() {
        quickSearch?.hide()
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 340),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Quick Search Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ShortcutSetupView(runtime: self))
            window.center()
            setupWindow = window
        }
        refreshLoginStatus()
        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    func refreshLoginStatus() { loginEnabled = SMAppService.mainApp.status == .enabled }

    @objc func toggleLogin() {
        loginError = nil
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            refreshLoginStatus()
            if SMAppService.mainApp.status == .requiresApproval {
                loginError = "Approve Find Yoshi IT in System Settings → General → Login Items."
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { loginError = "Could not change launch at login. \(error.localizedDescription)" }
        if loginError != nil { showSetup() }
    }

    private func makeStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Find Yoshi IT Quick Search")
        item.button?.toolTip = "Find Yoshi IT · Command–Space"
        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return item
        }
        _ = add("Quick Search    ⌘ Space", #selector(showSearch))
        _ = add("Open Library", #selector(showLibrary))
        menu.addItem(.separator())
        statusMenuItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        if let statusMenuItem { menu.addItem(statusMenuItem) }
        _ = add("Quick Search Settings…", #selector(showSetup))
        loginMenuItem = add("Launch at Login", #selector(toggleLogin))
        menu.addItem(.separator())
        _ = add("Quit Find Yoshi IT", #selector(quit))
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        retryShortcut()
        refreshLoginStatus()
        loginMenuItem?.state = loginEnabled ? .on : .off
    }

    @objc private func quit() { NSApp.terminate(nil) }

    deinit { activationTask?.cancel() }
}

private struct ShortcutSetupView: View {
    @ObservedObject var runtime: SearchRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Quick Search", systemImage: "magnifyingglass").font(.system(size: 23, design: .serif))
            Text(runtime.status).font(.system(size: 13, weight: .medium)).foregroundStyle(runtime.shortcutReady ? Palette.accent : .primary)
            Text("If Spotlight opens instead, go to Keyboard Shortcuts → Spotlight and turn off Show Spotlight search. Close any other launcher using Command–Space, then try again.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Keyboard Settings…") { runtime.openKeyboardSettings() }
                Button("Try Again") { runtime.retryShortcut() }
            }
            Divider()
            Toggle("Launch Find Yoshi IT when I log in", isOn: Binding(get: { runtime.loginEnabled }, set: { _ in runtime.toggleLogin() }))
                .font(.system(size: 12))
            Text("Closing the library keeps Quick Search available. Use the menu bar icon to reopen the library or quit.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let error = runtime.loginError { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
        }.padding(26).frame(width: 510, alignment: .leading).background(Palette.canvas).tint(Palette.accent)
    }
}
