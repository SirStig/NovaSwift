#if os(macOS)
import SwiftUI
import AppKit
import NovaSwiftKit

/// The Plugin Editor's root screen. Replaces the whole game UI while open
/// (`AppModel.Screen.editor`); see docs/PLUGIN_EDITOR.md.
///
/// Layout: sidebar (project + tools + types) · tool area. The resources tool is
/// list · inspector; other tools fill the area. Test runs swap the whole editor
/// for `EditorTestRunView` and come back on exit.
struct PluginEditorView: View {
    var onClose: () -> Void

    @EnvironmentObject private var app: AppModel
    @StateObject private var store = EditorProjectStore()
    @StateObject private var ui = EditorUIState()

    private struct TestRun { let collection: ResourceCollection; let base: ResourceCollection; let system: Int?; let ship: Int?; var request: EditorTestRunRequest? = nil }
    @State private var testRun: TestRun?

    var body: some View {
        Group {
            if let t = testRun {
                EditorTestRunView(collection: t.collection, base: t.base, startSystem: t.system, startShip: t.ship,
                                  onReady: t.request.map { r in { session in r.prepare(session); store.model.runSessionSetup(session) } }) {
                    testRun = nil
                }
            } else {
                editor
            }
        }
        .preferredColorScheme(.dark)
        .onReceive(store.model.$testRunRequest.compactMap { $0 }) { r in
            let m = store.model
            m.testRunRequest = nil
            testRun = TestRun(collection: m.effective, base: m.base, system: r.system ?? m.focusedSystemID,
                              ship: r.ship, request: r)
        }
        .onAppear {
            // Cheap: swaps in a document over the already-loaded base. The merged view and
            // the reference graph are assembled off-main (see `EditorModel.prepare`).
            store.configure(data: app.data)
        }
    }

    private var editor: some View {
        let model = store.model
        return VStack(spacing: 0) {
            EditorTopBar(model: model, store: store, lint: store.lint, plugins: app.data.plugins,
                         onTestRun: startTestRun, onClose: requestClose)
            Divider()
            HSplitView {
                EditorSidebar(model: model, store: store, lint: store.lint, cache: store.cache)
                    .frame(minWidth: 200, idealWidth: 230, maxWidth: 320)
                EditorToolArea(model: model, store: store, ui: ui, plugins: app.data.plugins)
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
            if let m = store.message { statusBar(m) }
        }
        .background(Color(white: 0.1))
        .overlay { if store.isBusy { busyOverlay } }
        .background(shortcuts)
        .background(EditorLintTrigger(model: model, lint: store.lint))
        .sheet(item: Binding(get: { ui.renumberTarget.map(EditorKeyItem.init) }, set: { ui.renumberTarget = $0?.key })) { item in
            RenumberSheet(model: model, key: item.key) { ui.renumberTarget = nil }
        }
        .confirmationDialog(store.pending?.title ?? "", isPresented: Binding(get: { store.pending != nil }, set: { if !$0 { store.pending = nil } }),
                            titleVisibility: .visible) {
            Button("Save") { saveThen { store.pending?.run(); store.pending = nil } }
            Button("Don't Save", role: .destructive) { let p = store.pending; store.pending = nil; p?.run() }
            Button("Cancel", role: .cancel) { store.pending = nil }
        } message: { Text("You have unsaved changes in \"\(model.document.name)\".") }
        .alert("Plugin Editor", isPresented: Binding(get: { store.errorText != nil }, set: { if !$0 { store.errorText = nil } })) {
            Button("OK") { store.errorText = nil }
        } message: { Text(store.errorText ?? "") }
        .alert("Recover unsaved work?", isPresented: $store.recoveryAvailable) {
            Button("Restore") { store.restoreRecovery() }
            Button("Discard", role: .destructive) { store.clearRecovery() }
        } message: { Text("The editor found an autosaved plug-in from a previous session that wasn't saved.") }
    }

    private func statusBar(_ m: String) -> some View {
        HStack { Image(systemName: "info.circle"); Text(m).lineLimit(1); Spacer() }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Color.white.opacity(0.05))
    }

    private var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 10) { ProgressView(); Text(store.busyText).font(.system(size: 12)) }
                .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: Actions

    private func requestClose() {
        store.guardDirty("Close the Plugin Editor?") { store.clearRecovery(); onClose() }
    }

    /// Save (prompting for a path if needed), then run `then` only if it went through.
    private func saveThen(_ then: @escaping () -> Void) {
        store.save()
        if !store.model.document.isDirty { then() }
    }

    private func startTestRun() {
        let model = store.model
        var system = model.focusedSystemID
        if system == nil, let s = model.selection, s.type == NovaType.syst { system = s.id }
        var ship: Int?
        if let s = model.selection, s.type == NovaType.ship { ship = s.id }
        testRun = TestRun(collection: model.effective, base: model.base, system: system, ship: ship)
    }

    /// Hidden buttons carry the keyboard shortcuts so they work wherever focus is.
    private var shortcuts: some View {
        let model = store.model
        return ZStack {
            Button("") { store.save() }.keyboardShortcut("s", modifiers: .command)
            Button("") { store.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("") { Self.undoShortcut(model, redo: false) }.keyboardShortcut("z", modifiers: .command)
            Button("") { Self.undoShortcut(model, redo: true) }.keyboardShortcut("z", modifiers: [.command, .shift])
            Button("") { if let t = model.selectedType, model.tool == .resources { EditorActions.newResource(model, t) } }
                .keyboardShortcut("n", modifiers: .command)
            Button("") { if let k = model.selection { EditorActions.duplicate(model, k) } }
                .keyboardShortcut("d", modifiers: .command)
            Button("") { model.tool = .resources; ui.searchTick += 1 }.keyboardShortcut("f", modifiers: .command)
            Button("") { startTestRun() }.keyboardShortcut("r", modifiers: .command)
            Button("") { store.guardDirty("Open another plug-in?") { store.openPanel() } }.keyboardShortcut("o", modifiers: .command)
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
    }
}

/// The main area under the toolbar. Observes the model so it can hold every tool back
/// (skeleton + "Preparing data…") until the merged view exists, instead of letting a tool
/// build it on the main thread inside its first `body`.
struct EditorToolArea: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var store: EditorProjectStore
    @ObservedObject var ui: EditorUIState
    let plugins: [PluginBundle]

    var body: some View {
        if !model.dataReady {
            ZStack {
                switch model.tool {
                case .resources:
                    HSplitView {
                        SkeletonList(rows: 16).frame(minWidth: 260, idealWidth: 320, maxWidth: 340, maxHeight: .infinity, alignment: .top)
                        SkeletonForm(groups: 4).frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                case .changes:
                    SkeletonList(rows: 18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                default:
                    Color(white: 0.11)
                }
                EditorLoadingOverlay(label: "Preparing data…")
            }
        } else {
            switch model.tool {
            case .changes:
                ChangesView(model: model)
            case .bundleFiles:
                BundleFilesView(model: model)
            case .resources:
                HSplitView {
                    ResourceListView(model: model, store: store, ui: ui)
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 340)
                    InspectorView(model: model, store: store, ui: ui, lint: store.lint)
                        .frame(minWidth: 380, maxWidth: .infinity)
                }
            case .galaxy:
                GalaxyEditorView(model: model)
            case .system:
                SystemEditorView(model: model)
            case .story:
                StoryEditorView(model: model)
            case .lint:
                LintPanelView(model: model, lint: store.lint, ui: ui)
            case .project:
                ProjectPanelView(model: model, store: store, plugins: plugins)
            }
        }
    }
}

/// Re-lints (debounced, off-main) when resource data changes or the merged view becomes
/// ready. Lives in its own observing view because `PluginEditorView` doesn't observe the model.
private struct EditorLintTrigger: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var lint: EditorLintModel

    private struct Key: Hashable { let rev: Int; let ready: Bool }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: Key(rev: model.dataRevision, ready: model.dataReady), initial: true) { _, _ in
                lint.noteChange(model)
            }
    }
}

struct EditorKeyItem: Identifiable { let key: ResourceKey; var id: String { "\(key.type.rawValue)/\(key.id)" } }

/// Top bar: close, file menu, save, undo/redo, validate, test run.
struct EditorTopBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var store: EditorProjectStore
    @ObservedObject var lint: EditorLintModel
    let plugins: [PluginBundle]
    var onTestRun: () -> Void
    var onClose: () -> Void

    var body: some View {
        let doc = model.document
        HStack(spacing: 10) {
            Button(action: onClose) { Label("Close", systemImage: "xmark") }
                .help("Close the editor and return to the main menu")
            Divider().frame(height: 18)
            fileMenu
            Button { store.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .help("Save (⌘S)").disabled(!doc.isDirty && model.fileURL != nil)
            Divider().frame(height: 18)
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!doc.canUndo).help(doc.undoLabel.map { "Undo \($0) (⌘Z)" } ?? "Undo")
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!doc.canRedo).help(doc.redoLabel.map { "Redo \($0) (⇧⌘Z)" } ?? "Redo")
            Spacer()
            Text(doc.undoLabel.map { "↶ \($0)" } ?? "").font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            Button { model.tool = .lint } label: {
                HStack(spacing: 5) {
                    Image(systemName: lint.errorCount > 0 ? "xmark.shield" : "checkmark.shield")
                    Text("Validate")
                    if lint.isRunning { ProgressView().controlSize(.mini).scaleEffect(0.8) }
                    let n = lint.errorCount + lint.warningCount
                    if n > 0 {
                        Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(lint.errorCount > 0 ? Color.red : Color.orange, in: Capsule())
                    }
                }
            }
            Button(action: onTestRun) {
                Label("Test Run", systemImage: "play.fill").foregroundStyle(Color.black)
            }
            .buttonStyle(.borderedProminent).tint(novaAmber)
            .help("Play the game with this plug-in applied (⌘R)")
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.regular)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(white: 0.13))
    }

    private var fileMenu: some View {
        Menu {
            Button("New Plug-in") { store.guardDirty("Create a new plug-in?") { store.newPlugin() } }
            Button("Open…") { store.guardDirty("Open another plug-in?") { store.openPanel() } }
            Menu("Open Installed Plug-in") {
                if plugins.isEmpty { Text("None installed") }
                ForEach(plugins) { p in Button(p.name) { store.guardDirty("Open \(p.name)?") { store.openInstalled(p) } } }
            }
            Menu("Open Recent") {
                if store.recents.isEmpty { Text("No recent files") }
                ForEach(store.recents) { r in Button(r.name) { store.guardDirty("Open \(r.name)?") { store.open(recent: r) } } }
            }
            Divider()
            Button("Save") { store.save() }
            Button("Save As…") { store.saveAs() }
            Button("Export Copy…") { store.exportCopy() }
            Button("Install into Plugins") { store.installIntoPlugins() }
            Divider()
            Button("Project Settings…") { model.tool = .project }
        } label: { Label("File", systemImage: "doc") }
            .menuStyle(.borderlessButton).fixedSize()
    }
}
#endif

#if os(macOS)
import AppKit

extension PluginEditorView {
    /// ⌘Z / ⇧⌘Z: while a text field is being edited, its own undo wins (so a
    /// typo fix doesn't roll back a document change); otherwise the document's.
    @MainActor
    static func undoShortcut(_ model: EditorModel, redo: Bool) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView,
           let manager = text.undoManager,
           redo ? manager.canRedo : manager.canUndo {
            redo ? manager.redo() : manager.undo()
            return
        }
        redo ? model.redo() : model.undo()
    }
}
#endif
