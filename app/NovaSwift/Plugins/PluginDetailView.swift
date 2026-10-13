import SwiftUI
import NovaSwiftKit
import NovaSwiftPluginStore
#if os(macOS)
import AppKit
#endif

/// Everything about one catalog entry, and the controls to install, update,
/// enable, disable or delete it.
struct PluginDetailView: View {
    let entry: PluginCatalogEntry
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var showFiles = false
    @State private var confirmDelete = false

    private var installedBundles: [PluginBundle] {
        model.data.plugins.filter { $0.id == entry.id || $0.id.hasPrefix(entry.id + "/") }
    }
    private var status: PluginInstallStatus { model.store.status(for: entry) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                actions
                if !entry.screenshotURLs.isEmpty { screenshots }
                facts
                about
                compatibility
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .cursorScrollable()
        .sheet(isPresented: $showFiles) {
            PluginFilesView(entry: entry).environmentObject(model).cursorHost()
        }
        .novaAlert("Delete \(entry.name)?", isPresented: $confirmDelete,
                   message: "The plug-in's files are removed from this device. You can install it again later.",
                   buttons: [
                    .destructive("Delete") { model.store.delete(entry, data: model.data) },
                    .cancel("Cancel") {}
                   ])
    }

    // MARK: Sections

    private var tint: Color { entry.isTotalConversion ? pluginTCTint : pluginAccent }

    /// Hero banner: large icon, title, author and badges over procedural space art.
    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            PluginIconTile(entry: entry, size: 104)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.name).font(.largeTitle.weight(.bold)).lineLimit(3)
                Text("by \(entry.author)").font(.title3).foregroundStyle(.white.opacity(0.75))
                HStack(spacing: 6) {
                    PluginBadge(text: "v\(entry.version)", systemImage: "tag", color: .white)
                    if entry.isTotalConversion {
                        PluginBadge(text: "Total conversion", systemImage: "sparkles", color: pluginTCTint)
                    }
                    if case .updateAvailable(let from, _) = status {
                        PluginBadge(text: from.map { "Update from v\($0)" } ?? "Update available",
                                    systemImage: "arrow.triangle.2.circlepath", color: .orange)
                    } else if status.isInstalled {
                        PluginBadge(text: "Installed", systemImage: "checkmark", color: .green)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .background(PluginSpaceArt(tint: tint, seed: pluginArtSeed(entry.id)))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(tint.opacity(0.3)))
    }

    /// Get / Update / Cancel with progress, Delete, Show files, Show in Finder, Website, Source and the enable switch.
    @ViewBuilder private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let transfer = model.store.transfer(for: entry) {
                switch transfer {
                case .working(let p):
                    HStack(spacing: 12) {
                        PluginProgressBar(progress: p)
                        Button("Cancel", role: .cancel) { model.store.cancel(entry) }.novaBorderedButton()
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline).foregroundStyle(.orange)
                    Button("Try again") { model.store.install(entry, data: model.data) }.novaProminentButton()
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    actionRow
                    ScrollView(.horizontal, showsIndicators: false) { actionRow }.cursorScrollable()
                }
                if model.store.isOffline && !status.isInstalled {
                    Label("You're offline. Connect to download.", systemImage: "wifi.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if status.isInstalled { enableControl }
            }
        }
        .pluginCardSurface()
    }

    @ViewBuilder private var actionRow: some View {
        HStack(spacing: 10) {
                switch status {
                case .notInstalled:
                    Button { model.store.install(entry, data: model.data) } label: {
                        Label(entry.sizeBytes.map { "Get  \u{00B7}  \(formatPluginSize($0))" } ?? "Get",
                              systemImage: "arrow.down.circle.fill")
                    }.novaProminentButton().disabled(entry.downloadURLs.isEmpty || model.store.isOffline)
                case .updateAvailable:
                    Button { model.store.install(entry, data: model.data) } label: {
                        Label("Update to v\(entry.version)", systemImage: "arrow.triangle.2.circlepath")
                    }.novaProminentButton().disabled(model.store.isOffline)
                    manageButtons
                case .installed:
                    manageButtons
                }
                Spacer(minLength: 0)
                links
            }
    }

    @ViewBuilder private var manageButtons: some View {
        Button { showFiles = true } label: { Label("Show files", systemImage: "doc.on.doc") }.novaBorderedButton()
        #if os(macOS)
        if let bundle = installedBundles.first,
           let url = pluginRevealURL(bundle, pluginsRoot: model.data.importedPluginsDir) {
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                Label("Show in Finder", systemImage: "folder")
            }.novaBorderedButton()
        }
        #endif
        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            .novaBorderedButton()
    }

    @ViewBuilder private var enableControl: some View {
        if let bundle = installedBundles.first {
            if model.data.manualPluginOrder || bundle.isTotalConversion {
                Toggle(isOn: Binding(get: { bundle.isEnabled },
                                     set: { model.data.setPlugin(bundle.id, enabled: $0) })) {
                    Text(bundle.isTotalConversion ? "Play this total conversion" : "Enabled").font(.headline)
                }
                .cursorClickable { model.data.setPlugin(bundle.id, enabled: !bundle.isEnabled) }
                if bundle.isTotalConversion {
                    Text("Only one total conversion can be active. Turning this on turns the others off.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                PluginChip(text: "Loads automatically", symbol: "checkmark.circle", tint: .green)
                Text("This plug-in loads automatically with the others, in file-name order, as in the original game. Turn on Manual plug-in order in Settings to pick which ones load.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var screenshots: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(entry.screenshotURLs, id: \.self) { url in
                    RemoteImage(url: url, contentMode: .fit) {
                        RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.08))
                            .overlay(ProgressView())
                    }
                    .frame(height: 220)
                    .frame(minWidth: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .cursorScrollable()
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 10) {
            PluginSectionHeader(symbol: "book", title: "About")
            VStack(alignment: .leading, spacing: 10) {
                let long = entry.description.isEmpty ? entry.summary : entry.description
                if let attributed = try? AttributedString(
                    markdown: long, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                    Text(attributed)
                } else {
                    Text(long)
                }
                Label(entry.license.map { "License: \($0). NovaSwift links to the author's original download and does not host or redistribute the file." }
                      ?? "Fan-made plug-in. NovaSwift links to the author's original download and does not host or redistribute the file.",
                      systemImage: "doc.text")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .pluginCardSurface()
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 10) {
            PluginSectionHeader(symbol: "info.circle", title: "Details")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12, alignment: .top)], spacing: 12) {
                PluginFactTile(symbol: "tag", label: "Version", value: "v\(entry.version)")
                PluginFactTile(symbol: "person.circle", label: "Author", value: entry.author)
                PluginFactTile(symbol: entry.kind.symbolName, label: "Kind", value: entry.kind.label,
                               tint: entry.isTotalConversion ? pluginTCTint : pluginAccent)
                if let size = entry.sizeBytes {
                    PluginFactTile(symbol: "arrow.down.to.line", label: "Download size", value: formatPluginSize(size))
                }
                if let d = entry.updatedDate ?? entry.addedDate {
                    PluginFactTile(symbol: "calendar", label: entry.updatedDate == nil ? "Added" : "Updated", value: d)
                }
                PluginFactTile(symbol: "globe", label: "Downloads from", value: entry.downloadHost)
                if !entry.tags.isEmpty {
                    PluginFactTile(symbol: "square.stack.3d.up", label: "Tags", value: entry.tags.joined(separator: ", "))
                }
                if let license = entry.license {
                    PluginFactTile(symbol: "doc.plaintext", label: "License", value: license)
                }
            }
        }
    }

    private var compatibility: some View {
        VStack(alignment: .leading, spacing: 10) {
            PluginSectionHeader(symbol: "checkmark.seal.fill", title: "Compatibility")
            VStack(alignment: .leading, spacing: 8) {
                note("externaldrive.badge.person.crop", "Needs your own copy of EV Nova's game data. NovaSwift doesn't include it.")
                if entry.isTotalConversion {
                    note("sparkles", "A total conversion replaces the stock scenario. Only one can be played at a time.")
                }
                if let min = entry.minNovaSwiftVersion {
                    note("app.badge", "Needs NovaSwift \(min) or newer.")
                }
                ForEach(entry.dependencies, id: \.self) { dep in
                    let installed = model.store.installedVersions[dep] != nil
                    note(installed ? "checkmark.circle" : "arrow.down.circle",
                         "Requires \(model.store.entry(id: dep)?.name ?? dep)" + (installed ? " (installed)" : " (installed automatically)"))
                }
            }
            .pluginCardSurface()
        }
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
    }

    @ViewBuilder private var links: some View {
        #if !os(tvOS)
        if let url = entry.homepageURL {
            Button { openURL(url) } label: { Label("Website", systemImage: "safari") }.novaBorderedButton()
        }
        if let url = entry.sourceURL {
            Button { openURL(url) } label: { Label("Source", systemImage: "chevron.left.forwardslash.chevron.right") }
                .novaBorderedButton()
        }
        #endif
    }
}

/// The files an installed plug-in put on disk.
struct PluginFilesView: View {
    let entry: PluginCatalogEntry
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let files = PluginInstaller.files(id: entry.id, in: model.data.importedPluginsDir)
        VStack(spacing: 0) {
            HStack {
                Text("\(entry.name) files").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.novaBorderedButton()
            }.padding()
            List {
                if files.isEmpty {
                    Text("No files found on this device.").foregroundStyle(.secondary)
                }
                ForEach(files) { file in
                    HStack {
                        Text(file.path).font(.callout.monospaced()).lineLimit(2)
                        Spacer()
                        Text(formatPluginSize(file.size)).foregroundStyle(.secondary).font(.caption)
                    }
                }
            }
            .novaHiddenScrollContentBackground()
            .cursorScrollable()
        }
        .cursorCancel { dismiss() }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }
}
