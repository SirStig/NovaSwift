#if os(macOS)
import SwiftUI
import AppKit
import NovaSwiftKit

/// Middle column: resources of the selected type with provenance, filters and
/// the context-menu actions.
struct ResourceListView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var store: EditorProjectStore
    @ObservedObject var ui: EditorUIState
    /// Which resources carry HD / 3D art (resolved off-main, shared with the Changes view).
    @ObservedObject private var hd: EditorHDIndex

    init(model: EditorModel, store: EditorProjectStore, ui: EditorUIState) {
        self.model = model
        self.store = store
        self.ui = ui
        _hd = ObservedObject(wrappedValue: EditorHDIndex.shared(for: model))
    }

    enum Scope: String, CaseIterable, Identifiable {
        case all = "All", mine = "This plug-in", base = "Base"
        var id: String { rawValue }
    }
    @State private var scope: Scope = .all
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    /// The last list delivered for the selected type (kept while a newer one builds).
    @State private var shown: Shown?

    private struct Shown { let type: NovaSwiftKit.FourCharCode; let list: BrowseList }

    var body: some View {
        VStack(spacing: 0) {
            if let type = model.selectedType {
                let current = currentList(type)
                header(type, current)
                Divider().overlay(alignment: .top) {
                    EditorRefreshStrip(active: current.map { $0.revision != model.dataRevision } ?? false)
                }
                list(type, current)
            } else {
                EditorEmptyState(icon: "sidebar.left", title: "Choose a resource type",
                                 subtitle: "Pick a type in the sidebar to browse and edit its resources.")
            }
        }
        .background(Color(white: 0.11))
        .onChange(of: ui.searchTick) { _, _ in searchFocused = true }
        .task(id: RefreshKey(type: model.selectedType, rev: model.dataRevision, ready: model.dataReady)) {
            await refresh()
        }
        .task(id: HDKey(rev: model.dataRevision, ready: model.dataReady)) {
            // Behind the list itself, and coalesced across an edit burst.
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            await hd.refresh(model)
        }
    }

    private struct HDKey: Hashable { let rev: Int; let ready: Bool }

    private struct RefreshKey: Hashable { let type: NovaSwiftKit.FourCharCode?; let rev: Int; let ready: Bool }

    /// What to draw for `type` right now: the delivered list if it is for this type, else
    /// whatever the cache already has (instant on a revisited type), else nil → skeleton.
    private func currentList(_ type: NovaSwiftKit.FourCharCode) -> BrowseList? {
        guard model.dataReady else { return nil }
        if let s = shown, s.type == type { return s.list }
        return store.cache.cachedList(type)
    }

    /// Build (off-main) the list for the selected type at the current revision. Edits arrive
    /// in bursts while typing in the inspector, so a refresh over an already-shown list waits
    /// briefly and is cancelled by the next edit instead of rebuilding per keystroke.
    private func refresh() async {
        guard let type = model.selectedType, model.dataReady else { return }
        if currentList(type)?.revision != model.dataRevision, currentList(type) != nil {
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
        }
        let fresh = await store.cache.list(type, model)
        if Task.isCancelled { return }
        shown = Shown(type: type, list: fresh)
    }

    private func visibleRows(_ all: BrowseList) -> [BrowseRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if scope == .all && q.isEmpty { return all.rows }
        return all.rows.filter { r in
            switch scope {
            case .all: break
            case .mine: if !r.entry.provenance.isOwn { return false }
            case .base: if r.entry.provenance.isOwn { return false }
            }
            return q.isEmpty || r.matches(q)
        }
    }

    private func header(_ type: NovaSwiftKit.FourCharCode, _ current: BrowseList?) -> some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(ResourceSchemas.displayName(for: type)).font(.system(size: 14, weight: .semibold))
                    Text(current.map { "\(visibleRows($0).count) of \($0.rows.count) · \(type.stringValue)" } ?? type.stringValue)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { newResource(type) } label: { Image(systemName: "plus") }
                    .help("New \(ResourceSchemas.displayName(for: type)) (⌘N)")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                TextField("Search name or id", text: $search).textFieldStyle(.plain).focused($searchFocused)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            Picker("", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
        }
        .padding(10)
    }

    private func list(_ type: NovaSwiftKit.FourCharCode, _ current: BrowseList?) -> some View {
        Group {
            if let current {
                let rows = visibleRows(current)
                if rows.isEmpty {
                    EditorEmptyState(icon: "magnifyingglass", title: current.rows.isEmpty ? "No resources" : "No matches",
                                     subtitle: current.rows.isEmpty ? "Press + to create the first one." : "Try another filter or search.")
                } else {
                    List(selection: $model.selection) {
                        ForEach(rows) { r in
                            row(r.entry).tag(Optional(r.entry.key)).contextMenu { menu(r.entry) }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .onDeleteCommand { if let k = model.selection { delete(k) } }
                }
            } else {
                // First load of this type (or the merged view is still being assembled).
                SkeletonList(rows: 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func row(_ e: PluginDocument.BrowserEntry) -> some View {
        HStack(spacing: 8) {
            Text("\(e.key.id)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
            Text(e.name.isEmpty ? "—" : e.name).lineLimit(1)
                .foregroundStyle(e.name.isEmpty ? .tertiary : .primary)
            Spacer(minLength: 4)
            if let others = model.conflicts[e.key], let winner = others.last {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
                    .help("Also defined by \(others.joined(separator: ", ")) — \(winner) wins")
            }
            if hd.result?.badgeKeys.contains(e.key) == true {
                Image(systemName: "cube.fill").font(.system(size: 10)).foregroundStyle(Color.cyan)
                    .help("Has an HD sprite or 3D model attached")
            }
            if e.provenance != .base { ProvenanceBadge(provenance: e.provenance) }
        }
    }

    @ViewBuilder private func menu(_ e: PluginDocument.BrowserEntry) -> some View {
        Button("New \(ResourceSchemas.displayName(for: e.key.type))") { newResource(e.key.type) }
        Button("Duplicate") { duplicate(e.key) }
        Divider()
        if e.provenance == .override {
            Button("Revert to Base") { model.document.revertToBase(e.key.type, e.key.id) }
        }
        if e.provenance.isOwn {
            Button("Delete", role: .destructive) { delete(e.key) }
            Button("Renumber…") { ui.renumberTarget = e.key }
        }
        Divider()
        Button("Copy ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(e.key.id)", forType: .string)
        }
        Button("Show References") { model.selection = e.key; ui.refsTick += 1 }
    }

    // MARK: Actions (also used by keyboard shortcuts through EditorActions)

    private func newResource(_ type: NovaSwiftKit.FourCharCode) { EditorActions.newResource(model, type) }
    private func duplicate(_ k: ResourceKey) { EditorActions.duplicate(model, k) }
    private func delete(_ k: ResourceKey) { EditorActions.delete(model, k) }
}

/// Resource-level actions shared by the list, shortcuts and inspector.
@MainActor
enum EditorActions {
    static func newResource(_ model: EditorModel, _ type: NovaSwiftKit.FourCharCode) {
        do {
            let name = "New \(ResourceSchemas.displayName(for: type))"
            let id = try model.document.create(type, name: name)
            model.selection = ResourceKey(type, id)
        } catch { NSSound.beep() }
    }

    static func duplicate(_ model: EditorModel, _ k: ResourceKey) {
        if let id = try? model.document.duplicate(k.type, k.id) { model.selection = ResourceKey(k.type, id) }
        else { NSSound.beep() }
    }

    /// Deletes a plug-in-owned resource (an override simply reveals the base again).
    static func delete(_ model: EditorModel, _ k: ResourceKey) {
        guard model.document.layerResource(k.type, k.id) != nil else { NSSound.beep(); return }
        model.document.remove(k.type, k.id)
        if model.document.resource(k.type, k.id) == nil, model.selection == k { model.selection = nil }
    }
}

struct EditorEmptyState: View {
    let icon: String
    let title: String
    var subtitle: String = ""
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Renumber sheet.
struct RenumberSheet: View {
    @ObservedObject var model: EditorModel
    let key: ResourceKey
    var done: () -> Void
    @State private var newID: String
    @State private var rewrite = true
    @State private var report: String?

    init(model: EditorModel, key: ResourceKey, done: @escaping () -> Void) {
        self.model = model; self.key = key; self.done = done
        _newID = State(initialValue: String(key.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Renumber \(key.type.stringValue) #\(key.id)").font(.headline)
            HStack {
                Text("New ID"); TextField("", text: $newID).frame(width: 90).textFieldStyle(.roundedBorder)
            }
            Toggle("Update references in this plug-in", isOn: $rewrite)
            if !model.referencesReady && report == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Indexing references…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let report { Text(report).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: done).keyboardShortcut(.cancelAction)
                Button(report == nil ? "Renumber" : "Done") {
                    if report != nil { done(); return }
                    apply()
                }.keyboardShortcut(.defaultAction)
                    .disabled(report == nil && !model.referencesReady)
            }
        }
        .padding(20).frame(width: 380)
    }

    private func apply() {
        guard let to = Int(newID.trimmingCharacters(in: .whitespaces)) else { report = "Enter a whole number."; return }
        do {
            let r = try model.document.renumber(key.type, from: key.id, to: to, rewriteReferences: rewrite)
            model.selection = r.to
            var lines = ["Renumbered to #\(to)."]
            if !r.rewritten.isEmpty { lines.append("\(r.rewritten.count) resource(s) updated.") }
            if !r.externalReferrers.isEmpty { lines.append("\(r.externalReferrers.count) outside resource(s) still point at the old id: \(r.externalReferrers.prefix(4).map(\.description).joined(separator: ", "))…") }
            if !r.implicitRelatives.isEmpty { lines.append("Related by id: \(r.implicitRelatives.map(\.description).joined(separator: ", ")) — move them too.") }
            if r.externalReferrers.isEmpty && r.implicitRelatives.isEmpty { done() } else { report = lines.joined(separator: " ") }
        } catch { report = "\(error)" }
    }
}
#endif
