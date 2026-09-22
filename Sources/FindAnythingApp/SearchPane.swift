import AppKit
import FindAnythingCore
import SwiftUI

struct SearchPane: View {
    @EnvironmentObject private var model: AppModel
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    SectionEyebrow(text: model.scopedSource?.kind == .network ? "Network library" : "Your library")
                    Text(model.scopedSource?.name ?? "Everything, within reach.")
                        .font(.system(size: 26, weight: .medium, design: .serif)).lineLimit(1)
                }
                Spacer()
                if let source = model.scopedSource {
                    Menu {
                        Button("Reconcile Now") { model.reconcileSource(source.id) }
                        Button("Verify All File Contents") { model.reconcileSource(source.id, verifyAll: true) }
                        Button("Source Settings…") { model.settingsSource = source }
                    } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Source actions")
                }
            }.padding(.top, 44).padding(.horizontal, 28).padding(.bottom, 22)

            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .regular)).foregroundStyle(Palette.accent)
                TextField("An app or document name…", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 15)).focused(searchFocused)
                    .onSubmit { model.scheduleSearch(immediate: true) }
                    .accessibilityLabel("Search your library")
                if model.isSearching {
                    ProgressView().controlSize(.small)
                } else if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                } else {
                    Text("⌘ F").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
            .padding(17).background(Palette.paper, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(searchFocused.wrappedValue ? Palette.accent.opacity(0.7) : Palette.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.025), radius: 5, y: 2)
            .padding(.horizontal, 28)

            if let status = model.searchStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 28).padding(.top, 8)
            }
            VStack(alignment: .leading, spacing: 10) {
                modePicker
                filterPickers
            }.padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 24)

            Divider().overlay(Palette.line)
            if model.sources.isEmpty && model.applicationResults.isEmpty {
                LibraryEmptyState()
            } else {
                HStack {
                    Text(model.query.isEmpty ? "RECENTLY INDEXED" : "SEARCH RESULTS")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.25).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.results.count.formatted()) files\(model.applicationResults.isEmpty ? "" : " · \(model.applicationResults.count) apps")\(model.results.count == 60 ? " · first 60" : "")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 12)

                if model.results.isEmpty && model.applicationResults.isEmpty {
                    SearchEmptyState()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if !model.applicationResults.isEmpty {
                                SectionEyebrow(text: "Applications").frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                                ForEach(model.applicationResults) { application in
                                    ApplicationResultCard(application: application)
                                }
                                if !model.results.isEmpty {
                                    SectionEyebrow(text: "Documents & other files").frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.top, 8)
                                }
                            }
                            ForEach(ResultGroup.make(model.results)) { group in
                                ResultGroupCard(group: group)
                            }
                        }.padding(.horizontal, 20).padding(.bottom, 24)
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "internaldrive").foregroundStyle(Palette.accent)
                Text("\(model.statistics.files.formatted()) files · \(model.statistics.passages.formatted()) passages")
                Spacer()
                Text(model.mode == .names ? "Name-first search" : model.mode == .exact ? "Exact search" : model.statistics.semanticAvailable ? "Local semantic search" : "Lexical search available")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.vertical, 13)
                .background(Palette.paper.opacity(0.55)).overlay(alignment: .top) { Divider() }
        }.frame(maxHeight: .infinity).background(Palette.canvas)
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(SearchMode.allCases, id: \.rawValue) { mode in
                Button { model.mode = mode } label: {
                    Text(mode.rawValue.capitalized)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(model.mode == mode ? Palette.accent : .secondary)
                        .frame(width: 76, height: 26)
                        .background(model.mode == mode ? Palette.paper : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(mode.rawValue.capitalized) search")
                .accessibilityIdentifier("search-mode-\(mode.rawValue)")
                .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(width: 316, height: 32)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search mode")
        .help("Names puts filename matches first, followed by matches inside documents. Hybrid, Exact, and Semantic also search contents across the library.")
    }

    private var filterPickers: some View {
        HStack(spacing: 10) {
            Picker("File type", selection: $model.fileType) {
                Text("All types").tag("")
                Text("Applications").tag("app")
                Text("PDF").tag("pdf")
                Text("Markdown").tag("md")
                Text("Text").tag("txt")
                Text("Word").tag("docx")
                Text("Excel").tag("xlsx")
                Text("PowerPoint").tag("pptx")
                Text("CSV").tag("csv")
                Text("PNG").tag("png")
                Text("JPEG").tag("jpg")
                Text("Swift").tag("swift")
                Text("Python").tag("py")
            }.labelsHidden().frame(width: 135, height: 26).accessibilityLabel("Filter by file type")
            Picker("Modified", selection: $model.dateFilter) {
                Text("Any time").tag("any")
                Text("Past week").tag("week")
                Text("Past month").tag("month")
                Text("Past year").tag("year")
            }.labelsHidden().frame(width: 135, height: 26).accessibilityLabel("Filter by modification date")
        }.controlSize(.small)
    }
}

private struct ApplicationResultCard: View {
    @EnvironmentObject private var model: AppModel
    let application: ApplicationRecord

    var body: some View {
        Button { model.launchApplication(application) } label: {
            HStack(spacing: 12) {
                Image(systemName: "app.dashed").font(.system(size: 24, weight: .light)).foregroundStyle(Palette.accent).frame(width: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text(application.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    Text(application.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Label("Open", systemImage: "arrow.up.right").font(.system(size: 11)).foregroundStyle(Palette.accent)
            }.padding(15).background(Palette.paper, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Open application \(application.name)")
    }
}

private struct ResultGroupCard: View {
    @EnvironmentObject private var model: AppModel
    let group: ResultGroup
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let representative = group.first
            ResultCard(result: representative, selected: representative.id == model.selectedID)
            if group.results.count > 1 {
                Button {
                    expanded.toggle()
                } label: {
                    Label("\(group.results.count) locations / versions", systemImage: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain).padding(.horizontal, 17)
                .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(group.first.filename), \(group.results.count) locations or versions")
                if expanded {
                    ForEach(group.results.filter { $0.path != representative.path }, id: \.path) { result in
                        ResultCard(result: result, selected: result.id == model.selectedID)
                            .padding(.leading, 18)
                    }
                }
            }
        }
    }
}

struct ResultCard: View {
    @EnvironmentObject private var model: AppModel
    let result: SearchResult
    let selected: Bool

    var body: some View {
        Button { model.selectedID = result.id } label: {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: fileSymbol(result.fileExtension)).font(.system(size: 18, weight: .light))
                        .foregroundStyle(Palette.accent).frame(width: 32, height: 34)
                        .background(Palette.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(result.filename).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        Text(result.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if selected { Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(Palette.accent).padding(.top, 4) }
                }
                if let passage = result.passages.first {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(highlighted(passage.text, query: model.query))
                            .font(.system(size: 12)).lineSpacing(4).foregroundStyle(.secondary).lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(passage.location).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.accent)
                    }.padding(.leading, 10).overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(Palette.accent.opacity(0.35)).frame(width: 2) }
                }
                HStack(spacing: 6) {
                    if result.availability == .offline {
                        Image(systemName: "wifi.slash").foregroundStyle(.orange)
                        Text("Offline\(result.indexedAt.map { " · indexed " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "")")
                    } else {
                        Text(result.sourceName).lineLimit(1)
                        Text("·")
                        Text(result.modifiedAt.formatted(date: .abbreviated, time: .omitted))
                    }
                    Spacer(minLength: 4)
                    Text(statusLabel).lineLimit(1).foregroundStyle(result.status == .indexed ? Palette.accent : .secondary)
                }.font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(17).background(selected ? Palette.paper : Palette.paper.opacity(0.40), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Palette.accent.opacity(0.48) : Palette.line.opacity(0.6), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).accessibilityLabel("\(result.filename), \(result.passages.first?.location ?? statusLabel), \(result.sourceName)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Open Original") { model.open(result) }.disabled(result.availability == .offline)
            Button("Reveal in Finder") { model.reveal(result) }.disabled(result.availability == .offline)
            Divider()
            Button("Copy Path") { model.copy(result.path) }
            if let passage = result.passages.first { Button("Copy Excerpt") { model.copy(passage.text) } }
        }
    }

    private var statusLabel: String {
        guard result.status != .indexed else { return result.matchKind }
        switch result.status {
        case .unsupported: return "Content unsupported"
        case .needsOCR: return "OCR pending"
        case .queued: return "Not yet indexed"
        default: return result.status.rawValue.capitalized
        }
    }
}

struct LibraryEmptyState: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 25)
            ZStack {
                Circle().fill(Palette.accent.opacity(0.055)).frame(width: 94, height: 94)
                Image(systemName: "magnifyingglass").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(Palette.accent)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Your apps and documents.\nWithin reach.")
                    .font(.system(size: 30, weight: .regular, design: .serif)).lineSpacing(3)
                Text("Search the words inside your documents, scans, and notes. Start with your NAS, a folder on your Mac, or an external drive.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            }
            Button { model.chooseSources() } label: {
                Label("Add your first source", systemImage: "plus").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 6)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.ready)
            VStack(alignment: .leading, spacing: 11) {
                capability("doc.text.viewfinder", "Find the passage, not just the filename")
                capability("network", "Keep your Mac and network files in one place")
                capability("lock", "Extraction and search stay on your Mac")
            }.padding(.top, 6)
            Spacer(minLength: 30)
        }.padding(.horizontal, 38).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    private func capability(_ symbol: String, _ title: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

struct SearchEmptyState: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: model.isIndexing ? "tray.and.arrow.down" : "magnifyingglass").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(Palette.accent)
            Text(model.isIndexing ? "Your library is taking shape." : model.query.isEmpty ? "No files here yet." : "No matching evidence found.")
                .font(.system(size: 22, design: .serif))
            Text(model.isIndexing ? "Files appear as indexing progresses. You can search while we work." : model.mode == .semantic && !model.statistics.semanticAvailable ? "Semantic matching is unavailable. Try Hybrid or Exact to search indexed words and filenames." : "Try a shorter phrase, a different search mode, or broader filters. Check source health for indexing coverage.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4).frame(maxWidth: 330)
            Button("View Source Health") { model.showHealth = true }.buttonStyle(QuietButtonStyle())
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
}

func highlighted(_ text: String, query: String) -> AttributedString {
    var value = AttributedString(String(text.prefix(1300)))
    let terms = query.split(whereSeparator: { $0.isWhitespace || $0 == "\"" }).map(String.init).filter { $0.count > 2 }
    for term in terms.prefix(12) {
        var cursor = value.startIndex
        while cursor < value.endIndex, let range = value[cursor...].range(of: term, options: .caseInsensitive) {
            value[range].foregroundColor = Palette.accent
            value[range].font = .system(size: 12, weight: .semibold)
            cursor = range.upperBound
        }
    }
    return value
}
