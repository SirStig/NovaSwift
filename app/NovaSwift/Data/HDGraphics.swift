import Foundation
import SpriteKit
import SceneKit
import Metal
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
    private var presentation: GameSettings.HullPresentation = .sprites
    private var modelDetail: GameSettings.ModelDetail = .full
    private var simpleLighting = false
    /// Live 3D: each model hull's classic sheet (noted by `prepare`, for fitting).
    private var liveSheets: [Int: SpriteSheet] = [:]
    /// Live 3D: each model hull's fit and light level, by base sprite id;
    /// kept when its model is evicted, so a reload measures nothing.
    private var liveFits: [Int: LiveFit] = [:]
    /// Live 3D: loaded models at the current detail, least recently used first
    /// in `liveModelOrder`. Only the hulls actually flying are kept, up to
    /// `liveModelCap`, so memory follows the system, not the whole pack.
    private var liveModels: [Int: LiveModel] = [:]
    private var liveModelOrder: [Int] = []
    private var liveLoading: Set<Int> = []
    private var liveFailed: Set<Int> = []
    private var generation = 0
    private var atlases: [Int: HDAtlas] = [:]
    private var textures: [Int: [SKTexture]] = [:]
    /// Shield bubbles for hulls whose pack asks for one (`shield`), by base sprite id.
    private var shieldAtlases: [Int: HDAtlas] = [:]
    private var shieldTextures: [Int: [SKTexture]] = [:]
    private var pending: Set<Int> = []
    private var failed: Set<Int> = []
    /// Base sprite id of each hull drawn by a model → whether it replaces the
    /// classic overlays (`overlays: hide`, the model default).
    private var modelHulls: [Int: Bool] = [:]
    /// UI portraits of model hulls (front three-quarter), transparent and on black.
    private var portraits: [Int: CGImage] = [:]
    private var portraitsOnBlack: [Int: CGImage] = [:]
    /// Portraits over their classic shipyard picture's government-coloured backdrop.
    private var portraitsOnBackdrop: [String: CGImage] = [:]
    private var tintedPortraits: [Int: CGImage] = [:]
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
        atlases = [:]; textures = [:]; pending = []; failed = []; modelHulls = [:]; portraits = [:]; portraitsOnBlack = [:]; portraitsOnBackdrop = [:]; tintedPortraits = [:]
        shieldAtlases = [:]; shieldTextures = [:]
        dropLiveState()
        apply(settings)
        for p in catalog.problems { NovaSwiftKit.Log.graphics.error("HD pack: \(p, privacy: .public)") }
        if !catalog.isEmpty {
            NovaSwiftKit.Log.graphics.info("HD: \(catalog.bySprite.count, privacy: .public) enhanced sprite(s) available")
        }
    }

    /// Follow the Settings toggles. A detail change rebuilds on next prewarm.
    func update(settings: GameSettings) {
        lock.lock(); defer { lock.unlock() }
        let oldScale = maxScale, oldDetail = modelDetail
        apply(settings)
        if oldScale != maxScale { atlases = [:]; textures = [:]; failed = []; modelHulls = [:]; shieldAtlases = [:]; shieldTextures = [:]; generation += 1 }
        // Models reload at the new detail as ships need them.
        if oldDetail != modelDetail { liveModels = [:]; liveModelOrder = [] }
    }

    private func apply(_ s: GameSettings) {
        enabled = s.hdGraphics
        maxScale = Double(min(4, max(1, s.hdDetail)))
        presentation = s.hullPresentation
        modelDetail = s.modelDetail
        simpleLighting = s.liveLighting == .simple
    }

    private func dropLiveState() {
        liveSheets = [:]; liveFits = [:]; liveModels = [:]; liveModelOrder = []; liveLoading = []; liveFailed = []
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && !catalog.isEmpty
    }

    /// Prepare every enhancement whose classic sprite is an `rlëD` (the
    /// sheets the loader can open by id alone) all the way to GPU textures,
    /// so the game opens with everything in place — nothing pops in later.
    /// PICT-sheet sprites are prepared on first sight instead (logged as
    /// "built on demand"). Call off the main thread.
    func prewarm(progress: (_ done: Int, _ total: Int) -> Void) {
        lock.lock()
        guard enabled, let game else { lock.unlock(); return }
        let entries = catalog.bySprite.values.sorted { $0.spriteID < $1.spriteID }
        let gen = generation
        lock.unlock()
        let start = Date()
        progress(0, entries.count)
        // Across the cores (one left for the UI): cached bakes decode in
        // parallel; a model that has to be baked waits its turn for the renderer.
        var uploads: [SKTexture] = []
        var done = 0
        let gather = NSLock()
        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            for i in stride(from: w, to: entries.count, by: workers) {
                let e = entries[i]
                var mine: [SKTexture] = []
                if game.resources.resource(NovaType.rleD, e.spriteID) != nil,
                   let sheet = game.spriteSheet(spriteID: e.spriteID, maskID: 0, frameWidth: 0, frameHeight: 0, frameCount: 0) {
                    prepare(e, classic: sheet, generation: gen)
                    mine += texturesIfReady(id: e.spriteID, frameCount: sheet.frameCount)
                    if let shield = shieldFrames(baseSpriteID: e.spriteID) { mine += shield.prefix(1) }
                }
                gather.lock()
                uploads += mine; done += 1
                progress(done, entries.count)
                gather.unlock()
            }
        }
        // The effect layers baked with each hull (engine glows, lights) are
        // sheets of their own: build them too, or the first ship of a type to
        // appear builds them mid-frame (the 30–140 ms `sync.npcs` spikes).
        lock.lock()
        let layerSheets = atlases.filter { textures[$0.key] == nil }
        lock.unlock()
        for (id, atlas) in layerSheets { uploads += texturesIfReady(id: id, frameCount: atlas.frameCount) }
        // Push them to the GPU now rather than on the first frame that draws them.
        if !uploads.isEmpty {
            let done = DispatchSemaphore(value: 0)
            SKTexture.preload(uploads) { done.signal() }
            // Never let the upload hold the loading screen hostage: if SpriteKit
            // doesn't call back, the textures still upload on first use.
            if done.wait(timeout: .now() + 10) == .timedOut {
                NovaSwiftKit.Log.graphics.error("HD: GPU preload didn't report back in 10 s — continuing")
            }
        }
        let s = stats()
        NovaSwiftKit.Log.graphics.notice("HD: ready — \(s.sheets, privacy: .public) sheet(s), \(s.atlasMB, privacy: .public) MB, \(s.textureSheets, privacy: .public) on GPU, in \(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) ms")
    }

    /// Build (once) the GPU textures for a prepared sheet; the first frame
    /// stands for the whole sheet, which shares one texture.
    private func texturesIfReady(id: Int, frameCount: Int) -> [SKTexture] {
        lock.lock()
        if let built = textures[id] { lock.unlock(); return Array(built.prefix(1)) }
        guard let atlas = atlases[id], atlas.frameCount == frameCount else { lock.unlock(); return [] }
        lock.unlock()
        let built = makeTextures(atlas)
        lock.lock()
        textures[id] = built
        for t in built { hdTextures.add(t) }
        lock.unlock()
        return Array(built.prefix(1))
    }

    /// For the performance log.
    func stats() -> (enabled: Bool, sheets: Int, atlasMB: Int, textureSheets: Int) {
        lock.lock(); defer { lock.unlock() }
        let bytes = atlases.values.reduce(0) { $0 + $1.byteCount } + shieldAtlases.values.reduce(0) { $0 + $1.byteCount }
        return (enabled && !catalog.isEmpty, atlases.count, bytes / 1_048_576, textures.count)
    }

    // MARK: Live 3D

    /// Remember a model hull's classic sheet: live 3D fits the model to it
    /// when a ship first needs one. Nothing is measured or loaded here, so
    /// turning live 3D on costs nothing until ships appear.
    private func noteLiveSheet(_ e: ResolvedGraphicsEnhancement, classic: SpriteSheet) {
        guard e.descriptor.kind == .model, e.descriptor.live != false else { return }
        lock.lock(); liveSheets[e.spriteID] = classic; lock.unlock()
    }

    /// A live 3D hull for a ship whose hull is a model, or nil to draw the
    /// sprite: the presentation is sprites, the hull has no model (or its
    /// sprite hasn't been prepared yet), or its model is still loading
    /// (asked for here; a later call gets it).
    /// Call from the scene's main thread; how many to draw is the scene's
    /// call (`LiveHullBudget`).
    func makeLiveHull(baseSpriteID id: Int) -> LiveHull? {
        lock.lock()
        guard enabled, presentation == .live, let e = catalog.bySprite[id], let classic = liveSheets[id] else {
            lock.unlock(); return nil
        }
        guard let model = liveModels[id], let fit = liveFits[id] else {
            if !liveLoading.contains(id), !liveFailed.contains(id) {
                liveLoading.insert(id)
                let gen = generation, detail = modelDetail
                if layouts == nil, let game { layouts = SpriteLayouts(game: game) }
                let layout = layouts?.layout(for: classic)
                lock.unlock()
                loadLiveModel(e, classic: classic, layout: layout, detail: detail, generation: gen)
            } else {
                lock.unlock()
            }
            return nil
        }
        if let i = liveModelOrder.firstIndex(of: id) { liveModelOrder.remove(at: i) }
        liveModelOrder.append(id)
        let simple = simpleLighting
        lock.unlock()
        return LiveHull(template: model.node, descriptor: e.descriptor, calibration: fit.calibration,
                        overlayLayers: model.overlayLayers, size: fit.size, simpleLighting: simple)
    }

    /// Load (and simplify) a hull's model off the main thread, and fit it on
    /// first use: the calibration renders a few frames under the bake lock,
    /// then is cached on disk, so this is a one-time cost per hull.
    private func loadLiveModel(_ e: ResolvedGraphicsEnhancement, classic: SpriteSheet, layout: BakeLayout?,
                               detail: GameSettings.ModelDetail, generation gen: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let layers = Set(overlayTargets(forBase: e.spriteID).map(\.target.layer))
            let start = Date()
            lock.lock(); var fit = liveFits[e.spriteID]; lock.unlock()
            var loaded: SCNNode?
            do {
                guard let layout else { throw HDAssetPipeline.PipelineError.unreadable }
                let node = try ModelLoader.load(e.source)
                if fit == nil {   // measured on the full model, before any simplifying
                    let c = try HDAssetPipeline.liveCalibration(for: e, classic: classic, layout: layout,
                                                                model: node, cache: bakeCache)
                    fit = LiveFit(calibration: c, size: CGSize(width: layout.frameWidth, height: layout.frameHeight))
                }
                if let cells = detail.cells {
                    let t = MeshSimplifier.simplify(node, cells: cells)
                    NovaSwiftKit.Log.graphics.info("HD: live model \(e.spriteID, privacy: .public) simplified \(t.before, privacy: .public) → \(t.after, privacy: .public) triangles")
                }
                loaded = node
            } catch {
                NovaSwiftKit.Log.graphics.error("HD: live model \(e.spriteID, privacy: .public) unavailable: \(String(describing: error), privacy: .public)")
            }
            lock.lock(); defer { lock.unlock() }
            liveLoading.remove(e.spriteID)
            guard gen == generation else { return }
            guard let loaded, let fit else { liveFailed.insert(e.spriteID); return }
            liveFits[e.spriteID] = fit
            guard detail == modelDetail else { return }   // detail changed meanwhile: the next ask reloads
            liveModels[e.spriteID] = LiveModel(node: loaded, overlayLayers: layers)
            liveModelOrder.append(e.spriteID)
            while liveModelOrder.count > Self.liveModelCap { liveModels[liveModelOrder.removeFirst()] = nil }
            NovaSwiftKit.Log.graphics.info("HD: live model \(e.spriteID, privacy: .public) ready in \(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) ms")
        }
    }

    /// Live 3D counts for the dev console (`hd 3d`).
    func liveStatus() -> (fitted: Int, loaded: Int, failed: Int) {
        lock.lock(); defer { lock.unlock() }
        return (liveFits.count, liveModels.count, liveFailed.count)   // fitted = measured at least once
    }

    /// The most live hulls this device is ever given (`LiveHullBudget.ceiling`).
    static let liveCeiling: Int = {
        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        #if os(macOS)
        let device = MTLCreateSystemDefaultDevice()
        return LiveHullBudget.ceiling(mobile: false, appleGPU: device?.supportsFamily(.apple7) ?? false,
                                      lowPowerGPU: device?.isLowPower ?? true, memoryGB: memoryGB)
        #else
        return LiveHullBudget.ceiling(mobile: true, appleGPU: true, lowPowerGPU: false, memoryGB: memoryGB)
        #endif
    }()

    /// Distinct live models kept loaded. Ships already flying keep theirs
    /// (a live hull holds its own clone); an evicted type reloads on demand.
    static let liveModelCap: Int = {
        #if os(macOS)
        return liveCeiling >= 10 ? 16 : 8
        #else
        return 6
        #endif
    }()

    private func prepare(_ e: ResolvedGraphicsEnhancement, classic: SpriteSheet, generation gen: Int) {
        noteLiveSheet(e, classic: classic)
        lock.lock()
        if atlases[e.spriteID] != nil || failed.contains(e.spriteID) { lock.unlock(); return }
        let signpost = PerfMonitor.signposter.beginInterval("HD prepare", id: PerfMonitor.signposter.makeSignpostID(), "sprite \(e.spriteID)")
        defer { PerfMonitor.signposter.endInterval("HD prepare", signpost) }
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
            // A shield bubble when the pack asks for one, one frame per heading.
            if let color = e.descriptor.shield, let base = made[e.spriteID],
               let shield = HDAssetPipeline.shield(for: e, hull: base, frames: layout.framesPerSet, color: color, cache: bakeCache) {
                lock.lock()
                if gen == generation { shieldAtlases[e.spriteID] = shield }
                lock.unlock()
            }
            // Hull models also get a UI portrait (shipyard, hail, target display).
            let isHull = layouts?.isHull(e.spriteID) ?? false
            if isHull, let portrait = try? HDAssetPipeline.portrait(for: e, cache: bakeCache) {
                lock.lock()
                if gen == generation { portraits[e.spriteID] = portrait }
                lock.unlock()
            }
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
            // The classic art shows until then — a visible pop-in, so log it.
            if !pending.contains(id) {
                pending.insert(id)
                NovaSwiftKit.Log.graphics.warning("HD: sprite \(id, privacy: .public) wasn't prepared on the loading screen — building it now (classic art shows until it's ready)")
                PerfMonitor.shared.noteHDOnDemand(spriteID: id)
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

    /// The HD shield bubble of the hull drawn with `baseSpriteID`, one frame
    /// per heading, or nil (HD off, no shield asked for, not ready yet).
    func shieldFrames(baseSpriteID id: Int) -> [SKTexture]? {
        lock.lock()
        guard enabled else { lock.unlock(); return nil }
        if let built = shieldTextures[id] { lock.unlock(); return built }
        guard let atlas = shieldAtlases[id] else { lock.unlock(); return nil }
        lock.unlock()
        let built = makeTextures(atlas)
        lock.lock()
        shieldTextures[id] = built
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

    /// One frame of a sheet's HD art as an image (for UI panels — the target
    /// display, shipyard pictures), or nil when HD isn't on / ready for it.
    /// Larger than the classic frame by `pixelScale`; callers scale to fit.
    func frameImage(for sheet: SpriteSheet, frame: Int) -> CGImage? {
        guard let id = sheet.sourceSpriteID else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard enabled, let atlas = atlases[id], frame >= 0, frame < atlas.frameCount else { return nil }
        return atlas.frameImage(frame)
    }

    /// The HD UI portrait for a hull's base sprite: front three-quarter,
    /// transparent (`onBlack: false`, for the red target silhouette) or on
    /// black like the original shipyard art (`onBlack: true`). nil when HD is
    /// off or the hull has no model.
    func portrait(baseSpriteID: Int, onBlack: Bool) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard enabled, let p = portraits[baseSpriteID] else { return nil }
        guard onBlack else { return p }
        if let cached = portraitsOnBlack[baseSpriteID] { return cached }
        guard let ctx = HDAtlas.makeContext(width: p.width, height: p.height) else { return p }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: p.width, height: p.height))
        ctx.draw(p, in: CGRect(x: 0, y: 0, width: p.width, height: p.height))
        let out = ctx.makeImage() ?? p
        portraitsOnBlack[baseSpriteID] = out
        return out
    }

    /// The HD portrait on the coloured gradient behind `classic` (the hull's
    /// original shipyard picture), so factions still read at a glance.
    /// `key` names the classic picture (e.g. its PICT id) for caching.
    func portrait(baseSpriteID: Int, over classic: CGImage, key: Int) -> CGImage? {
        let cacheKey = "\(baseSpriteID)-\(key)"
        lock.lock()
        let cached = portraitsOnBackdrop[cacheKey]
        lock.unlock()
        if let cached { return cached }
        guard let p = portrait(baseSpriteID: baseSpriteID, onBlack: false),
              let out = PortraitBackdrop.composite(p, over: classic) else { return nil }
        lock.lock(); portraitsOnBackdrop[cacheKey] = out; lock.unlock()
        return out
    }

    /// The HD portrait recoloured like a classic pre-tinted picture (the main
    /// menu's targeting PICT): its brightness, in the classic picture's
    /// average lit colour, on black — so it composites additively the same way.
    func tintedPortrait(baseSpriteID: Int, like classic: CGImage) -> CGImage? {
        lock.lock()
        let cached = tintedPortraits[baseSpriteID]
        lock.unlock()
        if let cached { return cached }
        guard let p = portrait(baseSpriteID: baseSpriteID, onBlack: false) else { return nil }
        // The classic picture's lit colour.
        func pixels(_ img: CGImage) -> (CGContext, UnsafeMutablePointer<UInt8>)? {
            guard let ctx = HDAtlas.makeContext(width: img.width, height: img.height), let d = ctx.data else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            return (ctx, d.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * img.height))
        }
        guard let (cctx, cp) = pixels(classic), let (pctx, pp) = pixels(p) else { return nil }
        var sum = SIMD3<Double>(0, 0, 0), n = 0.0
        for y in 0..<classic.height {
            for x in 0..<classic.width {
                let i = y * cctx.bytesPerRow + x * 4
                let c = SIMD3(Double(cp[i]), Double(cp[i + 1]), Double(cp[i + 2])) / 255
                let l = max(c.x, c.y, c.z)
                if l > 0.2 { sum += c; n += 1 }
            }
        }
        var tint = n > 0 ? sum / n : SIMD3(1, 0.25, 0.2)
        tint /= max(tint.x, tint.y, tint.z, 0.01)
        for y in 0..<p.height {
            for x in 0..<p.width {
                let i = y * pctx.bytesPerRow + x * 4
                // Premultiplied: luminance already carries coverage → on black.
                let l = (0.3 * Double(pp[i]) + 0.59 * Double(pp[i + 1]) + 0.11 * Double(pp[i + 2])) / 255
                let v = min(1, l * 1.35)
                pp[i] = UInt8(v * tint.x * 255); pp[i + 1] = UInt8(v * tint.y * 255)
                pp[i + 2] = UInt8(v * tint.z * 255); pp[i + 3] = 255
            }
        }
        guard let out = pctx.makeImage() else { return nil }
        lock.lock(); tintedPortraits[baseSpriteID] = out; lock.unlock()
        return out
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
        atlases = [:]; textures = [:]; failed = []; pending = []; modelHulls = [:]; shieldAtlases = [:]; shieldTextures = [:]; generation += 1
        dropLiveState()
        lock.unlock()
        if disk { bakeCache?.removeAll() }
    }

    /// Release GPU textures (memory warning / system change). Atlases stay,
    /// so they rebuild instantly on next use.
    func evictTextures() {
        lock.lock(); defer { lock.unlock() }
        if !textures.isEmpty { PerfMonitor.shared.noteEviction("HD textures (\(textures.count) sheets)") }
        textures = [:]; shieldTextures = [:]
    }
}

/// A model hull's live-drawing fit, and the frame size it's fitted to.
private struct LiveFit {
    let calibration: LiveHullCalibration
    let size: CGSize
}

/// A loaded live model (at the current detail) and the effect layers its
/// hull has classic overlays for (those glow as their own baked sheets).
private struct LiveModel {
    let node: SCNNode
    let overlayLayers: Set<GraphicsEnhancement.EffectLayer>
}
