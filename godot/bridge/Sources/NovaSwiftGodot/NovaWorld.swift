// NovaWorld — the Godot-visible façade over the NOVA Swift simulation.
//
// GDScript talks to exactly this class. It owns a `NovaSwiftEngine.World` and
// forwards a frame of Godot input into the engine's `ControlIntent`, ticks the
// sim with `step`, and hands entity state back out in packed arrays the scene
// can render cheaply. NO game logic lives here — anything past marshalling is a
// bug and belongs in the engine, where the Apple app inherits it too.
//
// Method names below are camelCase in Swift; every `@Callable` is declared
// `autoSnakeCase: true` so SwiftGodot exposes it to GDScript in snake_case
// (`makeDemoWorld` → `make_demo_world`), matching what godot/Main.gd calls.
// Confirmed on-toolchain: SwiftGodot's default (no `autoSnakeCase`) registers
// the literal camelCase Swift name instead — GDScript does not snake_case
// GDExtension methods for you, unlike its own built-in classes.
//
// Packed arrays construct from their Swift element arrays in one bulk copy —
// `PackedFloat32Array([Float])`, `PackedInt32Array([Int32])`,
// `PackedByteArray([UInt8])`, `PackedStringArray([String])` — confirmed
// on-toolchain too.
//
// See docs/GODOT_LAYER.md.

import Foundation
import SwiftGodot
import NovaSwiftEngine
import NovaSwiftKit
import NovaSwiftStory

/// Which decoded sheet a `sprite_info` / `sprite_rgba` call wants. One
/// enumerated accessor rather than a method pair per art type: every one of
/// these resolves through the same `spïn` → `rlëD` path in `NovaSwiftKit` and
/// marshals identically, so the only thing that actually varies is the lookup.
/// `id` means whatever that kind is keyed by — a `shïp` id for the hull layers,
/// a `spöb` id for stellars, a `spïn` id for shot art, a `bööm` id for
/// explosions, a `röid` id for rocks, and nothing at all for the starfield tile
/// (there is only ever one).
///
/// Raw ints because GDScript is the only caller and mirrors them as `SPRITE_*`
/// constants of its own: the values are API and must not be reordered.
private enum SpriteKind: Int {
    case ship = 0            // the hull itself
    case engineGlow = 1      // exhaust overlay, drawn while thrusting
    case shield = 2          // shield-flare overlay
    case lights = 3          // running lights overlay
    case weaponGlow = 4      // muzzle-flash overlay
    case spob = 5            // planet / station
    case spobDestroyed = 6   // its wrecked state
    case weapon = 7          // a shot's own art, by `spïn` id
    case boom = 8            // a `bööm` explosion animation
    case asteroid = 9        // a `röid` rock's rotation sheet
    case starfield = 10      // the background star tile
}

/// A decoded sheet and the rate to animate it at (0 = not a timed animation).
private typealias DecodedSheet = (sheet: SpriteSheet, animationRate: Int)

@Godot
class NovaWorld: Node2D {

    // MARK: Engine state

    private var world: World?
    private var galaxy: Galaxy?
    private var game: NovaGame?
    private var intent = ControlIntent()
    /// The system id `makeWorld` last built, so `launch()` can rebuild the same
    /// system after a docked visit — landing never changes system.
    private var currentSystemID: Int?
    /// The `spöb` id the player is currently docked at, or nil while flying.
    private var dockedSpobID: Int?
    /// The persistent pilot (credits, cargo, outfits, ship) — the same
    /// `PlayerState` schema the Apple app's `PilotStore` autosaves. Trade/
    /// outfit/shipyard transactions run through the portable `PilotEconomy`
    /// (Sources/NovaSwiftStory/PilotEconomy.swift) so this bridge doesn't
    /// reimplement pricing/mass-budget/trade-in rules. No disk save yet — see
    /// docs/GODOT_LAYER.md's pilot-save-load milestone item.
    private var pilot = PlayerState()
    private var pilotStarted = false

    // MARK: Fixed-step simulation
    //
    // The simulation runs on a fixed 30 Hz tick, exactly like the Apple app's
    // `GameScene.update` accumulator — NOT on the display's frame delta. This is
    // not a style choice: `World.step` integrates flight, weapon reloads, AI
    // re-planning and the spawn cadence per call, so feeding it a variable delta
    // makes the same ship handle differently at 60 Hz and 144 Hz. Godot's
    // `_process` delta goes into the accumulator; whole ticks come out.
    //
    // Between ticks the frontend still wants to draw at the display's rate, so
    // `renderAlpha` reports how far this frame sits into the next pending tick
    // and every pose readback below returns `lerp(prevTickPose, pose, alpha)`
    // off the engine's own `snapshotRenderState()` slots.

    private static let fixedStep = 1.0 / 30.0
    /// Cap on catch-up ticks per frame, so a long stall (window drag, a slow
    /// first sprite decode) doesn't spiral into an unbounded catch-up loop that
    /// stalls even longer. Matches `GameScene.simMaxCatchupTicks`.
    private static let maxCatchupTicks = 5

    private var simAccumulator = 0.0
    private var interpolationAlpha = 0.0

    /// `World.events` is cleared at the top of every `step`, so a frame that
    /// runs two ticks would lose the first tick's events if the frontend read
    /// the world directly. They're accumulated here instead and handed over on
    /// the next drain. Two buffers because the names feed the message log and
    /// the effect rows feed the particle layer — each drains independently, and
    /// one consuming the other would silently starve it.
    private var pendingEventNames: [String] = []
    private var pendingEffects: [Float] = []

    /// Stride of one `drainEffects()` row: `[kind, x, y, p0, p1, r, g, b]`.
    /// Kinds and what `p0`/`p1` mean per kind are documented on `drainEffects`.
    private static let effectRowFloats = 8

    /// Drop anything left over from a previous world — a stale half-tick or an
    /// undrained explosion from the system we just left would otherwise play
    /// over the new one.
    private func resetFrameState() {
        simAccumulator = 0
        interpolationAlpha = 0
        pendingEventNames.removeAll(keepingCapacity: true)
        pendingEffects.removeAll(keepingCapacity: true)
    }

    // MARK: World setup

    /// Build a bare physics world with a synthetic player ship and a few drifting
    /// NPCs. Runs with **no EV Nova data**, so the slice is playable immediately
    /// and proves the whole bridge end-to-end.
    @Callable(autoSnakeCase: true)
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
        resetFrameState()
    }

    /// Discover + merge the player's own EV Nova data (BYO-data, same as the
    /// Apple app). Returns false if the directory holds no readable game data.
    @Callable(autoSnakeCase: true)
    func loadGame(baseDir: String) -> Bool {
        let base = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: baseDir))
        // `merge` never throws on an empty file list (it just yields an empty
        // collection), so a missing/empty directory has to be rejected explicitly
        // here rather than relying on `try?` to catch it.
        guard !base.isEmpty, let collection = try? GameLibrary.merge(baseFiles: base) else { return false }
        let g = NovaGame(collection)
        self.game = g
        self.galaxy = Galaxy(game: g)
        return true
    }

    /// After `loadGame`, populate a real system with NPCs from its `düde`/`flët`
    /// spawn table via `GameSession.makeWorld`. Pass a negative id to use the
    /// data's starting system. Returns false if no game is loaded.
    @Callable(autoSnakeCase: true)
    func makeWorld(systemID: Int) -> Bool {
        guard let game = self.game else { return false }
        let galaxy = self.galaxy ?? Galaxy(game: game)
        self.galaxy = galaxy

        // Bootstrap the pilot from the scenario's `chär` exactly once — the
        // same authoritative bootstrap `PilotStore.newGame` uses on the Apple
        // side (random start system among candidates, starting hull/credits/
        // calendar/standings/OnStart script). A later `makeWorld` call (e.g.
        // traveling to a new system) reuses the live pilot instead of rerolling.
        if !pilotStarted {
            pilot = PilotFactory.makeDefault(name: "Captain", isMale: true, game: game)
            pilotStarted = true
        }

        let sysID = systemID >= 0 ? systemID : pilot.currentSystem
        let player = galaxy.makeLoadedShip(pilot.shipType, extraOutfits: pilot.outfits, at: Vec2())
            ?? Ship(name: "Player", stats: ShipStats(speed: 300, acceleration: 300, turnRate: 100))
        player.cargo = pilot.cargo

        let (w, _) = GameSession.makeWorld(game: game, systemID: sysID, player: player, galaxy: galaxy)
        self.world = w
        self.intent = ControlIntent()
        self.currentSystemID = sysID
        self.dockedSpobID = nil
        pilot.currentSystem = sysID
        resetFrameState()
        return true
    }

    // MARK: Input

    /// Map one frame of Godot input onto the engine's `ControlIntent`. Applied to
    /// the world at the next `step`.
    @Callable(autoSnakeCase: true)
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

    /// Feed one display frame's `dt` into the fixed-step accumulator and run
    /// however many whole 30 Hz ticks it buys — the same `World.step` the Apple
    /// app and the headless `novaswift-extract ai` harness drive, at the same
    /// cadence the Apple app drives it. A frame may run zero ticks (a 144 Hz
    /// display), one, or several after a stall; the frontend calls this once per
    /// `_process` either way and draws off `renderAlpha`.
    @Callable(autoSnakeCase: true)
    func step(dt: Double) {
        guard let world = self.world else { return }
        world.intent = self.intent

        let fixed = Self.fixedStep
        // Clamp before the loop, not inside it: a 4-second stall should drop the
        // backlog, not simulate 4 seconds of combat in one frame.
        simAccumulator = min(simAccumulator + max(0, dt), fixed * Double(Self.maxCatchupTicks))
        while simAccumulator >= fixed {
            world.snapshotRenderState()   // pre-tick pose for render interpolation
            world.step(fixed)
            simAccumulator -= fixed
            collectEvents(from: world)    // World.events is cleared by the next step
        }
        interpolationAlpha = fixed > 0 ? simAccumulator / fixed : 0
    }

    /// How far the current display frame sits into the next pending sim tick,
    /// 0..<1. Every pose this class hands back is already interpolated by it —
    /// this is exposed so the frontend can match the same easing for anything it
    /// animates itself (a beam welded to a moving muzzle, say).
    @Callable(autoSnakeCase: true) func renderAlpha() -> Double { interpolationAlpha }

    // MARK: Render interpolation

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    /// A ship's drawn position: its pose at the end of the previous tick eased
    /// toward its current pose. The engine seeds both slots at spawn, so a
    /// brand-new ship never lerps in from the origin.
    private func renderPosition(of s: Ship) -> Vec2 {
        Vec2(lerp(s.renderPrevPosition.x, s.position.x, interpolationAlpha),
             lerp(s.renderPrevPosition.y, s.position.y, interpolationAlpha))
    }

    /// Same for heading — via `angleDelta` so a ship crossing north interpolates
    /// the short way round instead of spinning the long way through 2π.
    private func renderAngle(of s: Ship) -> Double {
        s.renderPrevAngle + angleDelta(from: s.renderPrevAngle, to: s.angle) * interpolationAlpha
    }

    private func renderPosition(of p: Projectile) -> Vec2 {
        Vec2(lerp(p.renderPrevPosition.x, p.position.x, interpolationAlpha),
             lerp(p.renderPrevPosition.y, p.position.y, interpolationAlpha))
    }

    // MARK: Event collection

    /// Fold one tick's `WorldEvent`s into the two pending buffers. Names keep the
    /// reflected case-name form the message log already keys off, so a new engine
    /// event kind surfaces there without a bridge change; the effect rows are an
    /// explicit allow-list, because each one needs its position and payload
    /// packed in a shape the renderer knows what to do with.
    private func collectEvents(from world: World) {
        for event in world.events {
            pendingEventNames.append(String(String(describing: event).prefix { $0 != "(" }))

            func push(_ kind: Float, _ at: Vec2, _ p0: Float, _ p1: Float = 0,
                      _ r: Float = 1, _ g: Float = 1, _ b: Float = 1) {
                self.pendingEffects.append(contentsOf: [kind, Float(at.x), Float(at.y), p0, p1, r, g, b])
            }

            switch event {
            case let .explosion(at, radius, _, boomID):
                push(0, at, Float(radius), Float(boomID ?? -1))
            case let .shieldHit(at, weaponID):
                push(1, at, Float(weaponID), 0, 0.45, 0.70, 1.0)
            case let .armorHit(at, weaponID):
                push(2, at, Float(weaponID), 0, 1.0, 0.65, 0.30)
            case let .asteroidDebris(at, color, count):
                push(3, at, Float(count), 0,
                     Float(color.r) / 255, Float(color.g) / 255, Float(color.b) / 255)
            case let .shipDying(_, at, boomID):
                push(4, at, Float(boomID ?? -1))
            case let .shipDestroyed(_, shipTypeID, at):
                push(5, at, Float(shipTypeID))
            case let .weaponFired(_, at, heading, _, weaponID):
                push(6, at, Float(heading), Float(weaponID))
            default:
                break   // everything else is narrative, not visual — names only
            }
        }
    }

    // MARK: Player readback

    /// Interpolated, like every pose below — the camera follows this, so reading
    /// the raw sim position here would judder the whole scene at 30 Hz even
    /// though the ships in it are smooth.
    @Callable(autoSnakeCase: true) func playerPosition() -> Vector2 {
        guard let p = world?.player else { return Vector2(x: 0, y: 0) }
        let r = renderPosition(of: p)
        return Vector2(x: Float(r.x), y: Float(r.y))
    }

    @Callable(autoSnakeCase: true) func playerVelocity() -> Vector2 {
        guard let p = world?.player else { return Vector2(x: 0, y: 0) }
        return Vector2(x: Float(p.velocity.x), y: Float(p.velocity.y))
    }

    /// Engine heading in radians (0 = up / north, increasing clockwise).
    @Callable(autoSnakeCase: true) func playerAngle() -> Double {
        guard let p = world?.player else { return 0 }
        return renderAngle(of: p)
    }

    @Callable(autoSnakeCase: true) func playerShieldFraction() -> Double {
        guard let p = world?.player, p.maxShield > 0 else { return 0 }
        return max(0, min(1, p.shield / p.maxShield))
    }

    @Callable(autoSnakeCase: true) func playerArmorFraction() -> Double {
        guard let p = world?.player, p.maxArmor > 0 else { return 0 }
        return max(0, min(1, p.armor / p.maxArmor))
    }

    @Callable(autoSnakeCase: true) func playerIsAlive() -> Bool {
        world?.player.isAlive ?? false
    }

    // MARK: All-ship readback

    /// Number of live ships this frame (player + living NPCs).
    @Callable(autoSnakeCase: true) func shipCount() -> Int {
        guard let world = self.world else { return 0 }
        return 1 + world.npcs.filter { $0.isAlive }.count
    }

    /// Every live ship packed as `[x, y, angle, kind]` per ship, player first.
    /// `kind`: 0 = player, 1 = NPC, 2 = disabled NPC hulk. One flat array keeps
    /// the per-frame crossing cheap — GDScript strides it by 4.
    @Callable(autoSnakeCase: true) func shipTransforms() -> PackedFloat32Array {
        guard let world = self.world else { return PackedFloat32Array() }
        var flat: [Float] = []

        func push(_ x: Double, _ y: Double, _ a: Double, _ kind: Float) {
            flat.append(Float(x)); flat.append(Float(y)); flat.append(Float(a)); flat.append(kind)
        }

        let p = world.player
        let pr = renderPosition(of: p)
        push(pr.x, pr.y, renderAngle(of: p), 0)
        for npc in world.npcs where npc.isAlive {
            let r = renderPosition(of: npc)
            push(r.x, r.y, renderAngle(of: npc), npc.disabled ? 2 : 1)
        }
        return PackedFloat32Array(flat)
    }

    /// Entity id per live ship, SAME order as `shipTransforms()` (player first,
    /// `Ship.entityID`). Lets the frontend map a radar blip or click back to a
    /// concrete ship for `selectTarget`.
    // autoSnakeCase mis-splits the "IDs" acronym as "i_ds" (see bodySpobIDs below).
    @Callable(explicitName: "ship_ids") func shipIDs() -> PackedInt32Array {
        guard let world = self.world else { return PackedInt32Array() }
        var flat: [Int32] = [Int32(world.player.entityID)]
        for npc in world.npcs where npc.isAlive { flat.append(Int32(npc.entityID)) }
        return PackedInt32Array(flat)
    }

    /// Per live ship, SAME order as `shipTransforms()`: a radar/IFF category —
    /// 0 hostile (red), 1 neutral (blue), 2 friendly/escort (green), 3 disabled
    /// hulk (grey), 4 self (the player entry — the frontend already colors this
    /// distinctly and shouldn't need to special-case index 0). Delegates to the
    /// engine's own `Diplomacy`/brain hostility rules rather than re-deriving
    /// them client-side.
    @Callable(autoSnakeCase: true) func shipRelationships() -> PackedInt32Array {
        guard let world = self.world else { return PackedInt32Array() }
        var flat: [Int32] = [4]
        for npc in world.npcs where npc.isAlive {
            flat.append(relationship(of: npc, in: world))
        }
        return PackedInt32Array(flat)
    }

    private func relationship(of npc: Ship, in world: World) -> Int32 {
        if npc.disabled { return 3 }
        if world.isPlayerEscort(npc) { return 2 }
        if world.isEffectivelyHostileToPlayer(npc) { return 0 }
        return 1
    }

    // MARK: Targeting

    /// Lock the nearest eligible ship in `World.targetLockRange` (excludes the
    /// player's own fleet). `hostileOnly` narrows to ships that would actually
    /// fight the player — the "nearest enemy" hotkey. Returns the locked ship's
    /// entity id, or -1 if nothing was in range.
    @Callable(autoSnakeCase: true) func selectNearestTarget(hostileOnly: Bool) -> Int {
        world?.selectNearestTarget(hostileOnly: hostileOnly)?.entityID ?? -1
    }

    /// Lock a specific ship by id (click-to-select). Unlike
    /// `selectNearestTarget`, allows disabled hulks and has no range gate.
    @Callable(autoSnakeCase: true) func selectTarget(id: Int) -> Bool {
        world?.selectTarget(id: id) != nil
    }

    /// Drop the player's current target lock, if any.
    @Callable(autoSnakeCase: true) func clearPlayerTarget() {
        world?.clearPlayerTarget()
    }

    /// The player's locked target's entity id, or -1 if none/no longer alive.
    @Callable(autoSnakeCase: true) func playerTargetID() -> Int {
        guard let world = self.world, let tid = world.player.currentTargetID,
              let t = world.ship(id: tid), t.isAlive else { return -1 }
        return tid
    }

    private var lockedTarget: Ship? {
        guard let world = self.world, let tid = world.player.currentTargetID,
              let t = world.ship(id: tid), t.isAlive else { return nil }
        return t
    }

    @Callable(autoSnakeCase: true) func targetName() -> String { lockedTarget?.name ?? "" }

    @Callable(autoSnakeCase: true) func targetShieldFraction() -> Double {
        guard let t = lockedTarget, t.maxShield > 0 else { return 0 }
        return max(0, min(1, t.shield / t.maxShield))
    }

    @Callable(autoSnakeCase: true) func targetArmorFraction() -> Double {
        guard let t = lockedTarget, t.maxArmor > 0 else { return 0 }
        return max(0, min(1, t.armor / t.maxArmor))
    }

    @Callable(autoSnakeCase: true) func targetIsHostile() -> Bool {
        guard let world = self.world, let t = lockedTarget else { return false }
        return world.isEffectivelyHostileToPlayer(t)
    }

    /// Distance from the player to the locked target, in px — 0 if no target.
    @Callable(autoSnakeCase: true) func targetDistance() -> Double {
        guard let world = self.world, let t = lockedTarget else { return 0 }
        return (t.position - world.player.position).length
    }

    // MARK: Weapons

    /// The EV Nova flight HUD's weapon readout tracks the selected *secondary*
    /// (guns/primaries are "always available" and never occupy it) — a
    /// guns-only ship correctly reports `hasSecondaryWeapon() == false`.
    @Callable(autoSnakeCase: true) func hasSecondaryWeapon() -> Bool {
        !(world?.player.secondaryWeaponIDs.isEmpty ?? true)
    }

    @Callable(autoSnakeCase: true) func secondaryWeaponName() -> String {
        world?.player.effectiveSecondaryMount?.spec.name ?? ""
    }

    /// Remaining ammo for the effective secondary; -1 = unlimited, 0 if none fitted.
    @Callable(autoSnakeCase: true) func secondaryWeaponAmmo() -> Int {
        world?.player.effectiveSecondaryMount?.ammo ?? 0
    }

    /// 0 = ready to fire, 1 = just fired (full reload wait).
    @Callable(autoSnakeCase: true) func secondaryWeaponCooldownFraction() -> Double {
        guard let mount = world?.player.effectiveSecondaryMount, mount.spec.reloadSeconds > 0 else { return 0 }
        return max(0, min(1, mount.cooldown / mount.spec.reloadSeconds))
    }

    /// Step the selected secondary to the next/previous fitted secondary.
    /// Returns the new weapon's display name, or "" with no secondaries fitted.
    @Callable(autoSnakeCase: true) func cycleSecondaryWeapon(forward: Bool) -> String {
        guard let player = world?.player, !player.secondaryWeaponIDs.isEmpty else { return "" }
        player.cycleSecondary(forward: forward)
        return player.effectiveSecondaryMount?.spec.name ?? ""
    }

    // MARK: Sensors

    /// `baseRange` (frontend's own radar-circle radius, e.g. 4500) shrunk by the
    /// system's interference/jamming outfits for the player — mirrors the
    /// Apple app's `World.effectiveSensorRange(_:for:)` call.
    @Callable(autoSnakeCase: true) func effectiveSensorRange(baseRange: Double) -> Double {
        guard let world = self.world else { return baseRange }
        return world.effectiveSensorRange(baseRange, for: world.player)
    }

    // MARK: Fuel

    @Callable(autoSnakeCase: true) func playerFuelFraction() -> Double {
        guard let p = world?.player, p.maxFuel > 0 else { return 0 }
        return max(0, min(1, p.fuel / p.maxFuel))
    }

    /// Whole hyperjumps left on the current fuel (`ShipFuel.perJump` each).
    @Callable(autoSnakeCase: true) func playerJumpsRemaining() -> Int {
        guard let p = world?.player else { return 0 }
        return Int((p.fuel / ShipFuel.perJump).rounded(.down))
    }

    // MARK: Landing

    /// The nearest body the player could conceivably land on right now, in
    /// reach regardless of speed — mirrors `GameScene.updateLanding`'s
    /// distance/reach test (`body.radius + 70`, not `+55`: matches where
    /// takeoff/dock-load placement actually sets the ship down). Only
    /// `isLandable` bodies count, not hypergates/wormholes — gate travel is a
    /// separate flow (see docs/GODOT_LAYER.md's hypergate section).
    private func nearestReachableLandTarget() -> (id: Int, name: String)? {
        guard let world = self.world else { return nil }
        var bestID: Int?
        var bestDist = Double.greatestFiniteMagnitude
        var bestReach = 0.0
        for body in world.systemContext.bodies where body.isLandable {
            let d = (body.position - world.player.position).length
            if d < bestDist { bestDist = d; bestID = body.id; bestReach = body.radius + 70 }
        }
        guard let id = bestID, bestDist <= bestReach else { return nil }
        return (id, game?.spob(id)?.name ?? "")
    }

    /// True once the player is close enough AND slow enough to land — mirrors
    /// `GameScene.canLandNow`'s 130 u/s speed limit (`landingSpeedLimit`).
    @Callable(autoSnakeCase: true) func canLandNow() -> Bool {
        guard let world = self.world, nearestReachableLandTarget() != nil else { return false }
        return world.player.velocity.length <= 130
    }

    /// The `spöb` id of the nearest body in reach, or -1 if nothing's close
    /// enough — set even when too fast to land yet, so the frontend can show
    /// "slow down to land on X" like the Apple app does.
    @Callable(autoSnakeCase: true) func nearestLandableSpobID() -> Int {
        nearestReachableLandTarget()?.id ?? -1
    }

    /// Display name of the nearest body in reach, or "" if none.
    @Callable(autoSnakeCase: true) func nearestLandableName() -> String {
        nearestReachableLandTarget()?.name ?? ""
    }

    /// True while docked at a spöb (spaceport screens should be showing).
    @Callable(autoSnakeCase: true) func isLanded() -> Bool { dockedSpobID != nil }

    /// The `spöb` id the player is docked at, or -1 while flying.
    @Callable(autoSnakeCase: true) func landedSpobID() -> Int { dockedSpobID ?? -1 }

    /// Attempt to land on the nearest body in reach. Fails (returns false) if
    /// out of reach or moving too fast, exactly like pressing the Land key does
    /// in the Apple app. On success the frontend should stop calling `step()`
    /// and show spaceport screens until `launch()`.
    @Callable(autoSnakeCase: true) func attemptLand() -> Bool {
        guard canLandNow(), let target = nearestReachableLandTarget() else { return false }
        // Hand the flight ship's hold back to the pilot before the spaceport
        // screens read it. Anything picked up in flight — mined ore, plundered
        // cargo — lives on the `Ship` until touchdown, and `launch()` re-seeds
        // the ship from `pilot.cargo`, so without this handoff a run's takings
        // would be silently thrown away the moment it docked.
        if let ship = world?.player { pilot.cargo = ship.cargo }
        dockedSpobID = target.id
        pilot.landedSpob = target.id
        return true
    }

    /// Take off from the current dock: rebuilds the system (fresh NPC spawn,
    /// same as any `makeWorld`) and places the player just clear of the body's
    /// surface, nose pointed away from the system centre, at rest — EV Nova
    /// gives no outbound momentum on takeoff (mirrors
    /// `GameScene.reloadForDeparture`). No-op (returns false) if not landed.
    @Callable(autoSnakeCase: true) func launch() -> Bool {
        guard let spobID = dockedSpobID, let game = self.game, let galaxy = self.galaxy,
              let sysID = currentSystemID else { return false }
        // Rebuild from the pilot's current loadout, not the old flight `Ship` —
        // trade/outfit/shipyard transactions while docked only mutate `pilot`
        // (see the trade section below), matching the Apple app's
        // `buildPlayerShip` (a fresh loaded ship each landing/launch, cargo
        // carried in from `pilot.cargo`).
        let player = galaxy.makeLoadedShip(pilot.shipType, extraOutfits: pilot.outfits, at: Vec2())
            ?? world?.player ?? Ship(name: "Player", stats: ShipStats(speed: 300, acceleration: 300, turnRate: 100))
        player.cargo = pilot.cargo
        let (w, _) = GameSession.makeWorld(game: game, systemID: sysID, player: player, galaxy: galaxy)
        let ctx = w.systemContext
        if let body = ctx.bodies.first(where: { $0.id == spobID }) {
            var outward = body.position - ctx.center
            if outward.length < 1 { outward = Vec2(0, -1) }
            let dir = outward.normalized
            player.position = body.position + dir * (body.radius + 60)
            player.angle = dir.angle
            player.velocity = Vec2()
        }
        player.currentTargetID = nil
        self.world = w
        dockedSpobID = nil
        pilot.landedSpob = nil
        resetFrameState()
        return true
    }

    // MARK: Trade (Commodity Exchange)
    //
    // All pricing/mass/affordability math is `PilotEconomy`'s (see that type's
    // doc comment) — this section only resolves the docked `spöb` and marshals
    // its commodity rows. Only the standard 6 `Commodity` goods are exposed
    // here, matching the Apple app's `TradeCenterView`; `jünk` (contraband)
    // trading is a separate, not-yet-bridged screen.

    private var dockedSpob: SpobRes? {
        guard let id = dockedSpobID else { return nil }
        return game?.spob(id)
    }

    /// The docked spöb's tradable commodities, in `Commodity` raw-value order
    /// (food/industrial/medical/luxury/metal/equipment) — empty if not docked
    /// or the port has no commodity exchange.
    private func market() -> [(commodity: Commodity, level: PriceLevel, price: Int)] {
        guard let game = self.game, let spob = dockedSpob else { return [] }
        return game.commodityMarket(at: spob)
    }

    @Callable(autoSnakeCase: true) func playerCredits() -> Int { pilot.credits }
    @Callable(autoSnakeCase: true) func cargoFreeTons() -> Int {
        guard let galaxy = self.galaxy else { return 0 }
        return PilotEconomy.cargoFree(pilot, galaxy: galaxy)
    }
    @Callable(autoSnakeCase: true) func cargoCapacityTons() -> Int {
        guard let galaxy = self.galaxy else { return 0 }
        return PilotEconomy.cargoCapacity(pilot, galaxy: galaxy)
    }

    /// Number of tradable commodity rows at the docked spöb (0 if not docked
    /// or no exchange). The frontend indexes the other `commodity*`/`buy`/`sell`
    /// calls by row 0..<this.
    @Callable(autoSnakeCase: true) func commodityCount() -> Int { market().count }

    @Callable(autoSnakeCase: true) func commodityName(index: Int) -> String {
        let m = market()
        guard index >= 0, index < m.count else { return "" }
        return game?.commodityName(m[index].commodity) ?? m[index].commodity.fallbackName
    }

    @Callable(autoSnakeCase: true) func commodityPrice(index: Int) -> Int {
        let m = market()
        guard index >= 0, index < m.count else { return 0 }
        return m[index].price
    }

    /// Tons of this commodity currently in the pilot's hold (persists across
    /// landings — the same figure the flight HUD's cargo readout carries once
    /// `launch()` seeds the ship from it).
    @Callable(autoSnakeCase: true) func commodityHeld(index: Int) -> Int {
        let m = market()
        guard index >= 0, index < m.count else { return 0 }
        return PilotEconomy.held(pilot, cargo: m[index].commodity.cargoID)
    }

    /// Buy up to `tons` of commodity row `index` at its current price, capped by
    /// affordability and free cargo space. Returns the tonnage actually bought.
    @discardableResult
    @Callable(autoSnakeCase: true) func buyCommodity(index: Int, tons: Int) -> Int {
        guard let galaxy = self.galaxy else { return 0 }
        let m = market()
        guard index >= 0, index < m.count else { return 0 }
        let free = PilotEconomy.cargoFree(pilot, galaxy: galaxy)
        return PilotEconomy.buyCommodity(&pilot, m[index].commodity, tons: tons, unitPrice: m[index].price, cargoFree: free)
    }

    /// Sell up to `tons` of commodity row `index` at its current price. Returns
    /// the tonnage actually sold.
    @discardableResult
    @Callable(autoSnakeCase: true) func sellCommodity(index: Int, tons: Int) -> Int {
        let m = market()
        guard index >= 0, index < m.count else { return 0 }
        return PilotEconomy.sellCommodity(&pilot, m[index].commodity, tons: tons, unitPrice: m[index].price)
    }

    // MARK: Event drains
    //
    // Both of these genuinely *drain*: they hand over what has accumulated since
    // the last call and empty the buffer. Reading `World.events` directly (as
    // this did before) re-reported the same events on every frame the world
    // wasn't stepped — which is every frame while docked, so a single "Docked"
    // event redrew the message log forever.

    /// One string per `WorldEvent` produced since the last drain (the case name,
    /// e.g. `weaponFired`, `shipDestroyed`), for the message log and sound hooks.
    /// Uses the case-name prefix of the reflected value so new engine event kinds
    /// surface without a bridge change.
    @Callable(autoSnakeCase: true) func drainEvents() -> PackedStringArray {
        let names = pendingEventNames
        pendingEventNames.removeAll(keepingCapacity: true)
        return PackedStringArray(names)
    }

    /// The subset of events that want to be *drawn*, packed 8 floats per row:
    /// `[kind, x, y, p0, p1, r, g, b]`. `x`/`y` are world space; `r`/`g`/`b` are
    /// 0…1. By kind:
    ///
    /// - `0` explosion — `p0` blast radius, `p1` the `bööm` id to animate (-1 = none)
    /// - `1` shield hit — `p0` the `wëap` id that landed it
    /// - `2` armor hit — `p0` the `wëap` id that landed it
    /// - `3` asteroid debris — `p0` fragment count, `rgb` the rock's `partColor`
    /// - `4` ship dying — `p0` the hull's death `bööm` id (-1 = none)
    /// - `5` ship destroyed — `p0` the `shïp` id that died
    /// - `6` weapon fired — `p0` muzzle heading (radians), `p1` the `wëap` id
    ///
    /// Everything else in `WorldEvent` is narrative rather than visual and comes
    /// through `drainEvents()` by name only.
    @Callable(autoSnakeCase: true) func drainEffects() -> PackedFloat32Array {
        let rows = pendingEffects
        pendingEffects.removeAll(keepingCapacity: true)
        return PackedFloat32Array(rows)
    }

    /// Floats per `drainEffects()` row, so the frontend strides by a constant it
    /// was told rather than one it hardcoded.
    @Callable(autoSnakeCase: true) func effectStride() -> Int { Self.effectRowFloats }

    // MARK: Projectiles

    /// Every live shot as `[x, y, facing]`, render-interpolated. Shots are the
    /// fastest things on screen — at 30 Hz a torpedo moves visibly far per tick,
    /// so this is where interpolation earns the most.
    @Callable(autoSnakeCase: true) func projectileTransforms() -> PackedFloat32Array {
        guard let world = self.world else { return PackedFloat32Array() }
        var flat: [Float] = []
        flat.reserveCapacity(world.projectiles.count * 3)
        for shot in world.projectiles {
            let r = renderPosition(of: shot)
            flat.append(Float(r.x)); flat.append(Float(r.y)); flat.append(Float(shot.facing))
        }
        return PackedFloat32Array(flat)
    }

    /// Per live shot, SAME order as `projectileTransforms()`:
    /// `[graphicSpinID, spins, translucent]`. `graphicSpinID` is the `spïn` id of
    /// the weapon's own shot art (-1 → the frontend draws a generic bolt);
    /// `spins` is `wëap` "shots spin" (animate the sheet rather than treating it
    /// as a rotation sheet); `translucent` is `Flags3` 0x0002.
    @Callable(autoSnakeCase: true) func projectileStyles() -> PackedInt32Array {
        guard let world = self.world else { return PackedInt32Array() }
        var flat: [Int32] = []
        flat.reserveCapacity(world.projectiles.count * 3)
        for shot in world.projectiles {
            flat.append(Int32(shot.graphicSpinID ?? -1))
            flat.append(shot.spinShots ? 1 : 0)
            flat.append(shot.translucentShots ? 1 : 0)
        }
        return PackedInt32Array(flat)
    }

    // MARK: Beams

    /// Every live beam segment as
    /// `[x0, y0, x1, y1, width, alpha, r, g, b, coronaR, coronaG, coronaB, coronaFalloff]`
    /// — 13 floats per beam.
    ///
    /// Real EV Nova beams ship no sprite art at all: a bright `beamColor` core
    /// fading out to `coronaColor` *is* the authored look, which is why both
    /// colors and the falloff cross the bridge rather than a single tint. A
    /// `width` of 0 is a deliberate authoring choice meaning "corona only, no
    /// core" — pass it through as 0 and let the frontend give it glow room.
    ///
    /// Endpoints are rigidly translated by however far render interpolation has
    /// moved the shooter off its sim-tick position, so a continuous beam stays
    /// welded to the barrel between ticks instead of trailing it.
    @Callable(autoSnakeCase: true) func beamSegments() -> PackedFloat32Array {
        guard let world = self.world else { return PackedFloat32Array() }
        var flat: [Float] = []
        flat.reserveCapacity(world.activeBeams.count * 13)
        for b in world.activeBeams {
            var dx = 0.0, dy = 0.0
            if let shooter = world.ship(id: b.shooterID) {
                let interp = renderPosition(of: shooter)
                dx = interp.x - shooter.position.x
                dy = interp.y - shooter.position.y
            }
            // A continuous beam holds full brightness while its trigger is down;
            // a pulse fades over its own authored life rather than blinking off.
            let alpha: Double = (b.continuous || !b.life.isFinite)
                ? 0.95
                : max(0.1, min(1.0, b.life / max(b.maxLife, 0.001)))
            let core: (r: Double, g: Double, b: Double)
            if let authored = b.color {
                core = authored
            } else if b.hit {
                core = (r: 1.0, g: 0.6, b: 0.3)
            } else {
                core = (r: 0.85, g: 0.85, b: 0.85)
            }
            let corona: (r: Double, g: Double, b: Double) = b.coronaColor ?? core
            flat.append(contentsOf: [
                Float(b.from.x + dx), Float(b.from.y + dy),
                Float(b.to.x + dx), Float(b.to.y + dy),
                Float(b.width), Float(alpha),
                Float(core.r), Float(core.g), Float(core.b),
                Float(corona.r), Float(corona.g), Float(corona.b),
                Float(b.coronaFalloff),
            ])
        }
        return PackedFloat32Array(flat)
    }

    // MARK: Asteroids

    /// Every live rock as `[x, y, radius, angle]`. Asteroids don't move under
    /// their own power between ticks in any way the eye catches, so these are the
    /// raw sim values — no interpolation slot exists for them in the engine.
    @Callable(autoSnakeCase: true) func asteroidTransforms() -> PackedFloat32Array {
        guard let world = self.world else { return PackedFloat32Array() }
        var flat: [Float] = []
        for rock in world.asteroids where rock.isAlive {
            flat.append(contentsOf: [Float(rock.position.x), Float(rock.position.y),
                                     Float(rock.radius), Float(rock.angle)])
        }
        return PackedFloat32Array(flat)
    }

    /// Per live rock, SAME order as `asteroidTransforms()`:
    /// `[roidTypeID, spriteFrame]`, so the frontend picks the pre-rotated frame
    /// from that `röid` type's sheet exactly as it does for hulls.
    @Callable(autoSnakeCase: true) func asteroidStyles() -> PackedInt32Array {
        guard let world = self.world else { return PackedInt32Array() }
        var flat: [Int32] = []
        for rock in world.asteroids where rock.isAlive {
            flat.append(Int32(rock.roidTypeID)); flat.append(Int32(rock.spriteFrame))
        }
        return PackedInt32Array(flat)
    }

    // MARK: Per-ship visual state

    /// Per live ship, SAME order and count as `shipTransforms()`:
    /// `[cloak, ionize, thrusting]`.
    ///
    /// - `cloak` 0…1 — `Ship.effectiveCloakLevel`; fade the hull out by it, so a
    ///   ship engaging its cloak dissolves rather than popping. `shipTransforms`
    ///   still reports a fully cloaked ship, so it is this fade that hides it;
    ///   proper `World.canDetect` culling (which also accounts for the player's
    ///   own cloak scanners) is still open.
    /// - `ionize` 0…1 — how close the ship is to being ionized out, for the
    ///   crackle tint the Apple app draws.
    /// - `thrusting` 0 or 1 — draw the engine-glow sprite. The player's comes
    ///   from live intent; an NPC's is its afterburner, since the engine keeps no
    ///   per-NPC "main drive lit" flag to read.
    @Callable(autoSnakeCase: true) func shipVisuals() -> PackedFloat32Array {
        guard let world = self.world else { return PackedFloat32Array() }
        var flat: [Float] = []

        func push(_ ship: Ship, thrusting: Bool) {
            let ionize = ship.ionizeMax > 0 ? min(1, max(0, ship.ionCharge / ship.ionizeMax)) : 0
            flat.append(contentsOf: [Float(ship.effectiveCloakLevel), Float(ionize),
                                     thrusting ? 1 : 0])
        }

        push(world.player, thrusting: intent.thrust || world.player.afterburnerActive)
        for npc in world.npcs where npc.isAlive {
            push(npc, thrusting: npc.afterburnerActive)
        }
        return PackedFloat32Array(flat)
    }

    /// The system's authored `sÿst.BkgndColor` as `[r, g, b]`, 0…1, which the
    /// frontend clears to instead of a hardcoded near-black. Nova's nebula systems are visibly not
    /// black, and clearing wrong loses that entirely.
    @Callable(autoSnakeCase: true) func systemBackgroundColor() -> PackedFloat32Array {
        let c = world?.systemBackgroundColor ?? NovaColor(r: 0, g: 0, b: 0)
        return PackedFloat32Array([Float(c.r) / 255, Float(c.g) / 255, Float(c.b) / 255])
    }

    // MARK: Real-data render queries
    //
    // All nil-safe: they return empty/sentinel values in the data-free demo world,
    // so the frontend can call them unconditionally and fall back to primitives.

    /// True once real EV Nova data is loaded (vs the data-free demo world).
    @Callable(autoSnakeCase: true) func hasGame() -> Bool { game != nil }

    /// The player hull's `shïp` id, or -1 (demo ship has no sprite).
    @Callable(autoSnakeCase: true) func playerShipType() -> Int { world?.player.shipTypeID ?? -1 }

    /// A hull's display name, or "" if unknown / no data.
    @Callable(autoSnakeCase: true) func shipTypeName(shipType: Int) -> String {
        game?.ship(shipType)?.name ?? ""
    }

    /// Per live ship: `[shipType, spriteFrame]`, player first — SAME order and
    /// count as `shipTransforms()`, so the frontend zips the two. `shipType` is
    /// -1 for the synthetic demo ship (draw a primitive instead of a sprite).
    @Callable(autoSnakeCase: true) func shipSpriteFrames() -> PackedInt32Array {
        guard let world = self.world else { return PackedInt32Array() }
        var flat: [Int32] = [Int32(world.player.shipTypeID), Int32(world.player.spriteFrame)]
        for npc in world.npcs where npc.isAlive {
            flat.append(Int32(npc.shipTypeID)); flat.append(Int32(npc.spriteFrame))
        }
        return PackedInt32Array(flat)
    }

    // MARK: System geometry (stellar bodies)

    /// The system's hyperspace-jump radius (0 in the demo world).
    @Callable(autoSnakeCase: true) func jumpRadius() -> Double { world?.systemContext.jumpRadius ?? 0 }

    /// Per stellar body: `[x, y, radius, kind]`. `kind`: 0 landable planet,
    /// 1 non-landable planet, 2 hypergate, 3 wormhole, 4 deadly.
    @Callable(autoSnakeCase: true) func bodyTransforms() -> PackedFloat32Array {
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
    // autoSnakeCase mis-splits the "IDs" acronym as "i_ds"; pin the name explicitly.
    @Callable(explicitName: "body_spob_ids") func bodySpobIDs() -> PackedInt32Array {
        guard let world = self.world else { return PackedInt32Array() }
        return PackedInt32Array(world.systemContext.bodies.map { Int32($0.id) })
    }

    // MARK: Sprite export (raw RGBA the frontend uploads as a Godot Image)
    //
    // The decoders (RLED/PICT) produce a plain RGBA8 buffer with no Apple
    // dependency, so this path is fully cross-platform. GDScript turns the bytes
    // into an Image (FORMAT_RGBA8) once per hull/planet and caches the texture.

    /// Resolve one sheet plus, for a `bööm`, the authored frame rate to play it
    /// at. Returns nil for an unknown kind or a resource with no graphic.
    private func decodedSheet(kind: Int, id: Int) -> DecodedSheet? {
        guard let game = self.game, let which = SpriteKind(rawValue: kind) else { return nil }

        /// Everything except a `bööm` is a rotation sheet indexed by heading, so
        /// it has no timed playback rate of its own.
        func untimed(_ sheet: SpriteSheet?) -> DecodedSheet? {
            guard let sheet = sheet else { return nil }
            return (sheet, 0)
        }

        switch which {
        case .ship:          return untimed(game.shipSprite(id))
        case .engineGlow:    return untimed(game.engineGlowSprite(id))
        case .shield:        return untimed(game.shieldSprite(id))
        case .lights:        return untimed(game.lightSprite(id))
        case .weaponGlow:    return untimed(game.weaponGlowSprite(id))
        case .spob:          return untimed(game.spobSprite(id))
        case .spobDestroyed: return untimed(game.spobDestroyedSprite(id))
        case .weapon:        return untimed(game.weaponSprite(spinID: id))
        case .boom:          return game.boomSprite(id)
        case .asteroid:      return untimed(game.asteroidSprite(id))
        case .starfield:     return untimed(game.starfieldSprite())
        }
    }

    /// `[frameWidth, frameHeight, frameCount, columns, rows, surfaceWidth,
    /// surfaceHeight, animationRate]` for one decoded sheet, or empty if that
    /// resource has no graphic. `animationRate` is the `bööm`'s authored playback
    /// rate and 0 for every other kind (which are rotation sheets, indexed by
    /// heading, not timed animations).
    @Callable(autoSnakeCase: true) func spriteInfo(kind: Int, id: Int) -> PackedInt32Array {
        guard let found = decodedSheet(kind: kind, id: id) else { return PackedInt32Array() }
        let s = found.sheet
        return PackedInt32Array([
            s.frameWidth, s.frameHeight, s.frameCount,
            s.columns, s.rows, s.surfaceWidth, s.surfaceHeight, found.animationRate,
        ].map { Int32($0) })
    }

    /// The RGBA8 surface bytes (`surfaceWidth * surfaceHeight * 4`) for one
    /// decoded sheet. Call once per resource and cache the texture — a hull sheet
    /// is megabytes, and this copies all of it.
    @Callable(autoSnakeCase: true) func spriteRGBA(kind: Int, id: Int) -> PackedByteArray {
        guard let found = decodedSheet(kind: kind, id: id) else { return PackedByteArray() }
        // Convenience init from `[UInt8]` — one bulk copy, no per-byte Variant
        // crossing. Cached texture-side by GDScript.
        return PackedByteArray(found.sheet.rgba)
    }
}
