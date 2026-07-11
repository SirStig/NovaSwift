import SwiftUI
import EVNovaKit

/// Plug-in hub: an "Installed" manager (enable/disable/delete what's on
/// device) and a "Store" tab (browse/search/install the bundled catalog —
/// see `app/EVNova/Store/PluginStoreView.swift`). This is the mobile answer to
/// drop-in plug-in folders (see docs/MOBILE_AND_PLUGINS.md §3).
struct PluginsView: View {
    @EnvironmentObject private var model: AppModel
    /// Closes this dialog (injected by the full-screen overlay presenter).
    var onClose: () -> Void = {}
    @State private var tab: Tab = .installed

    private enum Tab: String, CaseIterable, Identifiable {
        case installed = "Installed", store = "Store"
        var id: String { rawValue }
    }

    // The plug-in hub keeps its native list/search structure, but sits on the
    // same dimmed-title-screen surface as `NovaDialog` (via `DialogChrome`) so
    // it reads as part of the game's UI. The Store's detail pages and search
    // field need a `NavigationStack`, so its list/detail flow is wrapped in one
    // *inside* the chrome (the old macOS `.sheet` supplied that stack; the
    // full-screen overlay doesn't). No `.novaResponsive()` here — it scales
    // ambient text by window width, which at full-screen size blew every row up
    // ~1.6×; the List/Form controls want their own native point sizes.
    var body: some View {
        DialogChrome(title: "Plug-ins", onClose: onClose) {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])

                switch tab {
                case .installed:
                    installedList.scrollContentBackground(.hidden)
                case .store:
                    NavigationStack { PluginStoreView() }
                }
            }
        }
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
                Text(plugin.name).novaFont(.heading)
                Text(kind.label).novaFont(.caption).foregroundStyle(.secondary)
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
            Text(title).novaFont(.heading)
            Text(message).novaFont(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}
