import FindAnythingCore
import SwiftUI

struct LibrarySidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(Palette.accent).frame(width: 35, height: 35)
                    Image(systemName: "sparkle.magnifyingglass").font(.system(size: 20, weight: .medium)).foregroundStyle(Palette.paper)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Find Yoshi IT").font(.system(size: 15, weight: .semibold))
                    Text("Your knowledge, nearby.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.top, 44).padding(.bottom, 32)

            VStack(alignment: .leading, spacing: 6) {
                SectionEyebrow(text: "Library").padding(.horizontal, 12).padding(.bottom, 5)
                Button { model.showQuickSearch?() } label: {
                    HStack {
                        Label("Quick Search", systemImage: "magnifyingglass")
                        Spacer()
                        Text("⌘ Space").font(.system(size: 10))
                    }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 10)
                }.buttonStyle(.plain).help(model.shortcutStatus)
                if !model.shortcutAvailable {
                    Button("Set up Command–Space…") { model.showShortcutSettings?() }
                        .font(.system(size: 10)).buttonStyle(.link).padding(.horizontal, 12)
                }
                sidebarRow("All files", symbol: "square.stack.3d.up", selected: model.sourceID == nil && !model.showHealth, count: model.statistics.files) {
                    model.sourceID = nil; model.showHealth = false
                }
                sidebarRow("Source health", symbol: "waveform.path.ecg", selected: model.showHealth) { model.showHealth = true }
            }.padding(.horizontal, 10)

            HStack {
                SectionEyebrow(text: "Sources")
                Spacer()
                Button { model.chooseSources() } label: { Image(systemName: "plus").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(.plain).help("Add a folder, drive, NAS, or shared Mac").accessibilityLabel("Add source").disabled(!model.ready)
            }.padding(.horizontal, 22).padding(.top, 32).padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.sources) { source in
                        Button {
                            model.sourceID = source.id; model.showHealth = false
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: source.kind == .network ? "network" : source.kind == .external ? "externaldrive" : "folder")
                                    .font(.system(size: 14)).frame(width: 18).foregroundStyle(Palette.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    HStack(spacing: 4) {
                                        Circle().fill(statusColor(source.availability)).frame(width: 4, height: 4)
                                        Text(source.availability.rawValue.capitalized).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                Text(source.fileCount.formatted()).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 11).contentShape(Rectangle())
                            .background(model.sourceID == source.id && !model.showHealth ? Palette.paper : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(source.name), \(source.fileCount) files, \(source.availability.rawValue)")
                        .contextMenu {
                            Button("Reconcile Now") { model.reconcileSource(source.id) }
                            Button("Verify All File Contents") { model.reconcileSource(source.id, verifyAll: true) }
                            Button(source.availability == .paused ? "Resume Indexing" : "Pause Indexing") { model.togglePause(source) }
                            Divider()
                            Button("Source Settings…") { model.settingsSource = source }
                            Button("Remove Source…", role: .destructive) { model.sourceToRemove = source }
                        }
                    }
                    if model.sources.isEmpty {
                        Text("Choose the places you want to search. Your files stay where they are.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                }.padding(.horizontal, 10)
            }

            Button { model.chooseSources() } label: {
                Label("Add a source", systemImage: "plus").font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity)
            }.buttonStyle(QuietButtonStyle()).disabled(!model.ready).padding(.horizontal, 20).padding(.vertical, 16)

            Divider().overlay(Palette.line)
            VStack(alignment: .leading, spacing: 10) {
                if let progress = model.progress {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text(progress.phase).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer()
                        Button { model.stopIndexing() } label: { Image(systemName: "stop.circle") }
                            .buttonStyle(.plain).accessibilityLabel("Stop indexing").help("Stop indexing. Progress is retained.")
                    }
                    Text("\(progress.processed.formatted()) processed · \(progress.discovered.formatted()) discovered")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Label("Entirely on your Mac", systemImage: "lock.shield")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
                    Text("Private by design. Works offline.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
        .frame(maxHeight: .infinity).background(Palette.sidebar)
    }

    private func sidebarRow(_ title: String, symbol: String, selected: Bool, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                Spacer()
                if let count { Text(count.formatted()).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
                .foregroundStyle(selected ? Palette.accent : .primary)
                .background(selected ? Palette.paper : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

func statusColor(_ availability: SourceAvailability) -> Color {
    switch availability {
    case .online: return Palette.accent
    case .scanning: return .blue
    case .offline, .paused: return .orange
    case .error: return .red
    }
}
