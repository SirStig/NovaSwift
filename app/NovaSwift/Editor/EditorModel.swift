#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// The Plugin Editor's observable state: one open `PluginDocument` plus what
/// the UI is looking at. Every editor surface (browser, inspectors, galaxy
/// and system editors, previews, test runs) reads and writes through this so
/// undo, dirty state and live previews stay in step. See docs/PLUGIN_EDITOR.md.
@MainActor
final class EditorModel: ObservableObject {
    /// Top-level tool shown in the main area.
    enum Tool: Hashable { case changes, resources, galaxy, system, story, lint, project }

    /// What the open document came from on disk: the plug-in's folder, its
    /// resource files, any `.nsx` graphics packs and other bundle files, and
    /// whether it's a total conversion. Nil for a new, never-saved document.
    /// Filled by the project store (see docs/PLUGIN_EDITOR.md, "Plug-in shapes").
    @Published var bundle: EditorBundleInfo?
    /// For every key the document touches, the other enabled plug-ins that
    /// also define it, in load order (last one wins in game). Built off-main.
    @Published var conflicts: [ResourceKey: [String]] = [:]

    @Published private(set) var document: PluginDocument
    /// Where the document was opened from / last saved to (nil = never saved).
    @Published var fileURL: URL?
    @Published var format: PluginFormat = .rez

    @Published var tool: Tool = .resources
    @Published var selectedType: NovaSwiftKit.FourCharCode?
    @Published var selection: ResourceKey?
    /// System the system editor is showing (sÿst id).
    @Published var focusedSystemID: Int?

    /// Set by the specialised inspectors (ship "Test fly", weapon "Test on range") to ask
    /// the shell to open an equipped test run; the shell clears it. See `EditorTestRunRequest`.
    @Published var testRunRequest: EditorTestRunRequest?

    /// Extra setup a tool wants applied to the next test run's session (set bits,
    /// start a mission). Consumed by `runSessionSetup`; see `Story/EditorModel+TestRun.swift`.
    var sessionSetup: ((EditorTestSession) -> Void)?

    /// Bumped on every document change; views key refreshes and previews off it.
    @Published private(set) var revision = 0
    /// Keys touched by the most recent change (for targeted preview reloads).
    @Published private(set) var lastChanged: Set<ResourceKey> = []
    /// Bumped only when resource DATA changes (an edit, undo/redo, a new document) — not for
    /// metadata/dirty-state refreshes like Save. Derived caches (lists, stats, specs, lint)
    /// key off this so saving never recomputes them. Not `@Published`: it always moves
    /// together with `revision`, which is what triggers view updates.
    private(set) var dataRevision = 0

    /// False while the open document's merged view (base ⊕ layer) is still being assembled
    /// off the main actor. Surfaces show skeletons until it flips.
    @Published private(set) var dataReady = false
    /// False until the reference graph ("uses · used by") has been built in the background.
    @Published private(set) var referencesReady = false

    private var prepareGeneration = 0
    private var refKeysSinceSnapshot: Set<ResourceKey> = []
    private var buildingReferences = false

    /// The pristine base the document overlays (base game + other enabled
    /// plug-ins, never including the document itself). Previews pass it to
    /// `EditorGameFactory` so only changed sprites re-decode.
    var base: ResourceCollection { document.base }
    /// Base ⊕ document — what the game would load with this plug-in enabled.
    var effective: ResourceCollection { document.effective }

    init(document: PluginDocument) {
        self.document = document
        attach()
    }

    /// Swap in another document (new / open), resetting UI state.
    func replaceDocument(_ doc: PluginDocument, url: URL?) {
        document.onChange = nil
        document = doc
        fileURL = url
        selection = nil
        selectedType = nil
        focusedSystemID = nil
        attach()
        dataRevision += 1
        revision += 1
    }

    private func attach() {
        document.onChange = { [weak self] keys in
            // PluginDocument calls back synchronously on the editing actor.
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.buildingReferences { self.refKeysSinceSnapshot.formUnion(keys) }
                self.lastChanged = keys
                self.dataRevision += 1
                self.revision += 1
            }
        }
        prepare()
    }

    /// Assemble the merged view and the reference graph off the main actor so the first
    /// frame never waits on them. Until `dataReady`, surfaces show skeletons; edits made
    /// meanwhile are reconciled by `PluginDocument.adoptEffective` / `adoptReferences`.
    private func prepare() {
        prepareGeneration += 1
        let gen = prepareGeneration
        let doc = document
        buildingReferences = false
        refKeysSinceSnapshot = []
        if doc.hasEffectiveCached || doc.base.byType.isEmpty {
            // Nothing heavy to assemble (empty base / already built): ready right now.
            dataReady = true
            referencesReady = doc.hasReferencesCached
            if !referencesReady { buildReferences(doc, gen: gen) }
            return
        }
        dataReady = false
        referencesReady = false
        let base = doc.base, layer = doc.layer, count = doc.changeCount
        Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) { () -> ResourceCollection in
                var e = base
                e.overlay(layer)
                return e
            }.value
            guard let self, gen == self.prepareGeneration else { return }
            doc.adoptEffective(built, atChangeCount: count)
            self.dataReady = true
            self.referencesReady = doc.hasReferencesCached
            if !self.referencesReady { self.buildReferences(doc, gen: gen) }
        }
    }

    private func buildReferences(_ doc: PluginDocument, gen: Int) {
        guard !buildingReferences else { return }
        buildingReferences = true
        refKeysSinceSnapshot = []
        let eff = doc.effective
        Task { [weak self] in
            let built = await Task.detached(priority: .utility) { ResourceReferences(eff) }.value
            guard let self, gen == self.prepareGeneration else { return }
            doc.adoptReferences(built, updating: self.refKeysSinceSnapshot)
            self.refKeysSinceSnapshot = []
            self.buildingReferences = false
            self.referencesReady = true
        }
    }

    // MARK: Editing conveniences (all undoable via the document)

    @discardableResult
    func setValue(_ value: FieldValue, field: String, of key: ResourceKey) -> Bool {
        document.setValue(value, field: field, of: key.type, key.id)
    }

    func readValue(_ field: String, of key: ResourceKey) -> FieldValue? {
        guard let schema = ResourceSchemas.schema(for: key.type),
              let r = document.resource(key.type, key.id) else { return nil }
        return schema.read(field, from: r.data)
    }

    func undo() { document.undo() }
    func redo() { document.redo() }

    /// Metadata (name/author/…) edits don't go through `onChange`; call this so
    /// observers refresh (dirty dot, titles).
    func metadataChanged() { revision += 1 }

    /// Jump to a resource in the browser (clears tool to `.resources`).
    func navigate(to key: ResourceKey) {
        tool = .resources
        selectedType = key.type
        selection = key
    }
}
#endif

#if os(macOS)
/// The on-disk shape of an opened plug-in (see `EditorModel.bundle`).
struct EditorBundleInfo: Equatable, Sendable {
    var name: String
    /// The plug-in's folder (nil for a lone file opened directly).
    var folderURL: URL?
    /// Resource files in load order. Each resource remembers which of these it
    /// came from (`PluginDocument` source tracking) so Save writes each back.
    var resourceFiles: [URL]
    /// `.nsx` graphics-pack folders loaded into the document as NSgx/NSbl.
    var graphicsPacks: [URL]
    /// Everything else in the folder: fonts, movies, music, pilots, `.nplay`, readmes.
    var otherFiles: [URL]
    /// A total conversion: its own `Nova Files` are the base, its `Plug-Ins` the layer.
    var isTotalConversion: Bool
    /// The installed `PluginBundle.id`, when opened from the plug-in list.
    var installedID: String?
}
#endif
