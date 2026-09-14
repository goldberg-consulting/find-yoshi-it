import FindAnythingCore
import SwiftUI

struct AddSourceView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var connection = NASConnection()
    @State private var isAdding = false
    @State private var addError: String?
    @State private var addTask: Task<Void, Never>?

    private var sharesToAdd: [MountedNetworkShare] {
        connection.selectedShares
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Add a source").font(.system(size: 27, design: .serif))
                Text("Connect your NAS or choose folders on this Mac. Add more places any time.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }.padding(24)

            HStack(spacing: 14) {
                Image(systemName: "folder.badge.plus").font(.system(size: 25, weight: .light)).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Folder or external drive").font(.system(size: 13, weight: .semibold))
                    Text("Select one or several folders.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose folders…") { model.chooseFolders() }
                    .disabled(connection.isConnecting || isAdding)
            }.padding(16).background(Palette.paper, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 24)

            Divider().padding(.horizontal, 24).padding(.vertical, 20)

            VStack(alignment: .leading, spacing: 10) {
                Label("NAS or shared Mac", systemImage: "network").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 10) {
                    TextField("Server address, such as smb://nas.local", text: $connection.address)
                        .textFieldStyle(.roundedBorder).controlSize(.large)
                        .accessibilityLabel("NAS server address")
                        .disabled(connection.isConnecting || isAdding)
                        .onSubmit { if !connection.isConnecting && !isAdding { connection.connect() } }
                    Button("Connect") { addError = nil; connection.connect() }
                        .controlSize(.large).disabled(connection.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connection.isConnecting || isAdding)
                }
                Text("macOS will ask you to sign in and choose shared folders.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 8) {
                    if connection.isConnecting { ProgressView().controlSize(.small) }
                    Text(addError ?? connection.errorMessage ?? connection.message ?? "Connect above, or select a share that is already connected below.")
                        .font(.system(size: 12)).foregroundStyle(addError != nil || connection.errorMessage != nil ? Color.red : .secondary)
                        .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    if connection.isConnecting {
                        Button("Cancel connection") { connection.cancelConnection() }.buttonStyle(.link)
                    }
                }.frame(height: 44, alignment: .top).padding(.top, 4)

                HStack {
                    SectionEyebrow(text: "Connected shares")
                    Spacer()
                    Button("Refresh") { connection.refreshShares() }.buttonStyle(.link).disabled(isAdding)
                }
            }.padding(.horizontal, 24)

            ScrollView {
                VStack(spacing: 8) {
                    if connection.mountedShares.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: "externaldrive.badge.wifi").font(.system(size: 24, weight: .light)).foregroundStyle(Palette.accent)
                            Text("No shares connected yet").font(.system(size: 13, weight: .medium))
                            Text("Your shared folders will appear here after you connect.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                    ForEach(connection.mountedShares) { share in
                        shareRow(share)
                    }
                }.padding(12)
            }
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 16)

            HStack(spacing: 12) {
                Text("Only the shares or folders you add will be indexed.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Button(isAdding ? "Cancel" : "Done") {
                    addTask?.cancel()
                    model.showAddSource = false
                }.keyboardShortcut(.cancelAction)
                Button(isAdding ? "Adding…" : sharesToAdd.count > 1 ? "Add \(sharesToAdd.count) shares" : "Add share") { addSelectedShares() }
                    .buttonStyle(.borderedProminent)
                    .disabled(sharesToAdd.isEmpty || connection.isConnecting || isAdding)
            }.padding(.horizontal, 24).padding(.bottom, 24)
        }
        .frame(width: 660, height: 650)
        .background(Palette.canvas).tint(Palette.accent)
        .task { connection.start() }
        .onDisappear { addTask?.cancel(); connection.stop() }
    }

    private func shareRow(_ share: MountedNetworkShare) -> some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { connection.selectedIDs.contains(share.id) }, set: { selected in
                if selected { connection.selectedIDs.insert(share.id) }
                else { connection.selectedIDs.remove(share.id) }
            })) { Text("Add \(share.name) on \(share.server)") }
                .labelsHidden().toggleStyle(.checkbox).disabled(connection.isConnecting || isAdding)
            VStack(alignment: .leading, spacing: 3) {
                Text(share.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(share.server).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Text(share.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Choose folders…") { model.chooseFolders(at: URL(fileURLWithPath: share.path, isDirectory: true)) }
                .buttonStyle(.link).font(.system(size: 11)).disabled(connection.isConnecting || isAdding)
                .accessibilityLabel("Choose folders inside \(share.name) on \(share.server)")
        }.padding(8)
    }

    private func addSelectedShares() {
        let selected = sharesToAdd
        guard !selected.isEmpty else { return }
        isAdding = true
        addError = nil
        addTask = Task { @MainActor in
            let error = await model.addNetworkSources(selected)
            guard !Task.isCancelled else { return }
            addError = error
            isAdding = false
            if addError == nil { model.showAddSource = false }
            else { connection.refreshShares() }
        }
    }
}
