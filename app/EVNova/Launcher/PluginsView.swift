import SwiftUI
import EVNovaKit

/// Plug-in hub: an "Installed" manager (enable/disable/delete what's on
/// device) and a "Store" tab (browse/search/install the bundled catalog —
/// see `app/EVNova/Store/PluginStoreView.swift`). This is the mobile answer to
/// drop-in plug-in folders (see docs/MOBILE_AND_PLUGINS.md §3).
struct PluginsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .installed

    private enum Tab: String, CaseIterable, Identifiable {
        case installed = "Installed", store = "Store"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])

            switch tab {
            case .installed: installedList
            case .store: PluginStoreView()
            }
        }
        .navigationTitle("Plug-ins")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private var installedList: some View {
        List {
            if model.data.plugins.isEmpty {
                ContentUnavailableViewCompat(
                    title: "No plug-ins installed",
                    message: "Switch to Store to browse and install plug-ins, or import a .rez/.ndat file.")
            } else {
                Section(footer: Text("Total conversions replace the base scenario; small plug-ins can stack. Changes apply next time you start a game.")) {
                    ForEach(model.data.plugins) { plugin in
                        row(plugin)
                    }
                }
            }
        }
    }

    private func row(_ plugin: PluginBundle) -> some View {
        let kind = plugin.kind == .unknown ? GameLibrary.classify(plugin) : plugin.kind
        let prebundled = model.data.isPrebundled(plugin)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name).font(.headline)
                Text(kind.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !prebundled {
                Button {
                    model.data.deletePlugin(plugin)
                } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            Toggle("", isOn: Binding(
                get: { plugin.isEnabled },
                set: { model.data.setPlugin(plugin.id, enabled: $0) }
            ))
            .labelsHidden()
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
