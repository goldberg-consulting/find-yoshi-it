import AppKit
import SwiftUI

/// Owns the reusable search panel and its keyboard focus without opening the library window.
@MainActor
final class QuickSearchController: NSObject, NSWindowDelegate {
    var showLibrary: (() -> Void)?

    private let state: QuickSearchModel
    private var panel: QuickSearchWindow?
    private weak var searchField: NSTextField?
    private var pendingFocusRequest: UUID?
    private var focusTask: Task<Void, Never>?

    init(model: AppModel) {
        state = QuickSearchModel(library: model)
        super.init()
        state.dismiss = { [weak self] in self?.hide() }
        state.openLibrary = { [weak self] in
            self?.hide()
            self?.showLibrary?()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: NSApp
        )
    }

    func toggle() {
        if panel?.isVisible == true { hide() }
        else { show() }
    }

    func show() {
        let window = searchWindow()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let x = frame.midX - window.frame.width / 2
            let y = max(frame.minY + 24, frame.maxY - window.frame.height - 100)
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        state.beginSession()
        pendingFocusRequest = UUID()
        searchField?.stringValue = state.query
        window.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        focusSearchFieldWhenReady()
    }

    func hide() {
        pendingFocusRequest = nil
        focusTask?.cancel()
        focusTask = nil
        state.endSession()
        panel?.orderOut(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        focusSearchFieldWhenReady()
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        guard pendingFocusRequest != nil, let panel, panel.isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
        focusSearchFieldWhenReady()
    }

    private func registerSearchField(_ field: NSTextField) {
        searchField = field
        focusSearchFieldWhenReady()
    }

    private func focusSearchFieldWhenReady() {
        guard let request = pendingFocusRequest else { return }
        focusTask?.cancel()
        focusTask = Task { @MainActor [weak self] in
            // Wait until AppKit has finished attaching the native field and activating its window.
            await Task.yield()
            guard !Task.isCancelled, let self, self.pendingFocusRequest == request,
                  let panel = self.panel, panel.isVisible, panel.isKeyWindow, NSApp.isActive,
                  let field = self.searchField, field.window === panel else { return }
            guard panel.makeFirstResponder(field) else { return }
            // Consume only a successful request. Attachment and activation callbacks retry failures.
            self.pendingFocusRequest = nil
            self.focusTask = nil
        }
    }

    private func searchWindow() -> QuickSearchWindow {
        if let panel { return panel }
        let window = QuickSearchWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 510),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.openSelected = { [weak self] in self?.state.openSelection() }
        window.selectCategory = { [weak self] category in self?.state.setCategory(category) }
        window.title = "Find Yoshi IT Search"
        window.setAccessibilityLabel("Find Yoshi IT Search")
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.delegate = self
        let content = NSHostingView(rootView: QuickSearchView(model: state, registerSearchField: { [weak self] field in
            self?.registerSearchField(field)
        }))
        content.sizingOptions = []
        window.contentView = content
        panel = window
        return window
    }
}

final class QuickSearchWindow: NSPanel {
    var selectCategory: ((QuickSearchCategory) -> Void)?
    var openSelected: (() -> Void)?

    func handleOpenKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
              event.keyCode == 36 || event.keyCode == 76,
              (firstResponder as? NSTextView)?.hasMarkedText() != true,
              let openSelected else { return false }
        if !event.isARepeat { openSelected() }
        return true
    }

    override func sendEvent(_ event: NSEvent) {
        if handleOpenKey(event) { return }
        super.sendEvent(event)
    }


    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == .command,
           let category = QuickSearchCategory.allCases.first(where: { $0.shortcut == event.charactersIgnoringModifiers }),
           let selectCategory {
            selectCategory(category)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
