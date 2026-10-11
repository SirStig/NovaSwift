import Foundation
import SpriteKit
import NovaSwiftKit
import NovaSwiftHD
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The live HD layer: the graphics packs' HD sprites and 3D models, ready to
/// draw in place of the original sprites (docs/HD_PIPELINE.md).
///
/// Everything expensive — decoding HD atlases, baking 3D models — happens in
/// `prewarm`, on the loading screen, and bakes persist across launches. In
/// flight, `frames(for:)` only ever hands back finished textures: a sprite
/// whose HD art isn't ready simply draws classic and is prepared in the
/// background, so HD never costs a frame.
///
/// HD textures report the original frame size (their pixels are `pixelScale`
/// times denser), so every node size, radius, exit point and hit-box is the
/// original's; collision always uses the classic masks.
final class HDGraphics: @unchecked Sendable {
    static let shared = HDGraphics()

    private let lock = NSLock()
    private var catalog = GraphicsEnhancementCatalog()
    private var game: NovaGame?
    private var layouts: SpriteLayouts?
    private var enabled = false
    private var maxScale = 2.0
    private var generation = 0
    private var atlases: [Int: HDAtlas] = [:]
    private var textures: [Int: [SKTexture]] = [:]
    private var pending: Set<Int> = []
    private var failed: Set<Int> = []
    /// Base sprite id of each hull drawn by a model → whether it replaces the
    /// classic overlays (`overlays: hide`, the model default).
    private var modelHulls: [Int: Bool] = [:]
    private let hdTextures = NSHashTable<SKTexture>.weakObjects()
    private let bakeCache = HDBakeCache()

    /// Point the layer at a freshly loaded data set. Drops everything built
    /// for the previous one.
    /// Where the last `install` looked and what it found (for `hd status`).
    private(set) var lastSearch: (dirs: [URL], packs: [URL], at: Date)?

    func noteSearch(dirs: [URL], packs: [URL]) {
        lock.lock(); lastSearch = (dirs, packs, Date()); lock.unlock()
    }

    func install(catalog: GraphicsEnhancementCatalog, game: NovaGame, settings: GameSettings) {
        lock.lock(); defer { lock.unlock() }
        self.catalog = catalog
        self.game = game
        layouts = nil
        generation += 1
        atlases = [:]; textures = [:]; pending = []; failed = []; modelHulls = [:]
        apply(settings)
        for p in catalog.problems { NovaSwiftKit.Log.graphics.error("HD pack: \(p, privacy: .public)") }
        if !catalog.isEmpty {
            NovaSwiftKit.Log.graphics.info("HD: \(catalog.bySprite.count, privacy: .public) enhanced sprite(s) available")
        }
    }

    /// Follow the Settings toggles. A detail change rebuilds on next prewarm.
    func update(settings: GameSettings) {
        lock.lock(); defer { lock.unlock() }
        let oldScale = maxScale
        apply(settings)
        if oldScale != maxScale { atlases = [:]; textures = [:]; failed = []; modelHulls = [:]; generation += 1 }
    }

    private func apply(_ s: GameSettings) {
        enabled = s.hdGraphics
        maxScale = Double(min(4, max(2, s.hdDetail)))
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && !catalog.isEmpty
    }

    /// Prepare every enhancement whose classic sprite is an `rlëD` (the
    /// sheets the loader can open by id alone). PICT-sheet sprites are
    /// prepared on first sight instead. Call off the main thread.
    func prewarm(progress: (_ done: Int, _ total: Int) -> Void) {
        lock.lock()
        guard enabled, let game else { lock.unlock(); return }
        let entries = catalog.bySprite.values.sorted { $0.spriteID < $1.spriteID }
        let gen = generation
        lock.unlock()
        progress(0, entries.count)
        for (i, e) in entries.enumerated() {
            if game.resources.resource(NovaType.rleD, e.spriteID) != nil,
               let sheet = game.spriteSheet(spriteID: e.spriteID, maskID: 0, frameWidth: 0, frameHeight: 0, frameCount: 0) {
                prepare(e, classic: sheet, generation: gen)
            }
            progress(i + 1, entries.count)
        }
    }

    private func prepare(_ e: ResolvedGraphicsEnhancement, classic: SpriteSheet, generation gen: Int) {
        lock.lock()
        if atlases[e.spriteID] != nil || failed.contains(e.spriteID) { lock.unlock(); return }
        if layouts == nil, let game { layouts = SpriteLayouts(game: game) }
        let layout = layouts?.layout(for: classic)
        let scale = maxScale
        lock.unlock()
        guard let layout else { return }
        let overlays = overlayTargets(forBase: e.spriteID)
        let start = Date()
        do {
            let made = try HDAssetPipeline.atlases(for: e, classic: classic, layout: layout, overlays: overlays,
                                                   maxScale: scale, cache: bakeCache)
            lock.lock()
            if gen == generation {
                for (id, atlas) in made { atlases[id] = atlas }
                modelHulls[e.spriteID] = e.descriptor.kind == .model ? e.descriptor.hidesClassicOverlays : nil
            }
            lock.unlock()
            let bytes = made.values.reduce(0) { $0 + $1.byteCount }
            NovaSwiftKit.Log.graphics.debug("HD: sprite \(e.spriteID, privacy: .public) ready (\(made.count, privacy: .public) sheet(s), \(bytes / 1024, privacy: .public) KB) in \(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) ms")
        } catch {
            lock.lock()
            if gen == generation { failed.insert(e.spriteID) }
            lock.unlock()
            NovaSwiftKit.Log.graphics.error("HD: sprite \(e.spriteID, privacy: .public) from \(e.origin, privacy: .public) unusable — \(String(describing: error), privacy: .public); drawing the original")
        }
    }

    /// The classic overlay sheets of the hull drawn with `baseSpriteID`, as
    /// targets for the model's effect layers.
    private func overlayTargets(forBase baseSpriteID: Int) -> [HDAssetPipeline.OverlayTarget] {
        lock.lock()
        let ids = layouts?.overlays(forBase: baseSpriteID) ?? [:]
        let game = self.game
        lock.unlock()
        guard let game else { return [] }
        return ids.compactMap { layer, id in
            guard game.resources.resource(NovaType.rleD, id) != nil,
                  let sheet = game.spriteSheet(spriteID: id, maskID: 0, frameWidth: 0, frameHeight: 0, frameCount: 0)
            else { return nil }
            return HDAssetPipeline.OverlayTarget(spriteID: id, target: ModelBaker.LayerTarget(
                layer: layer, frameWidth: sheet.frameWidth, frameHeight: sheet.frameHeight, frameCount: sheet.frameCount,
                classic: sheet))
        }.sorted { $0.spriteID < $1.spriteID }
    }

    /// The HD frames for a classic sheet, in the same order and count, or nil
    /// to draw the classic frames (HD off, no enhancement, not ready yet).
    func frames(for sheet: SpriteSheet) -> [SKTexture]? {
        guard let id = sheet.sourceSpriteID else { return nil }
        lock.lock()
        guard enabled, !failed.contains(id) else { lock.unlock(); return nil }
        if let built = textures[id] { lock.unlock(); return built }
        guard let atlas = atlases[id] else {
            // Effect layers rendered from a model exist only as atlases; a
            // sprite with no enhancement of its own is otherwise classic.
            guard let entry = catalog[id] else { lock.unlock(); return nil }
            // Not prewarmed (e.g. a PICT-sheet sprite): prepare in the background.
            if !pending.contains(id) {
                pending.insert(id)
                let gen = generation
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.prepare(entry, classic: sheet, generation: gen)
                    self?.lock.lock(); self?.pending.remove(id); self?.lock.unlock()
                }
            }
            lock.unlock()
            return nil
        }
        lock.unlock()
        guard atlas.frameCount == sheet.frameCount else { return nil }
        let built = makeTextures(atlas)
        lock.lock()
        textures[id] = built
        for t in built { hdTextures.add(t) }
        lock.unlock()
        return built
    }

    /// One GPU texture per sheet, carved into frames: a hull's NPCs batch,
    /// and each frame reports the original frame size.
    private func makeTextures(_ atlas: HDAtlas) -> [SKTexture] {
        let logical = CGSize(width: atlas.logicalWidth, height: atlas.logicalHeight)
        #if canImport(UIKit)
        let image = UIImage(cgImage: atlas.image, scale: CGFloat(atlas.image.width) / logical.width, orientation: .up)
        #else
        let image = NSImage(cgImage: atlas.image, size: logical)
        #endif
        let parent = SKTexture(image: image)
        parent.filteringMode = .linear
        return (0..<atlas.frameCount).map { i in
            let t = SKTexture(rect: atlas.normalizedRect(frame: i), in: parent)
            t.filteringMode = .linear
            return t
        }
    }

    /// Whether a hull drawn with `baseSpriteID` should skip the classic
    /// overlay `overlaySpriteID` (engine glow, lights, weapon glow, alt
    /// sprites). Those are pixel-matched to the classic art, so a model hull
    /// drops each one it doesn't replace with its own effect layer; the ones
    /// it does replace draw as usual (HD frames via `frames(for:)`), driven
    /// by the game exactly like the originals.
    func hidesOverlay(baseSpriteID: Int, overlaySpriteID: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard enabled, modelHulls[baseSpriteID] == true else { return false }
        return atlases[overlaySpriteID] == nil
    }

    /// HD textures always filter smoothly; the crisp-pixel setting is for
    /// the original pixel art.
    func isHD(_ texture: SKTexture?) -> Bool {
        guard let texture else { return false }
        lock.lock(); defer { lock.unlock() }
        return hdTextures.contains(texture)
    }

    // MARK: Debug / tools

    /// One enhancement's state, for the HD debug tools.
    struct EntryStatus: Identifiable {
        enum State: String { case ready, pending, failed, notPrepared = "not prepared" }
        var id: Int { spriteID }
        let spriteID: Int
        let origin: String
        let kind: GraphicsEnhancement.Kind
        let state: State
        /// Sheet + effect-layer atlases, bytes.
        let bytes: Int
        let pixelScale: Double?
        /// Effect layers it supplies, by name ("engine" …).
        let layers: [String]
    }

    struct Status {
        let enabled: Bool
        let maxScale: Double
        let entries: [EntryStatus]
        let problems: [String]
        var totalBytes: Int { entries.reduce(0) { $0 + $1.bytes } }
    }

    func status() -> Status {
        lock.lock(); defer { lock.unlock() }
        let entries = catalog.bySprite.values.sorted { $0.spriteID < $1.spriteID }.map { e -> EntryStatus in
            let overlayIDs = layouts?.overlays(forBase: e.spriteID) ?? [:]
            let layerIDs = overlayIDs.filter { atlases[$0.value] != nil }
            let bytes = (atlases[e.spriteID]?.byteCount ?? 0) + layerIDs.values.reduce(0) { $0 + (atlases[$1]?.byteCount ?? 0) }
            let state: EntryStatus.State = atlases[e.spriteID] != nil ? .ready
                : failed.contains(e.spriteID) ? .failed : pending.contains(e.spriteID) ? .pending : .notPrepared
            return EntryStatus(spriteID: e.spriteID, origin: e.origin, kind: e.descriptor.kind, state: state,
                               bytes: bytes, pixelScale: atlases[e.spriteID]?.pixelScale,
                               layers: layerIDs.keys.map(\.rawValue).sorted())
        }
        return Status(enabled: enabled, maxScale: maxScale, entries: entries, problems: catalog.problems)
    }

    /// The classic overlay sprite ids of the hull drawn with `baseSpriteID`.
    func overlayIDs(forBase baseSpriteID: Int) -> [GraphicsEnhancement.EffectLayer: Int] {
        lock.lock(); defer { lock.unlock() }
        if layouts == nil, let game { layouts = SpriteLayouts(game: game) }
        return layouts?.overlays(forBase: baseSpriteID) ?? [:]
    }

    /// Whether `spriteID` has HD art ready (its own enhancement or a model's
    /// effect layer).
    func isReady(_ spriteID: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && atlases[spriteID] != nil
    }

    /// Forget every prepared atlas and texture (and, with `disk`, the bake
    /// cache) so the next prewarm re-reads and re-renders everything.
    func reset(clearDiskCache disk: Bool) {
        lock.lock()
        atlases = [:]; textures = [:]; failed = []; pending = []; modelHulls = [:]; generation += 1
        lock.unlock()
        if disk { bakeCache?.removeAll() }
    }

    /// Release GPU textures (memory warning / system change). Atlases stay,
    /// so they rebuild instantly on next use.
    func evictTextures() {
        lock.lock(); defer { lock.unlock() }
        textures = [:]
    }
}
