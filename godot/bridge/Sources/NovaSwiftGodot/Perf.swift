// Plain-Swift support for the bridge's performance section (`// MARK: Performance` in
// NovaWorld.swift): the cross-launch decoded-sprite cache the Apple app has had since the
// loading-performance pass, the per-system sprite manifest, and the background decode that
// runs while the player is docked or hyperjumping so the next system's art is already warm
// (decoded in the NovaGame caches) when the world is rebuilt.
//
// No game logic here - only which resources a system draws and when to decode them.

import Foundation
import NovaSwiftKit

enum PerfSupport {
    /// `NovaGame` with a persistent decoded-sprite cache attached (the Apple `applyMerged`), keyed by the
    /// data set's fingerprint plus the plug-in load order. Kept in its own cache folder so the Godot
    /// frontend and the Apple app (which prunes every fingerprint but its own) never evict each other.
    static func makeGame(_ collection: ResourceCollection, baseDir: URL) -> NovaGame {
        NovaGame(collection, spriteCache: diskCache(baseDir: baseDir))
    }

    static func diskCache(baseDir: URL) -> SpriteDiskCache? {
        let rt = PluginRuntime.shared
        let pluginDirs = rt.searchedDirs.map { $0.standardizedFileURL.resolvingSymlinksInPath().path + "/" }
        let base = GameLibrary.discoverResourceFiles(in: baseDir).filter { f in
            let p = f.standardizedFileURL.resolvingSymlinksInPath().path
            return !pluginDirs.contains { p.hasPrefix($0) }
        }
        let plugins = rt.plugins
        var fp = GameLibrary.fingerprint(baseFiles: base, plugins: plugins, flatPluginOrder: true)
        // The merge order decides which file wins an override; `flatPluginOrder: true` sorts it away,
        // so key the real order and enabled set in as well (FNV-1a, stable across launches).
        var h: UInt64 = 0xcbf29ce484222325
        for p in plugins where p.isEnabled {
            for b in p.id.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            h = (h ^ 0x7c) &* 0x100000001b3
        }
        fp += "-" + String(h, radix: 16)
        return SpriteDiskCache(fingerprint: fp, subdirectory: "NovaSwift/GodotDecodedSprites")
    }

    // MARK: Sprite kinds (mirror `SpriteKind` in NovaWorld.swift and FlightSprites.gd)

    static let ship = 0, engineGlow = 1, shield = 2, lights = 3, weaponGlow = 4, spob = 5,
               spobDestroyed = 6, weapon = 7, boom = 8, asteroid = 9, starfield = 10, shipAlt = 11

    /// Decode one sheet through the `NovaGame` caches (what `spriteInfo` / `spriteRGBA` read).
    static func warm(_ game: NovaGame, kind: Int, id: Int) {
        switch kind {
        case ship:          _ = game.shipSprite(id)
        case engineGlow:    _ = game.engineGlowSprite(id)
        case shield:        _ = game.shieldSprite(id)
        case lights:        _ = game.lightSprite(id)
        case weaponGlow:    _ = game.weaponGlowSprite(id)
        case spob:          _ = game.spobSprite(id)
        case spobDestroyed: _ = game.spobDestroyedSprite(id)
        case weapon:        _ = game.weaponSprite(spinID: id)
        case boom:          _ = game.boomSprite(id)
        case asteroid:      _ = game.asteroidSprite(id)
        case starfield:     _ = game.starfieldSprite()
        case shipAlt:       _ = game.altSprite(id)
        default: break
        }
    }

    /// Every `(kind, id)` the flight view will ask for in `systemID`: its stellars (and wrecks), rock
    /// types, the star tile, the player's hull and the hulls of everything its `düde` / `përs` tables
    /// can spawn, each with its shän overlay layers. Ordered most-visible first. Resources with no art
    /// are harmless - the frontend caches the miss.
    static func manifest(game: NovaGame, systemID: Int, playerShip: Int?) -> [Int32] {
        var out: [Int32] = []
        var seen = Set<Int>()
        func add(_ kind: Int, _ id: Int) {
            guard seen.insert(kind &* 1_000_003 &+ id).inserted else { return }
            out.append(Int32(kind)); out.append(Int32(id))
        }
        func addShip(_ id: Int) {
            guard id >= 128 else { return }
            add(ship, id); add(engineGlow, id); add(lights, id); add(weaponGlow, id)
            add(shield, id); add(shipAlt, id)
        }
        add(starfield, 0)
        if let p = playerShip { addShip(p) }
        guard let sys = game.system(systemID) else { return out }
        for sid in sys.spobs {
            add(spob, sid)
            if game.spob(sid)?.destroyedGraphicSpinID != nil { add(spobDestroyed, sid) }
        }
        for t in sys.asteroidTypeIDs where (128..<144).contains(t) { add(asteroid, t) }
        for (dudeID, _) in sys.spawns {
            for s in game.dude(dudeID)?.ships ?? [] { addShip(s.shipID) }
        }
        for pid in sys.pinnedPersons + sys.persons.map(\.id) {
            if let p = game.pers(pid) { addShip(p.shipType) }
        }
        return out
    }
}

/// Decodes a manifest on a background thread, in order, publishing how many entries are done so the
/// frontend only uploads (and asks the bridge for) sprites that are already warm.
final class SpritePrewarmer: @unchecked Sendable {
    private let lock = NSLock()
    private var token = 0
    private var done = 0
    private var total = 0

    /// Start decoding `manifest` (flat `[kind, id, ...]`); supersedes any run in flight.
    func start(game: NovaGame, manifest: [Int32]) {
        lock.lock()
        token += 1
        let mine = token
        done = 0
        total = manifest.count / 2
        lock.unlock()
        let thread = Thread { [self] in
            var i = 0
            while i + 1 < manifest.count {
                lock.lock(); let live = token == mine; lock.unlock()
                if !live { return }
                PerfSupport.warm(game, kind: Int(manifest[i]), id: Int(manifest[i + 1]))
                i += 2
                lock.lock(); if token == mine { done = i / 2 }; lock.unlock()
            }
        }
        thread.qualityOfService = .userInitiated
        thread.stackSize = 4 << 20
        thread.start()
    }

    /// Entries finished for the latest run.
    var progress: Int { lock.lock(); defer { lock.unlock() }; return done }
}
