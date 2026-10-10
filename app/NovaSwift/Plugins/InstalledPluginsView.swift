import SwiftUI
import NovaSwiftKit
import NovaSwiftPluginStore

/// Files the game tried to load and couldn't, with the reason.
struct FailedPluginFilesSection: View {
    let failures: [PluginLoadFailure]

    var body: some View {
        if !failures.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Failed to load", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text("These files were skipped when the game data last loaded. The rest of the plug-ins are unaffected.")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(failures) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.fileName).font(.callout.weight(.semibold))
                        Text("in \(f.pluginID)").font(.caption).foregroundStyle(.secondary)
                        Text(f.message).font(.caption.monospaced()).foregroundStyle(.orange).textSelection()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }
}

private extension View {
    @ViewBuilder func textSelection() -> some View {
        #if os(tvOS)
        self
        #else
        self.textSelection(.enabled)
        #endif
    }
}

/// Everything on this device that the game can load: catalog installs, imports
/// and plug-ins bundled with the app. Enable/disable, update, delete.
struct InstalledPluginsView: View {
    @EnvironmentObject private var model: AppModel
    let onImport: () -> Void
    let onOpen: (PluginCatalogEntry) -> Void
    @State private var pendingDelete: PluginBundle?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FailedPluginFilesSection(failures: model.data.failedPluginFiles)
                if model.data.plugins.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "puzzlepiece.extension").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No plug-ins installed").font(.headline)
                        Text("Browse the catalog to install one, or import your own .rez, .ndat or .zip files.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        #if !os(tvOS)
                        Button("Import files...", action: onImport).novaBorderedButton()
                        #endif
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 50)
                } else {
                    ForEach(model.data.plugins.filter { !$0.isOptional }) { row($0) }
                    let optional = model.data.plugins.filter(\.isOptional)
                    if !optional.isEmpty {
                        Text("Optional extras inside plug-ins").font(.headline).padding(.top, 8)
                        ForEach(optional) { row($0) }
                    }
                }
                #if os(tvOS)
                TVPluginWebImport()
                #endif
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
        .alert("Delete \(pendingDelete?.name ?? "plug-in")?",
               isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { bundle in
            Button("Delete", role: .destructive) {
                model.data.deletePlugin(bundle)
                model.store.refresh(data: model.data)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("The plug-in's files are removed from this device.") }
    }

    private func catalogEntry(for bundle: PluginBundle) -> PluginCatalogEntry? {
        model.store.entry(id: bundle.id)
    }

    private func row(_ bundle: PluginBundle) -> some View {
        let entry = catalogEntry(for: bundle)
        let kind = bundle.kind == .unknown ? GameLibrary.classify(bundle) : bundle.kind
        let prebundled = model.data.isPrebundled(bundle)
        let canToggle = model.data.manualPluginOrder || bundle.isTotalConversion
        let update: Bool = {
            if let entry, case .updateAvailable = model.store.status(for: entry) { return true }
            return false
        }()
        return HStack(spacing: 12) {
            if let entry { PluginIconTile(entry: entry, size: 44) }
            else {
                Image(systemName: kind.symbolName).frame(width: 44, height: 44)
                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry?.name ?? bundle.name).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Text(kind.label).font(.caption).foregroundStyle(.secondary)
                    if bundle.isTotalConversion { PluginBadge(text: "Total conversion", color: .indigo) }
                    if prebundled { PluginBadge(text: "Built in") }
                    if entry == nil && !prebundled { PluginBadge(text: "Imported") }
                    if update { PluginBadge(text: "Update", systemImage: "arrow.triangle.2.circlepath", color: .orange) }
                }
            }
            Spacer(minLength: 8)
            if let entry {
                Button { onOpen(entry) } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.novaPlain).accessibilityLabel("Details")
            }
            if update, let entry {
                Button("Update") { model.store.install(entry, data: model.data) }.novaBorderedButton()
            }
            if !prebundled {
                Button { pendingDelete = bundle } label: { Image(systemName: "trash").foregroundStyle(.red) }
                    .buttonStyle(.novaPlain).accessibilityLabel("Delete")
            }
            if canToggle {
                Toggle("Enabled", isOn: Binding(get: { bundle.isEnabled },
                                                set: { model.data.setPlugin(bundle.id, enabled: $0) }))
                    .labelsHidden()
                    .cursorClickable { model.data.setPlugin(bundle.id, enabled: !bundle.isEnabled) }
            } else {
                Text("Loads automatically").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Load order: the order the game applies plug-ins in. Later wins.
struct LoadOrderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let plugins = model.data.plugins
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.data.manualPluginOrder
                     ? "You choose the order. When two plug-ins change the same thing, the one lower in this list wins. Changes apply next time you start a game."
                     : "This is the original game's order: every plug-in loads, sorted by file name, and when two change the same thing the later one wins. A total conversion replaces the stock scenario while it is switched on.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Toggle("Manual plug-in order", isOn: Binding(
                    get: { model.data.manualPluginOrder },
                    set: { model.data.setManualPluginOrder($0) }))
                    .cursorClickable { model.data.setManualPluginOrder(!model.data.manualPluginOrder) }
                if model.data.manualPluginOrder {
                    Text("Lets you reorder plug-ins and choose which ones load. This is an enhancement, not how the original worked.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if plugins.isEmpty {
                    Text("No plug-ins installed.").foregroundStyle(.secondary).padding(.vertical, 30)
                }
                ForEach(Array(plugins.enumerated()), id: \.element.id) { index, plugin in
                    HStack(spacing: 12) {
                        Text("\(index + 1)").font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plugin.name).font(.headline).lineLimit(1)
                            Text(plugin.isEnabled ? "Loads" : "Off").font(.caption)
                                .foregroundStyle(plugin.isEnabled ? Color.green : Color.secondary)
                        }
                        Spacer()
                        if plugin.isTotalConversion { PluginBadge(text: "Total conversion", color: .indigo) }
                        if model.data.manualPluginOrder {
                            Button { model.data.movePlugin(id: plugin.id, by: -1) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.novaPlain).disabled(index == 0).accessibilityLabel("Move up")
                            Button { model.data.movePlugin(id: plugin.id, by: 1) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.novaPlain).disabled(index == plugins.count - 1).accessibilityLabel("Move down")
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .opacity(plugin.isEnabled ? 1 : 0.6)
                }
                FailedPluginFilesSection(failures: model.data.failedPluginFiles)
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
    }
}

#if os(tvOS)
/// Apple TV has no file picker: receive plug-in files over local Wi-Fi.
struct TVPluginWebImport: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var server: WebImportServer

    init() {
        // Real destination is set in onAppear (needs the environment object).
        _server = StateObject(wrappedValue: WebImportServer(destinationDir: FileManager.default.temporaryDirectory))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add plug-ins from a computer").font(.headline)
            Text("Open this address in a browser on the same Wi-Fi and drop in .zip, .rez or .ndat files.")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(server.displayAddress ?? "Starting...").font(.title3.monospaced())
            if let last = server.receivedFiles.last {
                Label("\(server.receivedFiles.count) received, latest: \(last)", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear {
            server.setDestination(model.data.importedPluginsDir)
            server.unpackZipsAsPlugins = true
            server.onFileReceived = { model.data.reload() }
            server.start()
            model.webImportActive = true
        }
        .onDisappear {
            server.stop()
            model.webImportActive = false
        }
    }
}
#endif
