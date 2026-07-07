import SwiftUI
import EVNovaKit

/// Enable/disable the bundled + imported plug-in catalog. This is the mobile
/// answer to drop-in plug-in folders (see docs/MOBILE_AND_PLUGINS.md §3).
struct PluginsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if model.data.plugins.isEmpty {
                ContentUnavailableViewCompat(
                    title: "No plug-ins found",
                    message: "Bundled plug-ins appear here. You can also import a .rez/.ndat plug-in.")
            } else {
                Section(footer: Text("Total conversions replace the base scenario; small plug-ins can stack. Changes apply next time you start a game.")) {
                    ForEach(model.data.plugins) { plugin in
                        row(plugin)
                    }
                }
            }
        }
        .navigationTitle("Plug-ins")
        .toolbar { Button("Done") { dismiss() } }
    }

    private func row(_ plugin: PluginBundle) -> some View {
        let kind = plugin.kind == .unknown ? GameLibrary.classify(plugin) : plugin.kind
        return Toggle(isOn: Binding(
            get: { plugin.isEnabled },
            set: { model.data.setPlugin(plugin.id, enabled: $0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name).font(.headline)
                Text(kindLabel(kind)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func kindLabel(_ kind: PluginKind) -> String {
        switch kind {
        case .totalConversion: return "Total conversion"
        case .patch: return "Content patch"
        case .gameplay: return "Gameplay tweak"
        case .base: return "Base"
        case .unknown: return "Plug-in"
        }
    }
}

/// Minimal cross-version stand-in for ContentUnavailableView.
struct ContentUnavailableViewCompat: View {
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}
