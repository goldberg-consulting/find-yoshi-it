import FindAnythingCore
import PDFKit
import SwiftUI

struct ReaderView: View {
    @EnvironmentObject private var model: AppModel
    @State private var previewMode = "passages"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionEyebrow(text: "Evidence & context")
                Spacer()
                Image(systemName: "sidebar.right").foregroundStyle(.tertiary)
            }.padding(.horizontal, 24).padding(.top, 48).padding(.bottom, 28)

            if let result = model.selectedResult {
                documentHeader(result)
                Divider().padding(.top, 20)
                if result.availability == .offline {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "wifi.slash")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Offline · cached evidence").fontWeight(.medium)
                            if let indexedAt = result.indexedAt { Text("Indexed \(indexedAt.formatted(date: .abbreviated, time: .shortened))") }
                        }
                    }.font(.system(size: 10)).foregroundStyle(.orange).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.07))
                }
                if result.isStale {
                    Label("This file changed since its last successful extraction.", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 10)).foregroundStyle(.orange).padding(12)
                }

                if result.fileExtension == "pdf", result.availability != .offline {
                    Picker("Preview", selection: $previewMode) {
                        Text("Passages").tag("passages")
                        Text("PDF page").tag("original")
                    }.pickerStyle(.segmented).controlSize(.small).padding(.horizontal, 24).padding(.top, 16)
                }

                if previewMode == "original", result.fileExtension == "pdf", result.availability != .offline {
                    PDFPagePreview(path: result.path, page: model.selectedPassage?.page)
                        .padding(.top, 16)
                } else {
                    passageReader(result)
                }
            } else {
                readerEmptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.paper)
        .onChange(of: model.selectedID) { _, _ in previewMode = "passages" }
    }

    private func documentHeader(_ result: SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: fileSymbol(result.fileExtension)).foregroundStyle(Palette.accent)
                Text(result.fileExtension.isEmpty ? "FILE" : result.fileExtension.uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Copy Full Path") { model.copy(result.path) }
                    if let passage = model.selectedPassage {
                        Button("Copy Passage with Citation") { model.copy("\(passage.text)\n\n\(result.filename), \(passage.location)\n\(result.path)") }
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Evidence actions")
            }
            Text(result.filename).font(.system(size: 22, weight: .regular, design: .serif)).lineLimit(3).textSelection(.enabled)
            Text(result.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            HStack(spacing: 8) {
                Button { model.open(result) } label: { Label("Open original", systemImage: "arrow.up.right.square").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(.borderedProminent)
                Button { model.reveal(result) } label: { Image(systemName: "folder").font(.system(size: 11)) }
                    .buttonStyle(.bordered).help("Reveal in Finder").accessibilityLabel("Reveal in Finder")
                Spacer()
            }.controlSize(.small).disabled(result.availability == .offline)
        }.padding(.horizontal, 24)
    }

    private func passageReader(_ result: SearchResult) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let detail = result.detail {
                        Label(detail, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                    }
                    if model.passages.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Source details").font(.system(size: 17, design: .serif))
                            Text(emptyPassageMessage(result)).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                            metadataRow("Content status", result.status.rawValue.capitalized)
                            metadataRow("Modified", result.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                            if let indexed = result.indexedAt { metadataRow("Indexed", indexed.formatted(date: .abbreviated, time: .shortened)) }
                        }
                    } else {
                        HStack {
                            SectionEyebrow(text: "Source passages")
                            Spacer()
                            Text("\(model.passages.count.formatted())").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        if model.passages.count == 300 {
                            Text("Preview shows up to 300 passages around the match.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        ForEach(model.passages) { passage in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Button {
                                        model.selectedPassageID = passage.id
                                        if result.fileExtension == "pdf", result.availability != .offline { previewMode = "original" }
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: "text.quote")
                                            Text(passage.location)
                                            if passage.page != nil, result.availability != .offline { Image(systemName: "arrow.up.right").font(.system(size: 8)) }
                                        }.font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.accent)
                                    }.buttonStyle(.plain).help("Show this source location")
                                    Spacer(minLength: 4)
                                    Button { model.copy("\(passage.text)\n\n\(result.filename), \(passage.location)\n\(result.path)") } label: {
                                        Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }.buttonStyle(.plain).accessibilityLabel("Copy passage with source citation")
                                }
                                Text(passage.text).font(.system(size: 12)).lineSpacing(6).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(15).background(model.selectedPassageID == passage.id ? Palette.accent.opacity(0.045) : Palette.canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(model.selectedPassageID == passage.id ? Palette.accent.opacity(0.2) : .clear))
                            .id(passage.id)
                        }
                    }

                    if !model.relatedResults.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Divider()
                            SectionEyebrow(text: "Related documents")
                            Text("Explore nearby ideas. These are suggestions, separate from your search evidence.")
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
                            ForEach(model.relatedResults.prefix(5)) { related in
                                Button { model.showRelated(related) } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: fileSymbol(related.fileExtension)).foregroundStyle(Palette.accent)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(related.filename).font(.system(size: 11, weight: .medium)).lineLimit(2)
                                            Text(related.sourceName).font(.system(size: 10)).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    Label("Evidence comes directly from your indexed files.", systemImage: "checkmark.seal")
                        .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 6)
                }.padding(24)
            }.onChange(of: model.selectedPassageID) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) } }
            }
        }
    }

    private var readerEmptyState: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Image(systemName: "doc.text").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(Palette.accent.opacity(0.65))
            Text("The answer is in\nthe details.").font(.system(size: 27, weight: .regular, design: .serif)).lineSpacing(3)
            Text("Select a result to read the original passage and see exactly where it came from.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
            Divider().padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 14) {
                readerBenefit("text.quote", "Passages with context")
                readerBenefit("mappin.and.ellipse", "Pages, headings, sheets, and cells")
                readerBenefit("arrow.up.right.square", "One click to the original")
            }
            Spacer()
            Text("YOUR FILES ARE THE SOURCE OF TRUTH")
                .font(.system(size: 8, weight: .medium)).tracking(1.1).foregroundStyle(.tertiary).padding(.bottom, 24)
        }.padding(.horizontal, 32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func readerBenefit(_ symbol: String, _ label: String) -> some View {
        Label(label, systemImage: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(label).foregroundStyle(.secondary); Spacer(); Text(value) }.font(.system(size: 10))
    }

    private func emptyPassageMessage(_ result: SearchResult) -> String {
        if result.availability == .offline && !result.offlineContentAllowed { return "This source is offline. Its settings allow matching file metadata only. Reconnect the source to read its content." }
        switch result.status {
        case .unsupported: return "This file is cataloged by name and path. Content extraction is not supported for this format yet."
        case .locked: return "This document is locked. Unlock the original and reconcile its source to index the content."
        case .denied: return "Access to this document was denied. Cached content is unavailable."
        case .failed: return "Content could not be extracted. The filename and source path remain available."
        case .needsOCR: return "This file needs optical character recognition. Enable OCR in its source settings and reconcile the source."
        case .queued: return "This file has been discovered. Its content is waiting to be indexed."
        default: return "No readable passages were found in this file. You can still open the original when its source is online."
        }
    }
}

struct PDFPagePreview: NSViewRepresentable {
    let path: String
    let page: Int?

    final class Coordinator { var path: String?; var page: Int? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .windowBackgroundColor
        view.setAccessibilityLabel("Original PDF document preview")
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.path != path {
            view.document = PDFDocument(url: URL(fileURLWithPath: path))
            context.coordinator.path = path
            context.coordinator.page = nil
        }
        if context.coordinator.page != page, let page, let target = view.document?.page(at: max(0, page - 1)) {
            view.go(to: target)
            context.coordinator.page = page
        }
    }
}
