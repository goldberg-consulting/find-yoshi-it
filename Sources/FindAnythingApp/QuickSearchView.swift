import AppKit
import FindAnythingCore
import SwiftUI

struct QuickSearchView: View {
    @ObservedObject var model: QuickSearchModel
    let registerSearchField: (NSTextField) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .light)).foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                QuickSearchField(
                    text: model.query, registerSearchField: registerSearchField,
                    changed: model.setQuery, move: model.moveSelection,
                    submitted: model.openSelection, cancelled: { model.dismiss?() }
                )
                .frame(height: 42)
                if model.searchingDocuments {
                    ProgressView().controlSize(.small).accessibilityLabel("Searching documents")
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 17)
            HStack(spacing: 8) {
                ForEach(QuickSearchCategory.allCases, id: \.self) { category in
                    Button { model.setCategory(category) } label: {
                        HStack(spacing: 6) {
                            Text(category.title)
                            Text("⌘" + category.shortcut).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(model.category == category ? Palette.accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain).focusable(false)
                    .accessibilityLabel("\(category.title), Command \(category.shortcut)")
                    .accessibilityAddTraits(model.category == category ? .isSelected : [])
                }
                Spacer()
            }.padding(.horizontal, 20).padding(.bottom, 12)
            Divider()
            resultArea.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let status = model.searchStatus {
                Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 8)
            }
            if let error = model.errorMessage {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .accessibilityLabel("Search status: \(error)")
            }
            Divider()
            HStack(spacing: 14) {
                Text("↑ ↓ Select").accessibilityLabel("Use up and down arrow keys to select a result")
                Text("↩ Open").accessibilityLabel("Press Return to open the selected result")
                Text("esc Close").accessibilityLabel("Press Escape to close search")
                Spacer()
                Button("Open Library") { model.openLibrary?() }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent)
                    .accessibilityHint("Open the full Find Yoshi IT library window")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.vertical, 13)
        }
        .frame(width: 720, height: 510)
        .background(Palette.paper)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line, lineWidth: 1))
        .tint(Palette.accent)
    }

    @ViewBuilder
    private var resultArea: some View {
        if model.isEmptyQuery {
            VStack(spacing: 15) {
                Image(systemName: "command").font(.system(size: 35, weight: .ultraLight))
                    .foregroundStyle(Palette.accent).accessibilityHidden(true)
                Text("What are you looking for?").font(.system(size: 20, weight: .medium))
                Text(model.category == .applications ? "Type an application name." : model.category == .documents ? "Find a document by name or words inside it." : model.category == .other ? "Find code, images, and other files." : "Names appear first, followed by matches inside documents.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }.padding(24)
        } else if model.items.isEmpty {
            VStack(spacing: 10) {
                Text(model.searchingDocuments ? "Looking through your library…" : "No matches found")
                    .font(.system(size: 17, weight: .medium))
                Text(model.searchingDocuments ? "Applications appear as soon as they match." : "Try part of an app or filename. Open Library for broader content search.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }.padding(24)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if !model.applications.isEmpty {
                            sectionLabel("Applications")
                            ForEach(model.applications) { app in
                                resultRow(.application(app))
                            }
                        }
                        let documents = model.documents.filter { SearchPresentation.isDocument(extension: $0.fileExtension) }
                        let other = model.documents.filter { !SearchPresentation.isDocument(extension: $0.fileExtension) }
                        if !documents.isEmpty {
                            sectionLabel("Documents")
                            ForEach(documents) { document in resultRow(.document(document)) }
                        }
                        if !other.isEmpty {
                            sectionLabel("Other files")
                            ForEach(other) { document in resultRow(.document(document)) }
                        }
                    }.padding(.horizontal, 10).padding(.vertical, 8)
                }
                .onChange(of: model.selectedID) { _, selection in
                    guard let selection else { return }
                    proxy.scrollTo(selection)
                }
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1)
            .foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 5)
            .accessibilityAddTraits(.isHeader)
    }

    private func resultRow(_ item: QuickSearchItem) -> some View {
        Button { model.open(item) } label: {
            HStack(spacing: 12) {
                itemIcon(item).frame(width: 34, height: 34).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    switch item {
                    case .application(let app):
                        Text(app.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Text(app.path).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    case .document(let document):
                        HStack(spacing: 7) {
                            Text(document.filename).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            if document.availability == .offline {
                                Text("Offline").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        Text(document.path).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        if let passage = document.passages.first, !passage.text.isEmpty {
                            Text("\(passage.location) · \(passage.text)")
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if item.id == model.selectedID {
                    Image(systemName: "return").font(.system(size: 12)).foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(item.id == model.selectedID ? Palette.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(item))
        .accessibilityHint("Open this result")
        .accessibilityAddTraits(item.id == model.selectedID ? [.isSelected] : [])
        .id(item.id)
    }

    @ViewBuilder
    private func itemIcon(_ item: QuickSearchItem) -> some View {
        switch item {
        case .application(let app):
            if let icon = model.applicationIcon(app) {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "app").font(.system(size: 26)).foregroundStyle(Palette.accent)
            }
        case .document(let document):
            Image(systemName: fileSymbol(document.fileExtension)).font(.system(size: 25, weight: .light))
                .foregroundStyle(Palette.accent)
        }
    }

    private func accessibilityLabel(_ item: QuickSearchItem) -> String {
        switch item {
        case .application(let app): return "\(app.name), application, \(app.path)"
        case .document(let document):
            let passage = document.passages.first
            return "\(document.filename), \(document.sourceName), \(document.availability == .offline ? "offline, " : "")\(passage?.location ?? document.path)"
        }
    }
}

/// Uses the native field editor for text input and intercepts only launcher navigation keys.
private struct QuickSearchField: NSViewRepresentable {
    let text: String
    let registerSearchField: (NSTextField) -> Void
    let changed: (String) -> Void
    let move: (Int) -> Void
    let submitted: () -> Void
    let cancelled: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> QuickSearchTextField {
        let field = QuickSearchTextField()
        field.attachedToWindow = registerSearchField
        field.isBordered = false
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 25, weight: .regular)
        field.placeholderString = "Search apps and files"
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search apps and files")
        field.setAccessibilityIdentifier("quick-search-field")
        registerSearchField(field)
        return field
    }

    func updateNSView(_ field: QuickSearchTextField, context: Context) {
        context.coordinator.parent = self
        field.attachedToWindow = registerSearchField
        if field.stringValue != text { field.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QuickSearchField

        init(_ parent: QuickSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.changed(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch NSStringFromSelector(commandSelector) {
            case "moveDown:": parent.move(1)
            case "moveUp:": parent.move(-1)
            case "insertNewline:": parent.submitted()
            case "cancelOperation:": parent.cancelled()
            default: return false
            }
            return true
        }
    }
}

private final class QuickSearchTextField: NSTextField {
    var attachedToWindow: ((NSTextField) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { attachedToWindow?(self) }
    }
}
