// NovaWorld — the Godot-visible façade over the NOVA Swift simulation.
//
// GDScript talks to exactly this class. It owns a `NovaSwiftEngine.World` and
// forwards a frame of Godot input into the engine's `ControlIntent`, ticks the
// sim with `step`, and hands entity state back out in packed arrays the scene
// can render cheaply. NO game logic lives here — anything past marshalling is a
// bug and belongs in the engine, where the Apple app inherits it too.
//
// Method names below are camelCase in Swift; SwiftGodot exposes them to GDScript
// in snake_case (`makeDemoWorld` → `make_demo_world`). The vertical-slice script
// godot/Main.gd calls the snake_case names.
//
// SwiftGodot version assumptions to confirm on the first on-toolchain build
// (see godot/README.md — this has not yet been compiled):
//   1. Packed arrays construct from their Swift element arrays in one bulk copy —
//      `PackedFloat32Array([Float])`, `PackedInt32Array([Int32])`,
//      `PackedByteArray([UInt8])`, `PackedStringArray([String])`.
//   2. `@Callable` methods are exposed to GDScript in snake_case.
// Both are current SwiftGodot behaviour; if a pinned version differs, the fixes
// are mechanical and local to this file.
//
// See docs/GODOT_LAYER.md.

import SwiftGodot
import NovaSwiftEngine
import NovaSwiftKit

@Godot
class NovaWorld: Node2D {

    // MARK: Engine state

    private var world: World?
    private var galaxy: Galaxy?
    private var game: NovaGame?
    private var intent = ControlIntent()

    // MARK: World setup

    /// Build a bare physics world with a synthetic player ship and a few drifting
    /// NPCs. Runs with **no EV Nova data**, so the slice is playable immediately
    /// and proves the whole bridge end-to-end.
    @Callable
    func makeDemoWorld() {
        let player = Ship(
            name: "Player",
            stats: ShipStats(speed: 300, acceleration: 300, turnRate: 100),
            position: Vec2(0, 0)
        )
        let w = World(player: player)

        // A ring of drifting hulls so there's something to fly around. They have
        // no AI brain (no data-driven behaviour off real `düde` tables), so they
        // simply coast — enough to prove multi-entity readback + rendering.
        let count = 6
        for i in 0..<count {
            let angle = (Double(i) / Double(count)) * 2.0 * Double.pi
            let radius = 420.0
            let npc = Ship(
                name: "Drifter \(i + 1)",
                stats: ShipStats(speed: 220, acceleration: 160, turnRate: 70),
                position: Vec2(sin(angle) * radius, cos(angle) * radius),
                angle: angle
            )
            // Give each a gentle tangential drift so the scene isn't static.
            npc.velocity = Vec2(cos(angle) * 30.0, -sin(angle) * 30.0)
            _ = w.addNPC(npc)
        }

        self.world = w
        self.galaxy = nil
        self.game = nil
        self.intent = ControlIntent()
    }

    /// Discover + merge the player's own EV Nova data (BYO-data, same as the
    /// Apple app). Returns false if the directory holds no readable game data.
    @Callable
    func loadGame(baseDir: String) -> Bool {
        let base = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: baseDir))
        guard let collection = try? GameLibrary.merge(baseFiles: base) else { return false }
        let g = NovaGame(collection)
        self.game = g
        self.galaxy = Galaxy(game: g)
        return true
    }

    /// After `loadGame`, populate a real system with NPCs from its `düde`/`flët`
    /// spawn table via `GameSession.makeWorld`. Pass a negative id to use the
    /// data's starting system. Returns false if no game is loaded.
    @Callable
    func makeWorld(systemID: Int) -> Bool {
        guard let game = self.game else { return false }
        let galaxy = self.galaxy ?? Galaxy(game: game)
        self.galaxy = galaxy

        let sysID = systemID >= 0 ? systemID : (game.startingSystem()?.id ?? 128)
        let player = galaxy.makeShip(128, government: independentGovt, at: Vec2())
            ?? Ship(name: "Player", stats: ShipStats(speed: 300, acceleration: 300, turnRate: 100))

        let (w, _) = GameSession.makeWorld(game: game, systemID: sysID, player: player, galaxy: galaxy)
        self.world = w
        self.intent = ControlIntent()
        return true
    }

    // MARK: Input

    /// Map one frame of Godot input onto the engine's `ControlIntent`. Applied to
    /// the world at the next `step`.
    @Callable
    func setIntent(turnLeft: Bool, turnRight: Bool, thrust: Bool, reverse: Bool,
                   afterburner: Bool, firePrimary: Bool, fireSecondary: Bool) {
        var i = ControlIntent()
        i.turnLeft = turnLeft
        i.turnRight = turnRight
        i.thrust = thrust
        i.reverse = reverse
        i.afterburner = afterburner
        i.firePrimary = firePrimary
        i.fireSecondary = fireSecondary
        self.intent = i
    }

    // MARK: Tick

    /// Advance the simulation by `dt` seconds — the same `World.step` the Apple
    /// app and the headless `novaswift-extract ai` harness drive.
    @Callable
    func step(dt: Double) {
        guard let world = self.world else { return }
        world.intent = self.intent
        world.step(dt)
    }

    // MARK: Player readback

    @Callable func playerPosition() -> Vector2 {
        guard let p = world?.player else { return Vector2(x: 0, y: 0) }
        return Vector2(x: Float(p.position.x), y: Float(p.position.y))
    }

    @Callable func playerVelocity() -> Vector2 {
        guard let p = world?.player else { return Vector2(x: 0, y: 0) }
        return Vector2(x: Float(p.velocity.x), y: Float(p.velocity.y))
    }

    /// Engine heading in radians (0 = up / north, increasing clockwise).
    @Callable func playerAngle() -> Double {
        world?.player.angle ?? 0
    }

    @Callable func playerShieldFraction() -> Double {
        guard let p = world?.player, p.maxShield > 0 else { return 0 }
        return max(0, min(1, p.shield / p.maxShield))
    }

    @Callable func playerArmorFraction() -> Double {
        guard let p = world?.player, p.maxArmor > 0 else { return 0 }
        return max(0, min(1, p.armor / p.maxArmor))
    }

    @Callable func playerIsAlive() -> Bool {
        world?.player.isAlive ?? false
    }

    // MARK: All-ship readback

    /// Number of live ships this frame (player + living NPCs).
    @Callable func shipCount() -> Int {
        guard let world = self.world else { return 0 }
        return 1 + world.npcs.filter { $0.isAlive }.count
    }

    /// Every live ship packed as `[x, y, angle, kind]` per ship, player first.
    /// `kind`: 0 = player, 1 = NPC, 2 = disabled NPC hulk. One flat array keeps
    /// the per-frame crossing cheap — GDScript strides it by 4.
    @Callable func shipTransforms() -> PackedFloat32Array {
        guard let world = self.world else { return PackedFloat32Array() }
        var flat: [Float] = []

        func push(_ x: Double, _ y: Double, _ a: Double, _ kind: Float) {
            flat.append(Float(x)); flat.append(Float(y)); flat.append(Float(a)); flat.append(kind)
        }

        let p = world.player
        push(p.position.x, p.position.y, p.angle, 0)
        for npc in world.npcs where npc.isAlive {
            push(npc.position.x, npc.position.y, npc.angle, npc.disabled ? 2 : 1)
        }
        return PackedFloat32Array(flat)
    }

    /// One string per `WorldEvent` produced this step (the case name, e.g.
    /// `weaponFired`, `shipDestroyed`), for sound/FX hooks. Uses the case-name
    /// prefix of the reflected value so new engine event kinds surface without a
    /// bridge change.
    @Callable func drainEvents() -> PackedStringArray {
        guard let world = self.world else { return PackedStringArray() }
        let names = world.events.map { String(String(describing: $0).prefix { $0 != "(" }) }
        return PackedStringArray(names)
    }

    // MARK: Real-data render queries
    //
    // All nil-safe: they return empty/sentinel values in the data-free demo world,
    // so the frontend can call them unconditionally and fall back to primitives.

    /// True once real EV Nova data is loaded (vs the data-free demo world).
    @Callable func hasGame() -> Bool { game != nil }

    /// The player hull's `shïp` id, or -1 (demo ship has no sprite).
    @Callable func playerShipType() -> Int { world?.player.shipTypeID ?? -1 }

    /// A hull's display name, or "" if unknown / no data.
    @Callable func shipTypeName(shipType: Int) -> String {
        game?.ship(shipType)?.name ?? ""
    }

    /// Per live ship: `[shipType, spriteFrame]`, player first — SAME order and
    /// count as `shipTransforms()`, so the frontend zips the two. `shipType` is
    /// -1 for the synthetic demo ship (draw a primitive instead of a sprite).
    @Callable func shipSpriteFrames() -> PackedInt32Array {
        guard let world = self.world else { return PackedInt32Array() }
        var flat: [Int32] = [Int32(world.player.shipTypeID), Int32(world.player.spriteFrame)]
        for npc in world.npcs where npc.isAlive {
            flat.append(Int32(npc.shipTypeID)); flat.append(Int32(npc.spriteFrame))
        }
        return PackedInt32Array(flat)
    }

    // MARK: System geometry (stellar bodies)

    /// The system's hyperspace-jump radius (0 in the demo world).
    @Callable func jumpRadius() -> Double { world?.systemContext.jumpRadius ?? 0 }

    /// Per stellar body: `[x, y, radius, kind]`. `kind`: 0 landable planet,
    /// 1 non-landable planet, 2 hypergate, 3 wormhole, 4 deadly.
    @Callable func bodyTransforms() -> PackedFloat32Array {
        guard let world = self.world else { return PackedFloat32Array() }
        var flat: [Float] = []
        for b in world.systemContext.bodies {
            flat.append(Float(b.position.x))
            flat.append(Float(b.position.y))
            flat.append(Float(b.radius))
            var kind: Float = 1
            if b.isDeadly { kind = 4 }
            else if b.isWormhole { kind = 3 }
            else if b.isHypergate { kind = 2 }
            else if b.isLandable { kind = 0 }
            flat.append(kind)
        }
        return PackedFloat32Array(flat)
    }

    /// Per stellar body: its `spöb` id (for sprite lookup), SAME order as
    /// `bodyTransforms()`.
    @Callable func bodySpobIDs() -> PackedInt32Array {
        guard let world = self.world else { return PackedInt32Array() }
        return PackedInt32Array(world.systemContext.bodies.map { Int32($0.id) })
    }

    // MARK: Sprite export (raw RGBA the frontend uploads as a Godot Image)
    //
    // The decoders (RLED/PICT) produce a plain RGBA8 buffer with no Apple
    // dependency, so this path is fully cross-platform. GDScript turns the bytes
    // into an Image (FORMAT_RGBA8) once per hull/planet and caches the texture.

    /// `[frameWidth, frameHeight, frameCount, columns, rows, surfaceWidth,
    /// surfaceHeight]` for a hull's rotation sheet, or empty if it has no sprite.
    @Callable func shipSpriteInfo(shipType: Int) -> PackedInt32Array {
        spriteInfo(game?.shipSprite(shipType))
    }

    /// The RGBA8 surface bytes (`surfaceWidth*surfaceHeight*4`) for a hull's sheet.
    @Callable func shipSpriteRGBA(shipType: Int) -> PackedByteArray {
        spriteRGBA(game?.shipSprite(shipType))
    }

    /// Same as `shipSpriteInfo`, for a planet/station's `spöb` sprite.
    @Callable func spobSpriteInfo(spobID: Int) -> PackedInt32Array {
        spriteInfo(game?.spobSprite(spobID))
    }

    /// Same as `shipSpriteRGBA`, for a planet/station's `spöb` sprite.
    @Callable func spobSpriteRGBA(spobID: Int) -> PackedByteArray {
        spriteRGBA(game?.spobSprite(spobID))
    }

    // MARK: Sprite marshalling helpers

    private func spriteInfo(_ sheet: SpriteSheet?) -> PackedInt32Array {
        guard let s = sheet else { return PackedInt32Array() }
        return PackedInt32Array([
            s.frameWidth, s.frameHeight, s.frameCount,
            s.columns, s.rows, s.surfaceWidth, s.surfaceHeight,
        ].map { Int32($0) })
    }

    private func spriteRGBA(_ sheet: SpriteSheet?) -> PackedByteArray {
        guard let s = sheet else { return PackedByteArray() }
        // Convenience init from `[UInt8]` — one bulk copy, no per-byte Variant
        // crossing (the surface can be megabytes). Cached texture-side by GDScript.
        return PackedByteArray(s.rgba)
    }
}
