#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// Project tab: metadata, stats, save/export/install and recent files.
struct ProjectPanelView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var store: EditorProjectStore
    @ObservedObject private var cache: EditorBrowseCache
    let plugins: [PluginBundle]

    init(model: EditorModel, store: EditorProjectStore, plugins: [PluginBundle]) {
        self.model = model; self.store = store; self.plugins = plugins
        _cache = ObservedObject(wrappedValue: store.cache)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Project").font(.system(size: 18, weight: .semibold))
                metadata
                stats
                exportSection
                openSection
            }
            .padding(24).frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(white: 0.11))
        .task(id: model.dataRevision) { cache.refreshStats(model) }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
            c()
        }
    }

    private func bind(_ kp: ReferenceWritableKeyPath<PluginDocument, String>) -> Binding<String> {
        Binding(get: { model.document[keyPath: kp] }, set: { model.document[keyPath: kp] = $0; model.metadataChanged() })
    }

    private var metadata: some View {
        section("Plug-in") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow { Text("Name"); TextField("", text: bind(\.name)).textFieldStyle(.roundedBorder) }
                GridRow { Text("Author"); TextField("", text: bind(\.author)).textFieldStyle(.roundedBorder) }
                GridRow { Text("Version"); TextField("", text: bind(\.version)).textFieldStyle(.roundedBorder).frame(width: 120) }
                GridRow(alignment: .top) {
                    Text("Notes")
                    TextEditor(text: bind(\.notes)).font(.system(size: 12)).frame(height: 80)
                        .scrollContentBackground(.hidden).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                }
            }.font(.system(size: 12))
            HStack(spacing: 8) {
                Text(model.fileURL?.path ?? "Not saved yet").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let id = store.installedID { Text("installed: \(id)").font(.system(size: 11)).foregroundStyle(.green) }
            }
        }
    }

    private var stats: some View {
        let list = (cache.stats ?? []).filter { $0.new + $0.overridden > 0 }
        let n = list.reduce(0) { $0 + $1.new }, o = list.reduce(0) { $0 + $1.overridden }
        return section("Contents") {
            if cache.stats == nil {
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBar(width: 260, height: 11)
                    SkeletonBar(width: 200, height: 9)
                    SkeletonBar(width: 230, height: 9)
                }
            } else {
                Text("\(n + o) resources · \(n) new · \(o) overriding the base game").font(.system(size: 12))
            }
            if cache.stats == nil {
                EmptyView()
            } else if list.isEmpty {
                Text("Nothing yet — create or edit a resource and it appears here.").font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 3) {
                    GridRow {
                        Text("Type").gridColumnAlignment(.leading); Text("New"); Text("Override")
                    }.foregroundStyle(.secondary).font(.system(size: 11))
                    ForEach(list) { s in
                        GridRow {
                            Text(s.name).gridColumnAlignment(.leading)
                            Text("\(s.new)").font(.system(size: 12, design: .monospaced))
                            Text("\(s.overridden)").font(.system(size: 12, design: .monospaced))
                        }.font(.system(size: 12))
                    }
                }
            }
        }
    }

    private var exportSection: some View {
        section("Save & Export") {
            HStack(spacing: 8) {
                Button { store.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                Button { store.saveAs() } label: { Label("Save As…", systemImage: "square.and.arrow.down.on.square") }
                Button { store.installIntoPlugins() } label: { Label("Install into Plugins", systemImage: "puzzlepiece.extension") }
                    .help("Copy into NovaSwift's plug-ins folder and reload game data")
            }
            Picker("Format", selection: Binding(get: { store.exportOptions.format }, set: { store.exportOptions.format = $0; model.format = $0 })) {
                Text("EV Nova plug-in (.rez)").tag(PluginFormat.rez)
                Text("Classic resource fork (.ndat)").tag(PluginFormat.classic)
            }.frame(width: 360)
            Toggle("Embed editor metadata (name, author, notes)", isOn: $store.exportOptions.embedMetadata)
            Toggle("Include HD graphics layer (NSgx / NSbl)", isOn: $store.exportOptions.includeHD)
                .help("NovaSwift-only; the original game ignores these resources.")
            Toggle("Full export (include the base game)", isOn: $store.exportOptions.full)
            if store.exportOptions.full {
                Label("A full export contains the base game's own data. Only share it if you may redistribute it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            Button { store.exportCopy() } label: { Label("Export Copy…", systemImage: "square.and.arrow.up") }
        }
    }

    private var openSection: some View {
        section("Open") {
            HStack(spacing: 8) {
                Button("Open File…") { store.guardDirty("Open another plug-in?") { store.openPanel() } }
                Menu("Installed Plug-ins") {
                    if plugins.isEmpty { Text("No plug-ins installed") }
                    ForEach(plugins) { p in
                        Button(p.name) { store.guardDirty("Open \(p.name)?") { store.openInstalled(p) } }
                    }
                }.fixedSize()
            }
            if !store.recents.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(store.recents) { r in
                        Button { store.guardDirty("Open \(r.name)?") { store.open(recent: r) } } label: {
                            HStack { Image(systemName: "doc"); Text(r.name); Text(r.path).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head) }
                                .font(.system(size: 12))
                        }.buttonStyle(.plain)
                    }
                    Button("Clear Recents") { store.clearRecents() }.buttonStyle(.link).font(.system(size: 11))
                }
            }
        }
    }
}
#endif
