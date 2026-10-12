#if os(macOS)
import Foundation
import NovaSwiftKit

/// HD / 3D art for editor games (live preview, test run, stellar thumbnails).
///
/// The game's HD layer (`HDGraphics.shared`) is one process-wide singleton installed from
/// the *loaded* data set. An editor game runs on a different data set (base ⊕ the author's
/// plug-in layer), so before it builds sprites this installs a catalog for that data:
///
///  1. the user's installed enhancements — the loaded game's in-file `NSgx`/`NSbl` and every
///     `.nsx` sidecar pack the game found at load (`HDGraphics.lastSearch`), exactly as the
///     game layers them (skipped when the document is a total conversion);
///  2. then the document's effective collection on top — its own `NSgx`/`NSbl`, including
///     entries loaded from an `.nsx` pack (tagged `pack:` in the layer), so an edit to an HD
///     attachment overrides the installed art of the same sprite.
///
/// The user's HD settings are honoured by `HDGraphics` itself (`hdGraphics` off = nothing
/// is drawn HD, whatever is installed).
///
/// Installing is skipped when nothing relevant changed (`fingerprint`), so a rebuild after
/// an unrelated edit costs nothing. The editor changes the singleton, so the game's own HD
/// state is restored a few seconds after the last editor game goes away (`release`).
final class EditorHD: @unchecked Sendable {
    static let shared = EditorHD()

    /// Everything `ensure` needs from the main actor, captured as plain values.
    struct Inputs: Sendable {
        var plugins: [PluginBundle]
        /// The loaded game's merged resources (base + enabled plug-ins), nil for a total conversion.
        var installed: ResourceCollection?
        var settings: GameSettings
    }

    private let lock = NSLock()
    private var installedKey: Int?
    // Main-actor only (see `acquire` / `release`).
    private var owners = Set<ObjectIdentifier>()
    private var restoreTask: Task<Void, Never>?

    @MainActor
    static func inputs(app: AppModel, base: ResourceCollection?) -> Inputs {
        let usesInstalled = (base?.totalCount ?? 0) > 0
        return Inputs(plugins: app.data.plugins,
                      installed: usesInstalled ? app.data.game?.resources : nil,
                      settings: app.settings)
    }

    /// Install the catalog for `collection` and prepare its art (blocking; call off the
    /// main actor). Returns whether anything was (re)installed.
    @discardableResult
    func ensure(collection: ResourceCollection, game: NovaGame, inputs: Inputs) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let packs = inputs.installed == nil ? [] : (HDGraphics.shared.lastSearch?.packs ?? [])
        let key = Self.fingerprint(collection: collection, inputs: inputs, packs: packs)
        if key == installedKey {
            HDGraphics.shared.update(settings: inputs.settings)
            return false
        }
        var catalog: GraphicsEnhancementCatalog
        if let installed = inputs.installed {
            catalog = GameLibrary.graphicsCatalog(resources: installed, plugins: inputs.plugins, graphicsPacks: packs)
        } else {
            catalog = GraphicsEnhancementCatalog()
        }
        catalog.addInFile(from: collection)     // the document wins over the installed art
        HDGraphics.shared.install(catalog: catalog, game: game, settings: inputs.settings)
        installedKey = key
        if inputs.settings.hdGraphics, !catalog.isEmpty {
            HDGraphics.shared.prewarm { _, _ in }
        }
        return true
    }

    /// Whether HD art is currently drawn at all (setting on and something installed).
    var isActive: Bool { HDGraphics.shared.isActive }

    /// A cheap digest of what decides the catalog and the layouts HD sprites are fitted to.
    private static func fingerprint(collection: ResourceCollection, inputs: Inputs, packs: [URL]) -> Int {
        var h = Hasher()
        for r in collection.resources(of: GraphicsEnhancementType.descriptor).sorted(by: { $0.id < $1.id }) {
            h.combine(r.id); h.combine(r.data)
        }
        for r in collection.resources(of: GraphicsEnhancementType.blob).sorted(by: { $0.id < $1.id }) {
            // Blobs are large PNG/USDZ files: size + both ends identify an edit without hashing megabytes.
            h.combine(r.id); h.combine(r.data.count)
            h.combine(r.data.prefix(256)); h.combine(r.data.suffix(256))
        }
        // The classic sprite layouts the HD art is fitted to.
        for t in [NovaType.shan, NovaType.spin] {
            for r in collection.resources(of: t).sorted(by: { $0.id < $1.id }) { h.combine(r.id); h.combine(r.data) }
        }
        h.combine(inputs.installed == nil)
        for p in inputs.plugins where p.isEnabled { h.combine(p.id) }
        for p in packs { h.combine(p.path) }
        return h.finalize()
    }

    /// Forget the installed key; true if an editor catalog was installed.
    private func takeInstalled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let dirty = installedKey != nil
        installedKey = nil
        return dirty
    }

    // MARK: Restoring the game's own HD state

    /// An editor game (preview or test run) is using the HD layer.
    @MainActor
    func acquire(_ owner: AnyObject) {
        owners.insert(ObjectIdentifier(owner))
        restoreTask?.cancel(); restoreTask = nil
    }

    /// The owner is gone; once no editor game is left the game's installed HD layer is rebuilt
    /// (debounced, so switching between editor tools doesn't thrash it).
    @MainActor
    func release(_ owner: AnyObject, app: AppModel?) {
        owners.remove(ObjectIdentifier(owner))
        guard owners.isEmpty else { return }
        restoreTask?.cancel()
        restoreTask = Task { [weak self, weak app] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, self.owners.isEmpty else { return }
            guard self.takeInstalled(), let app else { return }
            await app.data.reloadGraphicsPacks()
        }
    }
}
#endif
