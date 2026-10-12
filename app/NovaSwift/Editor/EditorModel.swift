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
    enum Tool: Hashable { case resources, galaxy, system, story, lint, project }

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
        revision += 1
    }

    private func attach() {
        document.onChange = { [weak self] keys in
            // PluginDocument calls back synchronously on the editing actor.
            MainActor.assumeIsolated {
                self?.lastChanged = keys
                self?.revision += 1
            }
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
