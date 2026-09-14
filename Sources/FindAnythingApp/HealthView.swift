import FindAnythingCore
import SwiftUI

struct HealthView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionEyebrow(text: "Library status")
                        Text("Know what’s searchable.").font(.system(size: 32, design: .serif))
                        Text("Coverage, availability, and the work still ahead.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.scanAll() } label: { Label("Reconcile all", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(QuietButtonStyle()).disabled(model.sources.isEmpty).padding(.top, 10)
                }
                HStack(spacing: 15) {
                    statistic("Files cataloged", value: model.statistics.files.formatted(), symbol: "doc.on.doc")
                    statistic("Readable passages", value: model.statistics.passages.formatted(), symbol: "text.quote")
                    statistic("Local index", value: ByteCountFormatter.string(fromByteCount: model.statistics.databaseBytes, countStyle: .file), symbol: "internaldrive")
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Search engine", systemImage: "sparkle.magnifyingglass").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(model.statistics.semanticAvailable ? "Local semantic model ready" : "Exact text search ready")
                            .font(.system(size: 11)).foregroundStyle(Palette.accent)
                    }
                    Text(model.statistics.modelDescription.isEmpty ? "The catalog and keyword index live on this Mac. Semantic matching is available when a supported local embedding model is installed." : model.statistics.modelDescription)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                    Text("\(model.statistics.vectors.formatted()) passage vectors · Reconciliation runs every 15 minutes while the app is open.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(20).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))

                if let progress = model.progress {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(progress.phase).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Button("Stop") { model.stopIndexing() }.buttonStyle(QuietButtonStyle())
                        }
                        Text("\(progress.processed.formatted()) processed · \(progress.discovered.formatted()) discovered")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(progress.currentPath).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }.padding(20).background(Palette.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                }

                HStack { SectionEyebrow(text: "Selected sources"); Spacer(); Button("Add Source…") { model.chooseSources() }.buttonStyle(.link).disabled(!model.ready) }
                if model.sources.isEmpty {
                    Text("Your library starts with the folders you choose. Add a source to see its indexing coverage here.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 20)
                }
                ForEach(model.sources) { source in sourceCard(source) }
                VStack(alignment: .leading, spacing: 10) {
                    Label("Local, explicit, and transparent", systemImage: "lock.shield").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent)
                    Text("Original files stay in place. A disconnected source keeps its local index. Offline results reflect the last confirmed access state; remote permission changes are checked when the source is reachable. You control cached content separately for each source.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                }.padding(.top, 10)
            }.padding(36).padding(.top, 10)
        }.background(Palette.canvas)
    }

    private func statistic(_ label: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text(label).font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Image(systemName: symbol).foregroundStyle(Palette.accent) }
            Text(value).font(.system(size: 28, weight: .regular, design: .rounded)).monospacedDigit()
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
    }

    private func sourceCard(_ source: SourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: source.kind == .network ? "network" : "folder").font(.system(size: 23, weight: .light)).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(source.name).font(.system(size: 15, weight: .semibold))
                    Text(source.path).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Label(source.availability.rawValue.capitalized, systemImage: source.availability == .offline ? "wifi.slash" : "circle.fill")
                    .font(.system(size: 10)).foregroundStyle(statusColor(source.availability))
                Menu {
                    Button("Reconcile Now") { model.reconcileSource(source.id) }
                    Button("Verify All File Contents") { model.reconcileSource(source.id, verifyAll: true) }
                    Button(source.availability == .paused ? "Resume Indexing" : "Pause Indexing") { model.togglePause(source) }
                    Divider()
                    Button("Settings…") { model.settingsSource = source }
                    Button("Remove Source…", role: .destructive) { model.sourceToRemove = source }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(source.name)")
            }
            if source.fileCount > 0 {
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        Rectangle().fill(Palette.accent).frame(width: max(0, geometry.size.width * Double(source.indexedCount) / Double(max(source.fileCount, 1))))
                        Rectangle().fill(Palette.accent.opacity(0.12))
                    }.clipShape(Capsule())
                }.frame(height: 4)
            }
            HStack(spacing: 20) {
                coverage("Indexed", source.indexedCount, color: Palette.accent)
                coverage("Pending", source.pendingCount, color: .secondary)
                coverage("Unsupported", source.unsupportedCount, color: .secondary)
                coverage("Failed", source.failedCount, color: source.failedCount > 0 ? .orange : .secondary)
                Spacer()
            }
            Divider()
            HStack {
                Text(source.lastScan.map { "Last successful scan " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "No completed scan yet")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Settings") { model.settingsSource = source }.font(.system(size: 11)).buttonStyle(.link)
            }
            if let error = source.lastError { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange).lineSpacing(3) }
        }.padding(22).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
    }

    private func coverage(_ label: String, _ count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(count.formatted()).font(.system(size: 18, design: .rounded)).foregroundStyle(color)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct SourceSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var source: SourceRecord
    @State private var exclusions = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 7) {
                SectionEyebrow(text: "Source settings")
                Text(source.name).font(.system(size: 26, design: .serif))
                Text(source.path).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Form {
                TextField("Display name", text: $source.name)
                Toggle("Extract text from scans and images", isOn: $source.ocrEnabled)
                Toggle("Show cached passages while offline", isOn: $source.allowsOfflineContent)
            }.formStyle(.grouped).scrollDisabled(true).frame(height: 160)

            VStack(alignment: .leading, spacing: 8) {
                Text("Excluded names and paths").font(.system(size: 12, weight: .semibold))
                Text("One folder name or relative path per line. Changes take effect during the next reconciliation.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextEditor(text: $exclusions).font(.system(size: 11, design: .monospaced)).frame(height: 105)
                    .padding(6).background(Palette.paper, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line)).accessibilityLabel("Excluded folder names and relative paths")
            }
            Text("Offline access reflects the last confirmed permissions. Permission changes on a disconnected share cannot be detected until it reconnects. Turning off cached passages keeps offline filename and path results available.")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
            HStack {
                Button("Remove Source…", role: .destructive) { dismiss(); model.sourceToRemove = source }.buttonStyle(.link)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Settings") {
                    saving = true
                    source.exclusions = exclusions.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    Task { await model.save(source); dismiss() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(source.name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }.padding(30).frame(width: 510).background(Palette.canvas)
            .onAppear { exclusions = source.exclusions.joined(separator: "\n") }
    }
}
