import SwiftUI
import UniformTypeIdentifiers
import NovaSwiftKit

/// Plug-in hub: an "Installed" manager (enable/disable/delete what's on
/// device) and a "Store" tab (browse/search/install the bundled catalog —
/// see `app/NovaSwift/Store/PluginStoreView.swift`). This is the mobile answer to
/// drop-in plug-in folders (see docs/MOBILE_AND_PLUGINS.md §3).
struct PluginsView: View {
    @EnvironmentObject private var model: AppModel
    /// Closes this dialog (injected by the full-screen overlay presenter).
    var onClose: () -> Void = {}
    @State private var tab: Tab = .installed
    @State private var showingImporter = false
    @State private var importMessage: String?

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
                    VStack(spacing: 0) {
                        importBar
                        installedList.novaHiddenScrollContentBackground()
                    }
                case .store:
                    NavigationStack { PluginStoreView() }
                }
            }
        }
        .novaFileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [.zip, .folder, .data],
                          allowsMultipleSelection: false,
                          onCompletion: handleImport)
        .alert("Import Plug-in", isPresented: Binding(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } }
        ), presenting: importMessage) { _ in
            Button("OK") { importMessage = nil }
        } message: { Text($0) }
    }

    /// A standing, obvious entry point for plug-ins that don't come from the
    /// Store — a total conversion downloaded from a fan site, a `.zip` a
    /// friend sent, or a loose `.rez`/`.ndat` dropped from the Finder.
    private var importBar: some View {
        Button {
            showingImporter = true
        } label: {
            Label("Import Plug-in or .zip…", systemImage: "square.and.arrow.down.on.square")
                .frame(maxWidth: .infinity)
        }
        .novaBorderedButton()
        .padding([.horizontal, .top])
        .padding(.bottom, 4)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let src = try result.get().first else { return }
            let id = try model.data.importPlugin(from: src)
            importMessage = "Imported \"\(id)\". Enable it below to use it."
        } catch {
            importMessage = "That didn't work — \(error.localizedDescription)"
        }
    }

    private var installedList: some View {
        List {
            if model.data.plugins.isEmpty {
                ContentUnavailableViewCompat(
                    title: "No plug-ins installed",
                    message: "Switch to Store to browse and install plug-ins, or use Import above for a .rez/.ndat/.zip you got elsewhere.")
            } else {
                Section(footer: Text("Total conversions replace the base scenario; small plug-ins can stack. When two plug-ins define the same thing, the one lower in this list wins — use the arrows to reorder. Changes apply next time you start a game.")) {
                    let plugins = model.data.plugins
                    ForEach(Array(plugins.enumerated()), id: \.element.id) { index, plugin in
                        row(plugin, index: index, count: plugins.count)
                    }
                }
            }
        }
    }

    private func row(_ plugin: PluginBundle, index: Int, count: Int) -> some View {
        let kind = plugin.kind == .unknown ? GameLibrary.classify(plugin) : plugin.kind
        let prebundled = model.data.isPrebundled(plugin)
        return HStack {
            // Load-order priority: lower in the list = applied later = wins a
            // same-resource conflict. Reordering is only meaningful between
            // enabled plug-ins, but we don't restrict the arrows to those —
            // disabled plug-ins keep a place in the persisted order too, so
            // re-enabling one later doesn't silently reset its priority.
            VStack(spacing: 2) {
                Button {
                    model.data.movePlugin(id: plugin.id, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0)
                Button {
                    model.data.movePlugin(id: plugin.id, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index == count - 1)
            }
            .buttonStyle(.novaPlain)
            .font(.caption)
            .foregroundStyle(.secondary)

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
                .buttonStyle(.novaPlain)
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
