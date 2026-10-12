#if os(macOS)
import SwiftUI
import SpriteKit
import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory

// MARK: - Plugin Editor run layer — public surface
//
// This folder (`app/NovaSwift/Editor/Run/`) turns any `ResourceCollection`
// (base game ⊕ the author's plugin layer) into playable, debuggable sessions
// WITHOUT ever touching the player's pilot saves.
//
//   EditorGameFactory.build(collection:base:flightTuning:systemID:shipID:)
//       async, off-main. Builds `NovaGame` + `Galaxy` (cheap: NovaGame decodes
//       lazily) and pre-decodes the sprites the first frame needs. Reuses a
//       dedicated sprite disk cache (never the player's real one — see
//       `EditorSpriteSync`) so a rebuild after an edit re-decodes only the
//       rlëD resources that actually changed.
//
//   GameHost.makeEditorHost(model:build:options:)
//       `@MainActor`. A sandbox `GameHost` for a chosen system + ship id
//       (+ outfit list, start pose, invulnerable flag, muted, hidden player).
//       Generalises `makeTrainingHost`: no pilot-save callbacks are wired, and
//       nothing is persisted.
//
//   EditorLivePreviewView(model: EditorPreviewModel)           — EditorLivePreviewView.swift
//       Embeddable (non-fullscreen) real-`GameScene` view of one system.
//       `EditorPreviewModel.update(collection:systemID:base:)` rebuilds
//       (debounced 300 ms) and swaps the scene in place, keeping the camera.
//
//   EditorTestRunView(collection:base:startSystem:startShip:onExit:)   — EditorTestRunView.swift
//       Full-window test game (real controls + HUD, landing stub, galaxy map +
//       hyperjump inside the edited galaxy) with a collapsible right-hand debug
//       panel (EditorDebugPanel.swift) built on `EditorTestSession`.

/// The expensive-to-make, host-independent half of a session: the game data and
/// catalog for one collection. `@unchecked Sendable` because `Galaxy` is a
/// reference type that is only ever used from the main actor after hand-off.
struct EditorBuild: @unchecked Sendable {
    let game: NovaGame
    let galaxy: Galaxy
    let collection: ResourceCollection
    /// Wall-clock cost of this build, for the perf readout.
    let totalMillis: Double
    /// …of which: syncing changed rlëD sprites into the editor cache.
    let spriteSyncMillis: Double
    /// …and warming (decoding) first-frame sprites.
    let warmMillis: Double
    /// How many rlëD resources differ from the base game (re-decoded this build).
    let changedSprites: Int
    /// The scenario's default start, resolved off-main during the build.
    var defaultStart: (systemID: Int, shipID: Int)? = nil
    /// Searchable debug-panel lists, built off-main when the caller asked for them.
    var catalogs: EditorCatalogs? = nil
}

/// Pre-built, immutable pick-lists for the debug panel (ships, outfits, …).
struct EditorCatalogs: Sendable {
    var ships: [EditorPick] = []
    var outfits: [EditorPick] = []
    var fleets: [EditorPick] = []
    var systems: [EditorPick] = []
    var missions: [EditorPick] = []
    var govts: [EditorPick] = []

    static func make(game: NovaGame) -> EditorCatalogs {
        EditorCatalogs(
            ships: game.ships().map { EditorPick(id: $0.id, title: $0.displayName, subtitle: "shïp") },
            outfits: game.outfits().map { EditorPick(id: $0.id, title: $0.outfitterDisplayName, subtitle: "oütf") },
            fleets: game.fleets().map { EditorPick(id: $0.id, title: $0.name.novaDisplayName, subtitle: "flët") },
            systems: game.systems().map { EditorPick(id: $0.id, title: $0.displayName, subtitle: "sÿst") },
            missions: game.missions().map { EditorPick(id: $0.id, title: $0.displayName, subtitle: "mïsn") },
            govts: game.govts().map { EditorPick(id: $0.id, title: $0.displayName, subtitle: "gövt") })
    }
}

enum EditorGameFactory {

    enum BuildError: LocalizedError {
        case noSystems
        case noShips
        var errorDescription: String? {
            switch self {
            case .noSystems: return "The collection has no star systems (sÿst)."
            case .noShips: return "The collection has no ships (shïp)."
            }
        }
    }

    /// Build the game + galaxy for `collection` off the main actor.
    ///
    /// - Parameters:
    ///   - base: the unmodified base game, used to find which rlëD sprites the
    ///     author changed. Pass `nil` to run without a disk cache (every sprite
    ///     decodes on demand — correct, slower).
    ///   - systemID / shipID: sprites for these are decoded eagerly so the first
    ///     frame doesn't hitch on the main thread. `nil` = the scenario default,
    ///     which is resolved here (off-main) and returned as `defaultStart`.
    ///   - catalogs: also build the debug panel's searchable lists off-main.
    static func build(collection: ResourceCollection,
                      base: ResourceCollection?,
                      flightTuning: FlightTuning,
                      systemID: Int?, shipID: Int?,
                      catalogs wantsCatalogs: Bool = false) async -> Result<EditorBuild, Error> {
        await Task.detached(priority: .userInitiated) {
            let t0 = DispatchTime.now().uptimeNanoseconds
            func ms(since t: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t) / 1_000_000 }

            var syncMs = 0.0, changed = 0
            let cache: SpriteDiskCache?
            if let base {
                let t = DispatchTime.now().uptimeNanoseconds
                let r = EditorSpriteSync.shared.sync(effective: collection, base: base)
                cache = r.cache; changed = r.changed
                syncMs = ms(since: t)
            } else {
                cache = nil
            }

            var game = NovaGame(collection, spriteCache: cache)
            game.iniStringOverrides = [:]
            guard !game.systems().isEmpty else { return .failure(BuildError.noSystems) }
            guard !game.ships().isEmpty else { return .failure(BuildError.noShips) }
            let galaxy = Galaxy(game: game, flightTuning: flightTuning)

            let tw = DispatchTime.now().uptimeNanoseconds
            let dflt = defaultStart(game: game)
            warm(game: game, systemID: systemID ?? dflt?.systemID, shipID: shipID ?? dflt?.shipID)
            let cats: EditorCatalogs? = wantsCatalogs ? EditorCatalogs.make(game: game) : nil
            let warmMs = ms(since: tw)

            let total = ms(since: t0)
            Log.data.info("EditorGameFactory.build: \(total, format: .fixed(precision: 1), privacy: .public) ms (sync \(syncMs, format: .fixed(precision: 1), privacy: .public), warm \(warmMs, format: .fixed(precision: 1), privacy: .public), \(changed, privacy: .public) changed sprite(s))")
            return .success(EditorBuild(game: game, galaxy: galaxy, collection: collection,
                                        totalMillis: total, spriteSyncMillis: syncMs,
                                        warmMillis: warmMs, changedSprites: changed,
                                        defaultStart: dflt, catalogs: cats))
        }.value
    }

    /// Touch (decode + memoise) the sprites the first frame of a session needs.
    /// Safe off-main: `NovaGame`'s caches are lock-guarded and shared by copies.
    static func warm(game: NovaGame, systemID: Int?, shipID: Int?) {
        if let systemID { _ = game.stellarObjects(in: systemID) }
        if let shipID {
            _ = game.shipSprite(shipID)
            _ = game.engineGlowSprite(shipID)
            _ = game.lightSprite(shipID)
            _ = game.weaponGlowSprite(shipID)
            _ = game.altSprite(shipID)
        }
    }

    /// A reasonable default start: the scenario's system/hull, else the first of each.
    static func defaultStart(game: NovaGame) -> (systemID: Int, shipID: Int)? {
        let sys = game.startingSystem()?.id ?? game.systems().first?.id
        let scenario = game.startingChar()
        let ship = scenario.flatMap { $0.shipID >= 128 ? $0.shipID : nil } ?? game.ships().first?.id
        guard let sys, let ship else { return nil }
        return (sys, ship)
    }
}

// MARK: - Sprite cache for edited rlëD resources

/// The app's real decoded-sprite disk cache is keyed by the on-disk base+plugin
/// files and by bare rlëD id, so an author's *edited* sprite under the same id
/// would be shadowed by (or, worse, poison) it. The editor therefore uses its
/// own cache directory and keeps it coherent by hand:
///
///  * the first use in a process wipes the directory (nothing stale survives
///    a relaunch);
///  * on each build, rlëD resources whose bytes differ from the base game are
///    decoded straight away and stored (overwriting the previous version), and
///    ids that were edited earlier but have since been reverted are restored
///    from the base — so unchanged sprites stay warm across rebuilds and only
///    the touched ones re-decode.
final class EditorSpriteSync: @unchecked Sendable {
    static let shared = EditorSpriteSync()
    private let lock = NSLock()
    private var cache: SpriteDiskCache?
    private var opened = false
    /// rlëD id → content hash currently stored for it, for ids that differ from base.
    private var tracked: [Int: Int] = [:]

    private static let subdirectory = "NovaSwift/EditorSprites"
    private static let fingerprint = "session"

    func sync(effective: ResourceCollection, base: ResourceCollection) -> (cache: SpriteDiskCache?, changed: Int) {
        lock.lock(); defer { lock.unlock() }
        if !opened {
            opened = true
            if let caches = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: false) {
                try? FileManager.default.removeItem(
                    at: caches.appendingPathComponent(Self.subdirectory, isDirectory: true))
            }
            cache = SpriteDiskCache(fingerprint: Self.fingerprint, subdirectory: Self.subdirectory)
        }
        guard let cache else { return (nil, 0) }

        // Which rlëD ids differ from the base?
        var changedNow: [Int: Resource] = [:]
        for (id, r) in effective.byType[NovaType.rleD] ?? [:] {
            if let b = base.resource(NovaType.rleD, id), b.data == r.data { continue }
            changedNow[id] = r
        }
        for (id, r) in changedNow {
            let h = r.data.hashValue
            guard tracked[id] != h else { continue }
            if let sheet = try? RLED.decode(r.data) { cache.store(id, sheet) }
            tracked[id] = h
        }
        // Edited earlier, back to base now: put the base decode back.
        for id in Array(tracked.keys) where changedNow[id] == nil {
            if let b = base.resource(NovaType.rleD, id), let sheet = try? RLED.decode(b.data) {
                cache.store(id, sheet)
            }
            tracked[id] = nil
        }
        return (cache, changedNow.count)
    }
}

// MARK: - Sandbox GameHost

/// How to start an editor sandbox session.
struct EditorHostOptions {
    var systemID: Int
    var shipID: Int
    /// The player's full outfit inventory (the "player inventory invariant": it
    /// owns hull DefaultItems AND stock weapons). `nil` = the hull's stock fittings.
    var outfits: [Int: Int]? = nil
    /// Start pose; `nil` = a little south of the system centre, at rest.
    var position: Vec2? = nil
    var angle: Double = 0
    var velocity: Vec2 = Vec2()
    /// Player can't be hurt (damage scale 0). The debug panel's god mode is a
    /// separate, live toggle.
    var invulnerable: Bool = false
    /// No sound (live preview).
    var muted: Bool = false
    /// Hide the player's ship sprite (live preview flies an invisible camera ship).
    var hidePlayer: Bool = false
    var shipName: String? = nil
}

extension GameHost {

    /// Build a sandbox host for the editor from an already-built `EditorBuild`.
    /// Wires none of the pilot-save callbacks and persists nothing, exactly like
    /// the tutorial's training host. Returns nil if the system/ship don't exist.
    static func makeEditorHost(model: AppModel, build: EditorBuild,
                               options o: EditorHostOptions) -> GameHost? {
        let game = build.game, galaxy = build.galaxy
        guard let ship = editorShip(game: game, galaxy: galaxy, shipID: o.shipID, outfits: o.outfits) else {
            return nil
        }
        let art = editorShipArt(game: game, shipID: o.shipID)
        let system = game.system(o.systemID) ?? game.startingSystem() ?? game.systems().first
        let systemID = system?.id ?? 0
        let planets = system.map { editorPlanets(game: game, systemID: $0.id) } ?? []
        let center = galaxy.systemContext(for: systemID).center
        ship.position = o.position ?? (center + Vec2(0, -700))
        ship.angle = o.angle
        ship.velocity = o.velocity
        if o.invulnerable { ship.invulnerable = true }

        let name = o.shipName ?? game.ship(o.shipID)?.displayName ?? "Test Ship"
        let host = GameHost(training: model, ship: ship, textures: art.textures,
                            engineTextures: art.engine, shipName: name, systemID: systemID,
                            planets: planets, systemName: system?.displayName ?? "",
                            game: game, galaxy: galaxy,
                            shieldTextures: art.shield, lightTextures: art.lights,
                            weaponGlowTextures: art.weaponGlow, altTextures: art.alt,
                            hullAnim: art.hullAnim,
                            playerDamageScale: o.invulnerable ? 0 : nil,
                            muted: o.muted)
        if o.hidePlayer { host.scene.editorSetPlayerVisible(false) }
        return host
    }

    /// The stock inventory a hull ships with (DefaultItems + resolved weapons/ammo).
    static func editorStockOutfits(game: NovaGame, shipID: Int) -> [Int: Int] {
        guard let res = game.ship(shipID) else { return [:] }
        return PilotEconomy.hullFittings(res, game: game)
    }

    static func editorShip(game: NovaGame, galaxy: Galaxy, shipID: Int, outfits: [Int: Int]?) -> Ship? {
        let inventory = outfits ?? editorStockOutfits(game: game, shipID: shipID)
        // Both include flags off: the inventory owns everything (see PilotEconomy.loadout).
        guard let ship = galaxy.makeLoadedShip(shipID, extraOutfits: inventory,
                                               includeDefaultItems: false,
                                               includeHullWeapons: false) else { return nil }
        ship.armor = ship.maxArmor
        ship.shield = ship.maxShield
        ship.fuel = ship.maxFuel
        return ship
    }

    struct EditorShipArt {
        var textures: [SKTexture] = [], engine: [SKTexture] = [], shield: [SKTexture] = []
        var lights: [SKTexture] = [], weaponGlow: [SKTexture] = [], alt: [SKTexture] = []
        var hullAnim = HullAnim()
    }

    static func editorShipArt(game: NovaGame, shipID: Int) -> EditorShipArt {
        var a = EditorShipArt()
        if let s = game.shipSprite(shipID) { a.textures = SpriteTextures.allFrames(from: s) }
        if let g = game.engineGlowSprite(shipID) { a.engine = SpriteTextures.allFrames(from: g) }
        let prefs = GameSettings.load()
        if prefs.runningLights, let l = game.lightSprite(shipID) { a.lights = SpriteTextures.allFrames(from: l) }
        if prefs.weaponEffects, let w = game.weaponGlowSprite(shipID) { a.weaponGlow = SpriteTextures.allFrames(from: w) }
        if let alt = game.altSprite(shipID) { a.alt = SpriteTextures.allFrames(from: alt) }
        if let b = game.shieldSprite(shipID) { a.shield = SpriteTextures.rotationFrames(from: b) }
        a.hullAnim = game.shan(shipID).map(HullAnim.init) ?? HullAnim()
        return a
    }

    /// The system's stellars as scene visuals (animated ones included), the same
    /// construction as the play-session host minus destroyed-stellar handling.
    static func editorPlanets(game: NovaGame, systemID: Int) -> [PlanetVisual] {
        game.stellarObjects(in: systemID).compactMap { entry in
            let spob = entry.spob
            let tex = entry.sprite.flatMap { SpriteTextures.rotationFrames(from: $0, rotationCount: 1).first }
            let radius = CGFloat(entry.sprite?.frameWidth ?? 48) / 2
            var visual = PlanetVisual(id: spob.id, name: spob.name,
                                      position: CGPoint(x: spob.x, y: -spob.y),
                                      texture: tex, radius: radius,
                                      government: spob.government,
                                      isUninhabited: spob.isUninhabited,
                                      isHypergate: spob.isHypergate, isWormhole: spob.isWormhole)
            let anim = GameScene.stellarAnimation(spob: spob, sheet: entry.sprite,
                                                  destroyed: game.spobDestroyedSprite(spob.id))
            visual.frames = anim.frames
            visual.destroyedFrames = anim.destroyedFrames
            visual.animator = anim.animator
            visual.animatesOnlyWhenDestroyed = spob.animatesOnlyWhenDestroyed
            return visual
        }
    }
}
#endif
