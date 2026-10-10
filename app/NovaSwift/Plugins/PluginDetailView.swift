import SwiftUI
import NovaSwiftKit
import NovaSwiftPluginStore

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
                about
                facts
                compatibility
                links
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showFiles) {
            PluginFilesView(entry: entry).environmentObject(model)
        }
        .alert("Delete \(entry.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.store.delete(entry, data: model.data) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The plug-in's files are removed from this device. You can install it again later.")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            PluginIconTile(entry: entry, size: 96)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.name).font(.largeTitle.weight(.bold)).lineLimit(3)
                Text("by \(entry.author)").font(.title3).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    PluginBadge(text: "v\(entry.version)")
                    if entry.isTotalConversion {
                        PluginBadge(text: "Total conversion", systemImage: "sparkles", color: .indigo)
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
    }

    @ViewBuilder private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let transfer = model.store.transfer(for: entry) {
                switch transfer {
                case .working(let p):
                    HStack(spacing: 12) {
                        if let p { ProgressView(value: p) } else { ProgressView() }
                        Text(p.map { "Downloading \(Int($0 * 100))%" } ?? "Working...")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Cancel", role: .cancel) { model.store.cancel(entry) }.novaBorderedButton()
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline).foregroundStyle(.orange)
                    Button("Try again") { model.store.install(entry, data: model.data) }.novaProminentButton()
                }
            } else {
                HStack(spacing: 12) {
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
                }
                if model.store.isOffline && !status.isInstalled {
                    Label("You're offline. Connect to download.", systemImage: "wifi.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if status.isInstalled { enableControl }
            }
        }
    }

    @ViewBuilder private var manageButtons: some View {
        Button { showFiles = true } label: { Label("Files", systemImage: "doc.on.doc") }.novaBorderedButton()
        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            .novaBorderedButton()
    }

    @ViewBuilder private var enableControl: some View {
        if let bundle = installedBundles.first {
            if model.data.manualPluginOrder || bundle.isTotalConversion {
                Toggle(isOn: Binding(get: { bundle.isEnabled },
                                     set: { model.data.setPlugin(bundle.id, enabled: $0) })) {
                    Text(bundle.isTotalConversion ? "Play this total conversion" : "Enabled")
                }
                .cursorClickable { model.data.setPlugin(bundle.id, enabled: !bundle.isEnabled) }
                if bundle.isTotalConversion {
                    Text("Only one total conversion can be active. Turning this on turns the others off.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
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
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About").font(.title3.weight(.semibold))
            let long = entry.description.isEmpty ? entry.summary : entry.description
            if let attributed = try? AttributedString(
                markdown: long, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed)
            } else {
                Text(long)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details").font(.title3.weight(.semibold))
            fact("Version", entry.version)
            fact("Author", entry.author)
            if let size = entry.sizeBytes { fact("Download size", formatPluginSize(size)) }
            if let d = entry.updatedDate ?? entry.addedDate { fact(entry.updatedDate == nil ? "Added" : "Updated", d) }
            fact("Downloads from", entry.downloadHost)
            if !entry.tags.isEmpty { fact("Tags", entry.tags.joined(separator: ", ")) }
            if let license = entry.license { fact("License", license) }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }

    private var compatibility: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compatibility").font(.title3.weight(.semibold))
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
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
    }

    @ViewBuilder private var links: some View {
        #if !os(tvOS)
        if entry.homepageURL != nil || entry.sourceURL != nil {
            HStack(spacing: 12) {
                if let url = entry.homepageURL {
                    Button { openURL(url) } label: { Label("Website", systemImage: "safari") }.novaBorderedButton()
                }
                if let url = entry.sourceURL {
                    Button { openURL(url) } label: { Label("Source", systemImage: "chevron.left.forwardslash.chevron.right") }
                        .novaBorderedButton()
                }
            }
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
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }
}
