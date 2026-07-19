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
        let out = PackedFloat32Array()
        guard let world = self.world else { return out }

        func push(_ x: Double, _ y: Double, _ a: Double, _ kind: Float) {
            _ = out.append(value: Float(x))
            _ = out.append(value: Float(y))
            _ = out.append(value: Float(a))
            _ = out.append(value: kind)
        }

        let p = world.player
        push(p.position.x, p.position.y, p.angle, 0)
        for npc in world.npcs where npc.isAlive {
            push(npc.position.x, npc.position.y, npc.angle, npc.disabled ? 2 : 1)
        }
        return out
    }

    /// One string per `WorldEvent` produced this step (the case name, e.g.
    /// `weaponFired`, `shipDestroyed`), for sound/FX hooks. Uses the case-name
    /// prefix of the reflected value so new engine event kinds surface without a
    /// bridge change.
    @Callable func drainEvents() -> PackedStringArray {
        let out = PackedStringArray()
        guard let world = self.world else { return out }
        for event in world.events {
            let described = String(describing: event)
            let name = described.prefix { $0 != "(" }
            _ = out.append(value: String(name))
        }
        return out
    }
}
