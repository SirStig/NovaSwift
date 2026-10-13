import SwiftUI
import NovaSwiftKit
import NovaSwiftPluginStore
#if os(macOS)
import AppKit
#endif

/// Files the game tried to load and couldn't, with the reason.
struct FailedPluginFilesSection: View {
    let failures: [PluginLoadFailure]

    var body: some View {
        if !failures.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                PluginBanner(symbol: "exclamationmark.triangle.fill", tint: .orange,
                             title: "\(failures.count) file\(failures.count == 1 ? "" : "s") failed to load",
                             message: "These were skipped when the game data last loaded. The rest of the plug-ins are unaffected.")
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

/// Tile for a plug-in with no catalog entry: a symbol for its kind.
struct PluginKindTile: View {
    let kind: PluginKind
    var size: CGFloat = 48
    var body: some View {
        let tint: Color = kind == .totalConversion ? pluginTCTint : pluginAccent
        ZStack {
            LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: kind.symbolName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

/// Everything on this device that the game can load: catalog installs, imports
/// and plug-ins bundled with the app. Enable/disable, update, delete.
struct InstalledPluginsView: View {
    @EnvironmentObject private var model: AppModel
    let onImport: () -> Void
    let onOpen: (PluginCatalogEntry) -> Void
    var onBrowse: () -> Void = {}
    /// Bundle id whose Delete button was pressed once; the next press deletes.
    @State private var armedDelete: String?
    @State private var disarmTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                FailedPluginFilesSection(failures: model.data.failedPluginFiles)
                if model.data.plugins.isEmpty {
                    emptyState
                } else {
                    PluginSectionHeader(symbol: "tray.full", title: "Installed",
                                        note: "\(model.data.plugins.count) plug-in\(model.data.plugins.count == 1 ? "" : "s")")
                    if let tc = TCAddOns.selectedTC(model.data.plugins) { TCAddOnsSection(tc: tc) }
                    ForEach(model.data.plugins.filter { !$0.isOptional }) { row($0) }
                    let optional = model.data.plugins.filter(\.isOptional)
                    if !optional.isEmpty {
                        PluginSectionHeader(symbol: "square.stack.3d.up", title: "Optional extras inside plug-ins")
                        ForEach(optional) { row($0) }
                    }
                }
                #if os(tvOS)
                TVPluginWebImport()
                #endif
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
        .cursorScrollable()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            PluginEmptyIllustration(symbol: "tray")
            Text("No plug-ins installed").font(.headline)
            Text("Browse the catalog to install one, or import your own .rez, .ndat or .zip files.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                #if !os(tvOS)
                Button(action: onImport) { Label("Import files...", systemImage: "square.and.arrow.down.on.square") }
                    .novaBorderedButton()
                #endif
                Button(action: onBrowse) { Label("Browse plug-ins", systemImage: "icloud.and.arrow.down") }
                    .novaProminentButton()
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private func catalogEntry(for bundle: PluginBundle) -> PluginCatalogEntry? {
        model.store.entry(id: bundle.id)
    }

    /// First press arms (button turns into "Confirm"), second press within a few seconds deletes.
    private func pressDelete(_ bundle: PluginBundle) {
        if armedDelete == bundle.id {
            disarmTask?.cancel()
            armedDelete = nil
            model.data.deletePlugin(bundle)
            model.store.refresh(data: model.data)
        } else {
            armedDelete = bundle.id
            disarmTask?.cancel()
            disarmTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled { armedDelete = nil }
            }
        }
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
        let fileCount = bundle.allFileURLs.count
        let armed = armedDelete == bundle.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let entry { PluginIconTile(entry: entry, size: 48) } else { PluginKindTile(kind: kind, size: 48) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry?.name ?? bundle.name).font(.headline).lineLimit(1)
                    HStack(spacing: 6) {
                        PluginBadge(text: kind.label, color: bundle.isTotalConversion ? pluginTCTint : .secondary)
                        if prebundled { PluginBadge(text: "Built in", systemImage: "app.badge.checkmark") }
                        if entry == nil && !prebundled { PluginBadge(text: "Imported", systemImage: "square.and.arrow.down") }
                        if update { PluginBadge(text: "Update", systemImage: "arrow.triangle.2.circlepath", color: .orange) }
                    }
                    Label("\(pluginSourceFolderName(bundle)) \u{00B7} \(fileCount) file\(fileCount == 1 ? "" : "s")",
                          systemImage: "folder")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if canToggle {
                    Toggle("Enabled", isOn: Binding(get: { bundle.isEnabled },
                                                    set: { model.data.setPlugin(bundle.id, enabled: $0) }))
                        .labelsHidden()
                        .cursorClickable { model.data.setPlugin(bundle.id, enabled: !bundle.isEnabled) }
                } else if let tc = TCAddOns.selectedTC(model.data.plugins), !bundle.isTotalConversion {
                    // Original rule: a conversion ignores global plug-ins; add it to the conversion's list above.
                    PluginChip(text: "Not loaded under \(tc.name)", symbol: "minus.circle", tint: .secondary)
                } else {
                    PluginChip(text: "Loads automatically", symbol: "checkmark.circle", tint: .green)
                }
            }
            HStack(spacing: 8) {
                if update, let entry {
                    Button { model.store.install(entry, data: model.data) } label: {
                        Label("Update", systemImage: "arrow.triangle.2.circlepath")
                    }.novaProminentButton()
                }
                if let entry {
                    Button { onOpen(entry) } label: { Label("Details", systemImage: "info.circle") }
                        .novaBorderedButton()
                }
                #if os(macOS)
                if let url = pluginRevealURL(bundle, pluginsRoot: model.data.importedPluginsDir) {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }.novaBorderedButton()
                }
                #endif
                Spacer(minLength: 0)
                if !prebundled {
                    Button { pressDelete(bundle) } label: {
                        Label(armed ? "Press again to delete" : "Delete", systemImage: "trash")
                            .foregroundStyle(armed ? Color.white : Color.red)
                            .padding(.horizontal, armed ? 8 : 0)
                            .background(armed ? Color.red : Color.clear, in: Capsule())
                    }
                    .novaBorderedButton()
                    .accessibilityLabel(armed ? "Confirm delete" : "Delete")
                }
            }
        }
        .pluginCardSurface()
    }
}

/// Load order: the order the game applies plug-ins in. Later wins.
struct LoadOrderView: View {
    @EnvironmentObject private var model: AppModel
    @State private var dropTarget: String?

    var body: some View {
        let plugins = model.data.plugins
        let manual = model.data.manualPluginOrder
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PluginSectionHeader(symbol: "list.number", title: "Load order",
                                    note: "\(plugins.count) plug-in\(plugins.count == 1 ? "" : "s")")
                explanation(manual: manual)
                baseRow
                if plugins.isEmpty {
                    Text("No plug-ins installed.").foregroundStyle(.secondary).padding(.vertical, 30)
                        .frame(maxWidth: .infinity)
                }
                ForEach(Array(plugins.enumerated()), id: \.element.id) { index, plugin in
                    orderRow(index: index, plugin: plugin, count: plugins.count, manual: manual)
                }
                FailedPluginFilesSection(failures: model.data.failedPluginFiles)
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
        .cursorScrollable()
    }

    private func explanation(manual: Bool) -> some View {
        HStack(alignment: .center, spacing: 16) {
            PluginLayerDiagram()
            VStack(alignment: .leading, spacing: 8) {
                Text(manual ? "You choose the order" : "The original order").font(.headline)
                Text(manual
                     ? "When two plug-ins change the same thing, the one lower in this list wins. Drag the grip or use the arrows to reorder. Changes apply next time you start a game."
                     : "This is the original game's order: every plug-in loads, sorted by file name, and when two change the same thing the later one wins. A total conversion replaces the stock scenario while it is switched on.")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Toggle("Manual plug-in order", isOn: Binding(
                        get: { model.data.manualPluginOrder },
                        set: { model.data.setManualPluginOrder($0) }))
                        .font(.subheadline.weight(.semibold))
                        .cursorClickable { model.data.setManualPluginOrder(!model.data.manualPluginOrder) }
                    PluginChip(text: "Enhancement", symbol: "sparkles", tint: .cyan)
                }
                if manual {
                    Text("Lets you reorder plug-ins and choose which ones load. This is an enhancement, not how the original worked.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .pluginCardSurface()
    }

    private var baseRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
                .frame(width: 34, height: 34).background(Color.primary.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("EV Nova game data").font(.headline)
                Text("Always loads first").font(.caption).foregroundStyle(.secondary)
            }
            .opacity(0.8)
            Spacer()
            PluginChip(text: "Base", tint: .secondary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func orderRow(index: Int, plugin: PluginBundle, count: Int, manual: Bool) -> some View {
        let isTarget = dropTarget == plugin.id
        let row = HStack(spacing: 12) {
            if manual {
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).frame(width: 22)
                    .accessibilityHidden(true)
            }
            Text("\(index + 1)").font(.callout.monospacedDigit().weight(.bold))
                .foregroundStyle(pluginAccent)
                .frame(width: 34, height: 34).background(pluginAccent.opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill").font(.system(size: 7))
                        .foregroundStyle(plugin.isEnabled ? Color.green : Color.secondary)
                    Text(plugin.isEnabled ? "Loads" : "Off").font(.caption.weight(.medium))
                        .foregroundStyle(plugin.isEnabled ? Color.green : Color.secondary)
                    Text(plugin.kind == .unknown ? "Plug-in" : plugin.kind.label).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if plugin.isTotalConversion { PluginBadge(text: "Total conversion", systemImage: "sparkles", color: pluginTCTint) }
            if manual {
                Button { model.data.movePlugin(id: plugin.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.novaPlain).disabled(index == 0).accessibilityLabel("Move up")
                Button { model.data.movePlugin(id: plugin.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.novaPlain).disabled(index == count - 1).accessibilityLabel("Move down")
            }
        }
        .padding(12)
        .background(Color.primary.opacity(isTarget ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(isTarget ? pluginAccent : Color.clear, lineWidth: 2))
        .opacity(plugin.isEnabled ? 1 : 0.6)
        #if os(tvOS)
        row
        #else
        if manual {
            row
                .draggable(plugin.id)
                .dropDestination(for: String.self) { items, _ in
                    guard let dragged = items.first, dragged != plugin.id else { return false }
                    model.data.movePlugin(id: dragged, toIndex: index)
                    return true
                } isTargeted: { over in
                    if over { dropTarget = plugin.id } else if dropTarget == plugin.id { dropTarget = nil }
                }
        } else {
            row
        }
        #endif
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
