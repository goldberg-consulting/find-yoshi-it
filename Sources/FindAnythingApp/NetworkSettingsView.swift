import Foundation
import SwiftUI

struct NetworkSettings {
    var defaults: UserDefaults = .standard
    private static let homeNetworkKey = "FindAnything.homeNetworkName"

    var homeNetworkName: String {
        defaults.string(forKey: Self.homeNetworkKey) ?? "Gondor"
    }

    @discardableResult
    mutating func saveHomeNetworkName(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        defaults.set(name, forKey: Self.homeNetworkKey)
        return true
    }
}

struct NetworkSettingsMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Home Network…") { openWindow(id: "network-settings") }
    }
}

struct NetworkSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Home network").font(.title2.weight(.semibold))
            Text("Automatically reconnect your saved NAS shares when you return home.")
                .foregroundStyle(.secondary)
            TextField("Home Wi-Fi name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            Text("Enter the Wi-Fi name exactly, including capitalization. On Ethernet, or when macOS hides the Wi-Fi name, Find Yoshi IT checks whether your saved NAS is reachable.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { name = model.homeNetworkName }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.saveHomeNetworkName(name)
        dismiss()
    }
}
