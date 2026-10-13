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
    /// reimplement pricing/mass-budget/trade-in rules. Persisted as `.evpilot`
    /// through `PilotSaves` — see "Pilots & saves" at the end of this class.
    private var pilot = PlayerState()
    private var pilotStarted = false
    /// The pilot directory in use and the save id the live pilot writes to.
    private var pilotArchive: PilotArchive?
    private var pilotSaveID: UUID?

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
    /// Sound cues + the voice board (see "Audio" at the end of this class).
    private var sound = SoundState()

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
        sound.resetForNewWorld()
        interactionsWorldRebuilt()   // close hail/plunder windows, bring the escort wing back
        storyWorldRebuilt()          // attach the mission-ship host, drop active missions' ships in
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
        let player = galaxy.makeLoadedShip(pilot.shipType, extraOutfits: pilot.outfits, at: Vec2(),
                                            includeDefaultItems: false,
                                            includeHullWeapons: false)
            ?? Ship(name: "Player", stats: ShipStats(speed: 300, acceleration: 300, turnRate: 100))
        player.cargo = pilot.cargo

        let (w, _) = GameSession.makeWorld(game: game, systemID: sysID, player: player, galaxy: galaxy)
        // A pilot saved at a spaceport (the original's only save point) resumes
        // at that stellar's centre, at rest, on a random whole-degree heading
        // (FL-20) — mirrors GameContainerView's resume placement.
        if let sid = pilot.landedSpob, let body = w.systemContext.bodies.first(where: { $0.id == sid }) {
            player.position = body.position
            player.angle = Double(Int.random(in: 0..<360)) * .pi / 180
            player.velocity = Vec2()
        }
        pilot.landedSpob = nil
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

    /// Analog aim (a controller's right stick): rotate toward `heading` — radians,
    /// compass (0 = screen up, clockwise), the same `ControlIntent.desiredHeading`
    /// the Apple app's `GameControllerInput` feeds. Call *after* `setIntent`, which
    /// replaces the whole intent; `active == false` clears it. Discrete turns still
    /// win inside the engine, exactly as on Apple.
    @Callable(autoSnakeCase: true)
    func setAimHeading(active: Bool, heading: Double) {
        intent.desiredHeading = active ? heading : nil
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
        // The engine flies a hyperjump itself; held keys mustn't fight it.
        world.intent = world.playerJump == nil ? self.intent : ControlIntent()

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
        tickSoundAlarms(dt: dt)       // red alert / klaxxon / warp-up cue
        tickInteractions(dt: dt)      // Escort Commands panel clock
        tickStory(dt: dt)             // sightings, queued world edits
        advanceHyperjump()            // arrival once the engine's jump has fired
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
            sound.pending.append(contentsOf: SoundCues.cues(for: event, game: game))
            interactionsNote(event)       // tribute / lost escort -> pilot
            storyNote(event)              // mission ship goals / losses, fail-if-disabled
            if case let .combatChatter(soundID) = event { sound.chatterSoundID = soundID }
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
        // Fuel goes the same way: the pilot owns the tank level while docked
        // (refuelling is paid), and `launch()` carries it back out.
        if let ship = world?.player { pilot.cargo = ship.cargo; pilot.fuel = ship.fuel }
        storyLeavingSystem()                      // surviving aux ships go back to their budgets
        dockedSpobID = target.id
        sound.pending.append(SoundCues.docking)   // .shipLanded for entity 0: snd 390
        pilot.landedSpob = target.id
        // The landing pass: offer lists refresh, cargo is picked up / dropped, and a
        // mission whose objective is done here completes and pays (0x00443780).
        if let engine = storyEngine() {
            engine.playerLanded(onSpob: target.id)
            storyCommit(engine)
        }
        visitDays = SpaceportVisitDays()
        outfitterOwnedAtOpen = nil
        // The auto-refueller (oütf ModType 19) runs on docking, skipped at an
        // uninhabited stellar — shared with the Apple spaceport.
        if let galaxy, let spob = game?.spob(target.id) {
            SpaceportShops.autoRecharge(&pilot, spob: spob, galaxy: galaxy)
        }
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
        // The original's launch-tail save, still docked at this stellar: that is
        // the pilot's restore point (UI-01).
        pilot.landedSpob = spobID
        // The visit's days (FL-05): the dock-and-launch tick, +1 for outfitter
        // trades, +4 for a ship purchase — then the launch-tail save.
        let days = visitDays.departureDays
        visitDays = SpaceportVisitDays()
        storyBindHooks()
        let story = StoryEngine(game: game, player: pilot, services: storyState.services)
        story.advanceDays(days)
        pilot = story.player
        autosave(.launch)
        // In flight again: the mission pass runs (a deadline that ran out while
        // docked fails now) and a `Q` staged while landed is handed back.
        var launchMessage: String?
        if let engine = storyEngine() {
            launchMessage = engine.playerLaunched()
            pilot = engine.player
        }
        // Rebuild from the pilot's current loadout, not the old flight `Ship` —
        // trade/outfit/shipyard transactions while docked only mutate `pilot`
        // (see the trade section below), matching the Apple app's
        // `buildPlayerShip` (a fresh loaded ship each landing/launch, cargo
        // carried in from `pilot.cargo`).
        let player = galaxy.makeLoadedShip(pilot.shipType, extraOutfits: pilot.outfits, at: Vec2(),
                                            includeDefaultItems: false,
                                            includeHullWeapons: false)
            ?? world?.player ?? Ship(name: "Player", stats: ShipStats(speed: 300, acceleration: 300, turnRate: 100))
        player.cargo = pilot.cargo
        // The pilot's real tank level (a nil level reads as full), as the Apple
        // app's `buildPlayerShip` does.
        player.fuel = pilot.fuel.map { min($0, player.maxFuel) } ?? player.maxFuel
        // A story `M`/`N` op fired while docked moves where the takeoff happens.
        let (w, _) = GameSession.makeWorld(game: game, systemID: currentSystemID ?? sysID, player: player, galaxy: galaxy)
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
        if let launchMessage, !launchMessage.isEmpty { storyState.services.messages.append(launchMessage) }
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
        guard let galaxy = self.galaxy else { return 0 }
        let m = market()
        guard index >= 0, index < m.count else { return 0 }
        return PilotEconomy.held(pilot, cargo: m[index].commodity.cargoID, game: galaxy.game)
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
        guard let galaxy = self.galaxy else { return 0 }
        let m = market()
        guard index >= 0, index < m.count else { return 0 }
        return PilotEconomy.sellCommodity(&pilot, m[index].commodity, tons: tons, unitPrice: m[index].price,
                                          game: galaxy.game)
    }

    // MARK: Navigation & hyperjump
    //
    // The galaxy map and the hyperspace jump. Routing, fog-of-war, fuel and the
    // jump maneuver itself are shared code (`StarMapRoute`, `StarMapNavigator`,
    // `PlayerHyperjump`, `HyperjumpCommit`) — the same types the Apple app's
    // `NavigationModel`/`GameScene` run. This section resolves the pilot/world
    // handles and marshals; the in-flight align → accelerate → flash is flown by
    // the engine (`World.playerJump`, ticked by `World.step`) and completed in
    // `advanceHyperjump`, which `step` calls after its ticks.

    private var nav = NavState()

    private func navigator() -> StarMapNavigator? {
        guard let game else { return nil }
        return StarMapNavigator(game: game, hidden: nav.hidden, visibilityKnown: true)
    }

    /// Re-read which systems the story hides and drop/replace route hops that
    /// went hidden (`System_UpdateSystemAndStellarDisplayState` 0x00432470).
    private func refreshNavVisibility() {
        guard let game else { return }
        let hidden = game.hiddenSystemIDs(for: pilot)
        nav.hidden = hidden
        let nv = StarMapNavigator(game: game, hidden: hidden, visibilityKnown: true)
        nav.route.revalidate(isVisible: { !hidden.contains($0) }, resolveVisible: { nv.resolveVisible($0) })
    }

    private func knownSets() -> (explored: Set<Int>, charted: Set<Int>) {
        (pilot.exploredSystems, pilot.chartedSystems ?? [])
    }

    /// Re-sync story visibility; call when the map opens.
    @Callable(autoSnakeCase: true) func navRefresh() { refreshNavVisibility() }

    /// The system the player is in.
    @Callable(autoSnakeCase: true) func navCurrentSystem() -> Int { currentSystemID ?? -1 }

    /// Floats per `nav_systems` row.
    @Callable(autoSnakeCase: true) func navStride() -> Int { 8 }

    /// Every drawable system (visible and not fogged out entirely), as rows of
    /// `[id, x, y, visibility, r, g, b, govt]`. Map coordinates are the data's
    /// (+y down). `visibility`: 1 adjacent (dim, unnamed), 2 charted, 3 explored.
    @Callable(autoSnakeCase: true) func navSystems() -> PackedFloat32Array {
        guard let game, let nv = navigator() else { return PackedFloat32Array() }
        let known = knownSets()
        let adjacent = nv.adjacentToKnown(explored: known.explored, charted: known.charted)
        let palette = GovernmentMapPalette(game: game)
        var flat: [Float] = []
        for s in game.systems() where !nav.hidden.contains(s.id) {
            let vis: Float
            switch StarMapNavigator.visibility(of: s.id, explored: known.explored, adjacent: adjacent, charted: known.charted) {
            case .unknown: continue
            case .adjacent: vis = 1
            case .chartered: vis = 2
            case .explored: vis = 3
            }
            let c = palette.color(for: s.government)
            flat += [Float(s.id), Float(s.x), Float(s.y), vis, Float(c[0]), Float(c[1]), Float(c[2]), Float(s.government)]
        }
        return PackedFloat32Array(flat)
    }

    /// Hyperspace links between drawable systems, as `[a, b]` id pairs.
    @Callable(autoSnakeCase: true) func navLinks() -> PackedInt32Array {
        guard let game, let nv = navigator() else { return PackedInt32Array() }
        let known = knownSets()
        let adjacent = nv.adjacentToKnown(explored: known.explored, charted: known.charted)
        func drawn(_ id: Int) -> Bool {
            !nav.hidden.contains(id) && StarMapNavigator.visibility(
                of: id, explored: known.explored, adjacent: adjacent, charted: known.charted) != .unknown
        }
        var flat: [Int32] = []
        for s in game.systems() where drawn(s.id) {
            for link in nv.visibleNeighbors(s.id) where link > s.id && drawn(link) {
                flat += [Int32(s.id), Int32(link)]
            }
        }
        return PackedInt32Array(flat)
    }

    /// Display name of a system the player knows by name (visited or charted);
    /// "" for a merely adjacent one — the map shows those unnamed.
    @Callable(autoSnakeCase: true) func navSystemName(id: Int) -> String {
        guard let game, let s = game.system(id) else { return "" }
        let known = knownSets()
        return known.explored.contains(id) || known.charted.contains(id) ? s.displayName : ""
    }

    /// The controlling government's name, for the info panel ("" = independent).
    @Callable(autoSnakeCase: true) func navSystemGovernment(id: Int) -> String {
        guard let game, let s = game.system(id), s.government >= 0 else { return "" }
        let known = knownSets()
        guard known.explored.contains(id) || known.charted.contains(id) else { return "" }
        return game.govt(s.government)?.name ?? ""
    }

    /// Hops one jump command can cross (multi-jump outfits), at least 1.
    @Callable(autoSnakeCase: true) func navMaxJumpHops() -> Int {
        guard let galaxy else { return 1 }
        return PilotEconomy.maxJumpHops(pilot, galaxy: galaxy)
    }

    // Route plotting. `nav_click`/`nav_shift_click` are the original's rules
    // (UI-05: a click arms a linked system, Shift+click extends hop by hop);
    // `nav_plot_course` is the `autoRoutePlotting` enhancement's fewest-jumps path.

    /// A plain click on a map system. Returns whether it armed a jump.
    @Callable(autoSnakeCase: true) func navClick(id: Int) -> Bool {
        guard let nv = navigator(), let cur = currentSystemID else { return false }
        refreshNavVisibility()
        nav.selected = id
        return nav.route.click(id, current: cur, linked: nv.isLinked)
    }

    /// A Shift+click: extend the route from its tail, truncate at a plotted hop,
    /// or clear it on the current system. Returns whether a jump is armed.
    @Callable(autoSnakeCase: true) func navShiftClick(id: Int) -> Bool {
        guard let nv = navigator(), let cur = currentSystemID else { return false }
        refreshNavVisibility()
        nav.selected = id
        nav.route.shiftClick(id, current: cur, linked: nv.isLinked)
        return nav.route.armed
    }

    /// Plot the fewest-jumps course to `id` (the `autoRoutePlotting` enhancement).
    /// False when unreachable.
    @Callable(autoSnakeCase: true) func navPlotCourse(id: Int) -> Bool {
        guard let cur = currentSystemID else { return false }
        refreshNavVisibility()
        nav.selected = id
        guard id != cur else { nav.route.clear(); return true }
        guard let path = navigator()?.shortestPath(from: cur, to: id) else { return false }
        nav.route.set(path, cap: false)
        return true
    }

    @Callable(autoSnakeCase: true) func navClearRoute() { nav.route.clear() }

    /// The plotted hops in order, excluding the current system.
    @Callable(autoSnakeCase: true) func navRoute() -> PackedInt32Array {
        PackedInt32Array(nav.route.hops.map { Int32($0) })
    }

    /// Whether the route's first hop is armed for a jump.
    @Callable(autoSnakeCase: true) func navRouteArmed() -> Bool { nav.route.armed }

    /// The map's selected system, or -1.
    @Callable(autoSnakeCase: true) func navSelected() -> Int { nav.selected ?? -1 }

    /// Hops the next jump command will cross (0 with nothing armed).
    @Callable(autoSnakeCase: true) func navNextJumpHops() -> Int {
        nav.route.armed ? min(navMaxJumpHops(), nav.route.hops.count) : 0
    }

    // Jump action.

    /// Engage the hyperdrive along the armed route. Returns the status-line text
    /// when refused ("" = engaged, or refused silently — check `hyperjump_active`):
    /// STR# 2002 #29 with no course, #10 without fuel for a jump, #42 too close
    /// to the system centre. The engine then flies the maneuver and `step`
    /// completes the arrival.
    @Callable(autoSnakeCase: true) func beginHyperjump() -> String {
        guard let world, let game, let galaxy, let cur = currentSystemID,
              dockedSpobID == nil, world.playerJump == nil else { return "" }
        refreshNavVisibility()
        let text = OriginalText(game: game)
        let hops = navNextJumpHops()
        guard hops > 0 else { return text.misc(29) }
        let p = world.player
        guard p.fuel >= ShipFuel.perJump else { return text.misc(10) }
        let radius = PilotEconomy.hyperspaceNoJumpRadius(pilot, galaxy: galaxy)
        switch world.hyperspaceRefusal(noJumpRadius: radius) {
        case nil: break
        case .silent?: return ""
        case .tooCloseToCentre?: return text.misc(42)
        }
        let route = nav.route.hops
        // The ship turns toward the armed first hop, even on a multi-jump (A9).
        let bearing = StarMapNavigator.outboundHeading(game: game, from: cur, to: route[0])
        world.playerJump = PlayerHyperjump(
            bearing: bearing, fastJump: PilotEconomy.hasInstantJump(pilot, galaxy: galaxy),
            soundTicks60: galaxy.hyperspaceWarpUpSoundTicks60,
            soundTicks60X2: galaxy.hyperspaceWarpUp2xSoundTicks60,
            multiplier: galaxy.jumpDurationMultiplier(hull: p.shipTypeID))
        nav.pending = PendingHyperjump(destination: route[hops - 1], hops: hops,
                                       passedThrough: Array(route.prefix(max(0, hops - 1))), bearing: bearing)
        return ""
    }

    /// True from engage until the arrival (or collapse).
    @Callable(autoSnakeCase: true) func hyperjumpActive() -> Bool { world?.playerJump != nil }

    /// `[phase, progress, fadeTriggered, bearing]` for the jump visual. Phase:
    /// 0 none, 1 braking, 2 spinning up (the tunnel), 3 fired. `fadeTriggered`
    /// is the original's white fade (progress past 55).
    @Callable(autoSnakeCase: true) func hyperjumpState() -> PackedFloat32Array {
        guard let jump = world?.playerJump else { return PackedFloat32Array([0, 0, 0, 0]) }
        let phase: Float
        switch jump.phase {
        case .brake: phase = 1
        case .spinUp: phase = 2
        case .fired, .collapsed: phase = 3
        }
        return PackedFloat32Array([phase, Float(jump.progress), jump.fadeTriggered ? 1 : 0, Float(jump.bearing)])
    }

    /// The name of the system just jumped into (once), else "".
    @Callable(autoSnakeCase: true) func takeJumpArrival() -> String {
        defer { nav.arrivedIn = nil }
        return nav.arrivedIn ?? ""
    }

    /// Status-line messages the jump produced (e.g. a collapsed field), drained.
    @Callable(autoSnakeCase: true) func drainNavMessages() -> PackedStringArray {
        defer { nav.messages.removeAll() }
        return PackedStringArray(nav.messages)
    }

    /// Called by `step` after its ticks: finish a fired jump or clean up a dead one.
    private func advanceHyperjump() {
        guard let world, let jump = world.playerJump else { return }
        guard world.player.isAlive, let plan = nav.pending else {
            world.playerJump = nil; nav.pending = nil; return
        }
        switch jump.phase {
        case .fired: completeHyperjump(plan)
        case .collapsed:
            // Ship disabled - hyperspace field collapsed (STR# 2002 #35): no system change.
            world.playerJump = nil
            nav.pending = nil
            sound.board.stop(soundID: SoundCues.hyperspaceChargeID)
            sound.board.stop(soundID: SoundCues.warpUp2xID)
            sound.pending.append(SoundCues.hyperspaceArrive)
            if let game { nav.messages.append(OriginalText(game: game).misc(35)) }
        case .brake, .spinUp: break
        }
    }

    /// The arrival half of the jump (`GameScene.reloadSystem` + the container's
    /// commit closure): spend the fuel, follow the pilot, rebuild the destination
    /// reusing the player's ship (fuel/damage/cargo carry) and place it as the
    /// original does on a hyperspace arrival (FL-13).
    private func completeHyperjump(_ plan: PendingHyperjump) {
        guard let world, let game, let galaxy, let nv = navigator() else { return }
        let ship = world.player
        storyLeavingSystem()                         // surviving aux ships go back to their budgets
        _ = world.returnJumpingFighters()
        let escortDays = world.attachedShipsTravelDays(galaxy: galaxy)
        ship.consumeJumpFuel()                       // one jump, however many hops (FL-06)
        nav.route.arrive(at: plan.destination, crossing: plan.hops, linked: nv.isLinked)
        nav.selected = nil
        pilot.cargo = ship.cargo
        HyperjumpCommit.apply(&pilot, game: game, galaxy: galaxy, destination: plan.destination,
                              passedThrough: plan.passedThrough, shipFuel: ship.fuel, extraDays: escortDays,
                              services: storyState.services)
        // The mission pass runs after a jump's days: a deadline that ran out fails now.
        storyBindHooks()
        if !pilot.activeMissions.isEmpty, let engine = storyEngine() {
            engine.missionFlightPass()
            pilot = engine.player
        }

        let (w, _) = GameSession.makeWorld(game: game, systemID: plan.destination, player: ship, galaxy: galaxy)
        w.previousSystemBearing = plan.bearing + .pi   // AI-14: mission ships jump in from where we came
        w.placePlayerAtHyperspaceArrival(bearing: plan.bearing)
        ship.currentTargetID = nil
        ship.wantsToDepart = false
        self.world = w
        self.intent = ControlIntent()
        currentSystemID = plan.destination
        pilot.currentSystem = plan.destination
        nav.pending = nil
        refreshNavVisibility()
        if let nv = navigator() { nav.route.sync(current: plan.destination, linked: nv.isLinked) }
        nav.arrivedIn = game.system(plan.destination)?.displayName ?? ""
        resetFrameState()
        sound.board.stop(soundID: SoundCues.hyperspaceChargeID)   // the jump cut its Warp up
        sound.board.stop(soundID: SoundCues.warpUp2xID)
        sound.pending.append(SoundCues.hyperspaceArrive)           // arriving: Warp out
    }

    // MARK: Spaceport (outfitter/shipyard)
    //
    // The landed screens (godot/screens/Spaceport.gd). Every rule — which outfits
    // and hulls are listed, what can be bought, prices, trade-ins, refuelling,
    // trade rows — is shared code (`SpaceportShops`, `PilotEconomy`,
    // `LandedServices`, `LockState`) that the Apple spaceport calls too; this
    // section only resolves the docked spöb and marshals. Lists cross as JSON.

    /// What the pilot owned when the outfitter opened: units bought this visit
    /// sell back at full price, the rest at half (EC-07).
    private var outfitterOwnedAtOpen: [Int: Int]?
    /// Days the visit will cost on departure (outfitter +1, ship purchase +4).
    private var visitDays = SpaceportVisitDays()

    private func shopContext() -> (game: NovaGame, galaxy: Galaxy, spob: SpobRes)? {
        guard let game, let galaxy, let spob = dockedSpob else { return nil }
        return (game, galaxy, spob)
    }

    /// STR# 150 button label (1-based), with a fallback.
    private func buttonLabel(_ index: Int, _ fallback: String) -> String {
        let s = game?.stringList(150)?.string(at: index) ?? ""
        return s.isEmpty ? fallback : s
    }

    /// The landing screen: `{id, name, description, shipyard, outfitter, trade,
    /// bar, uninhabited, needsRecharge, fuel, maxFuel, credits, labels{…}}`.
    @Callable(autoSnakeCase: true) func spaceportInfo() -> String {
        guard let c = shopContext() else { return "{}" }
        let s = c.spob
        let maxFuel = SpaceportShops.maxFuel(pilot, galaxy: c.galaxy) ?? 0
        return Self.json([
            "id": s.id, "name": s.name, "description": c.game.descText(s.id),
            "shipyard": s.hasShipyard, "outfitter": s.hasOutfitter, "trade": s.hasCommodityExchange,
            "bar": s.hasBar, "uninhabited": s.isUninhabited,
            "needsRecharge": SpaceportShops.needsRecharge(pilot, spob: s, galaxy: c.galaxy),
            "fuel": SpaceportShops.currentFuel(pilot, galaxy: c.galaxy) / 100, "maxFuel": maxFuel / 100,
            "credits": pilot.credits,
            "labels": [
                "leave": buttonLabel(1, "Leave"), "buy": buttonLabel(2, "Buy"), "sell": buttonLabel(3, "Sell"),
                "buyShip": buttonLabel(4, "Buy Ship"), "done": buttonLabel(5, "Done"),
                "recharge": buttonLabel(6, "Recharge"), "trade": buttonLabel(7, "Trade Center"),
                "outfitter": buttonLabel(8, "Outfitter"), "shipyard": buttonLabel(9, "Shipyard"),
                "bar": buttonLabel(10, "Bar"), "info": buttonLabel(48, "Info"),
            ] as [String: String],
        ] as [String: Any])
    }

    /// The Recharge button: credits spent, or -1 when it did nothing.
    @Callable(autoSnakeCase: true) func spaceportRecharge() -> Int {
        guard let c = shopContext() else { return -1 }
        return SpaceportShops.recharge(&pilot, spob: c.spob, galaxy: c.galaxy) ?? -1
    }

    // Pictures. `kind`: 0 PICT id as given · 1 spöb landing picture (id = spöb)
    // · 2 outfit picture (id = oütf) · 3 ship picture (id = shïp). Resolution of
    // which PICT is shared (`NovaGame.landscapePictID` & co); -1 = none.

    @Callable(autoSnakeCase: true) func spaceportPictureID(kind: Int, id: Int) -> Int {
        guard let game else { return -1 }
        let pict: Int?
        switch kind {
        case 0: pict = id
        case 1: pict = game.spob(id).map { game.landscapePictID(for: $0) }
        case 2: pict = game.outfit(id).map { game.outfitPictID($0) }
        case 3: pict = game.ship(id).flatMap { game.shipPictID(for: $0) }
        default: pict = nil
        }
        guard let p = pict, game.hasPICT(p) else { return -1 }
        return p
    }

    /// `[width, height]` of a decoded PICT, or empty.
    @Callable(autoSnakeCase: true) func pictInfo(pictID: Int) -> PackedInt32Array {
        guard let s = game?.pictSheet(pictID) else { return PackedInt32Array() }
        return PackedInt32Array([Int32(s.surfaceWidth), Int32(s.surfaceHeight)])
    }

    /// RGBA8 bytes of a PICT (`width*height*4`). Cache the texture GDScript-side.
    @Callable(autoSnakeCase: true) func pictRGBA(pictID: Int) -> PackedByteArray {
        guard let s = game?.pictSheet(pictID) else { return PackedByteArray() }
        return PackedByteArray(s.rgba)
    }

    // Trade Center. Rows are `LandedServices.tradeRows` (reputation/domination
    // scale, disasters, the two junk rows), addressed by row index.

    private func tradeRowList() -> [LandedServices.TradeRow] {
        guard let c = shopContext() else { return [] }
        return LandedServices.tradeRows(at: c.spob, state: pilot, game: c.game)
    }

    /// `{rows:[{name, level, label, price, held}], status, disaster, headers[3],
    /// credits}` for the Trade Center.
    @Callable(autoSnakeCase: true) func tradeView() -> String {
        guard let c = shopContext() else { return "{}" }
        let rows = tradeRowList()
        let text = OriginalText(game: c.game)
        func misc(_ n: Int, _ fallback: String) -> String { let s = text.misc(n); return s.isEmpty ? fallback : s }
        let shipCap = PilotEconomy.shipCargoCapacity(pilot, galaxy: c.galaxy)
        let fleetCap = PilotEconomy.cargoCapacity(pilot, galaxy: c.galaxy)
        let out: [[String: Any]] = rows.map { r in
            let name = Commodity.standard(cargoID: r.cargoID).map { c.game.commodityName($0) }
                ?? c.game.junk(r.cargoID)?.name ?? "\(r.cargoID)"
            var label = r.level.label
            if r.disaster, let up = LandedServices.disasterRaised(cargoID: r.cargoID, at: c.spob.id, state: pilot, game: c.game) {
                label = misc(up ? 204 : 205, label)
            }
            return ["name": name, "level": r.level.rawValue, "label": label, "price": r.price,
                    "held": PilotEconomy.held(pilot, cargo: r.cargoID, game: c.game)]
        }
        let status = LandedServices.tradeStatus(state: pilot, game: c.game, shipCapacity: shipCap,
                                                fleetCapacity: fleetCap,
                                                junkRows: Set(rows.map(\.cargoID).filter { $0 >= 128 }))
            .replacingOccurrences(of: "\r", with: "\n")
        return Self.json([
            "rows": out, "status": status,
            "disaster": LandedServices.tradeDisasterLine(at: c.spob.id, state: pilot, game: c.game) ?? "",
            "headers": [misc(197, "Commodity"), misc(200, "Price"), misc(shipCap < fleetCap ? 198 : 199, "Hold")],
            "credits": pilot.credits,
        ] as [String: Any])
    }

    /// Tons a Buy (or Sell) of `row` would move: `LandedServices.tradeQuantity`
    /// with `prompted` = -1 for a plain click (10 at most) or the typed amount.
    /// With `prompted` = 32000 this is also the quantity prompt's ceiling.
    @Callable(autoSnakeCase: true) func tradeQuantity(row: Int, buying: Bool, prompted: Int) -> Int {
        guard let c = shopContext() else { return 0 }
        let rows = tradeRowList()
        guard row >= 0, row < rows.count else { return 0 }
        return LandedServices.tradeQuantity(buying: buying, prompted: prompted < 0 ? nil : prompted,
                                            credits: pilot.credits, price: rows[row].price,
                                            cargoFree: PilotEconomy.cargoFree(pilot, galaxy: c.galaxy),
                                            held: PilotEconomy.held(pilot, cargo: rows[row].cargoID, game: c.game))
    }

    /// Buy/sell `tons` of trade row `row`; returns the tons moved.
    @discardableResult
    @Callable(autoSnakeCase: true) func tradeBuy(row: Int, tons: Int) -> Int {
        guard let c = shopContext() else { return 0 }
        let rows = tradeRowList()
        guard row >= 0, row < rows.count else { return 0 }
        return PilotEconomy.buyCargo(&pilot, id: rows[row].cargoID, tons: min(tons, 32000), unitPrice: rows[row].price,
                                     cargoFree: PilotEconomy.cargoFree(pilot, galaxy: c.galaxy))
    }

    @discardableResult
    @Callable(autoSnakeCase: true) func tradeSell(row: Int, tons: Int) -> Int {
        guard let c = shopContext() else { return 0 }
        let rows = tradeRowList()
        guard row >= 0, row < rows.count else { return 0 }
        return PilotEconomy.sellCargo(&pilot, id: rows[row].cargoID, tons: min(tons, 32000),
                                      unitPrice: rows[row].price, game: c.game)
    }

    // Outfitter.

    /// Snapshot what's owned now (call when the outfitter opens).
    @Callable(autoSnakeCase: true) func outfitterOpen() { outfitterOwnedAtOpen = pilot.outfits }

    private func outfitterOwned(_ id: Int) -> Int? { outfitterOwnedAtOpen.map { $0[id] ?? 0 } }

    /// `{credits, freeMass, cargoUsed, cargoCapacity}` for the outfitter's info panel.
    @Callable(autoSnakeCase: true) func outfitterState() -> String {
        guard let c = shopContext() else { return "{}" }
        return Self.json(["credits": pilot.credits, "freeMass": PilotEconomy.freeMass(pilot, galaxy: c.galaxy),
                          "cargoUsed": PilotEconomy.cargoUsed(pilot),
                          "cargoCapacity": PilotEconomy.cargoCapacity(pilot, galaxy: c.galaxy)] as [String: Any])
    }

    /// The outfitter's list in display order: `[{id, name, price, owned, mass,
    /// locked, canBuy, canSell, salePrice, plural}]`.
    @Callable(autoSnakeCase: true) func outfitterList() -> String {
        guard let c = shopContext() else { return "[]" }
        let diplomacy = c.galaxy.makeDiplomacy()
        let stock = SpaceportShops.outfitList(game: c.game, spob: c.spob, state: pilot, diplomacy: diplomacy,
                                              owned: pilot.outfits)
        let sellOnly = SpaceportShops.outfitSellOnlyIDs(game: c.game, spob: c.spob, state: pilot, diplomacy: diplomacy)
        let rows: [[String: Any]] = stock.map { o in
            let lock = c.game.lockState(for: o, pilot: pilot, at: c.spob, diplomacy: diplomacy)
            return [
                "id": o.id, "name": o.outfitterDisplayName, "price": PilotEconomy.effectiveCost(pilot, o, galaxy: c.galaxy),
                "owned": PilotEconomy.owned(pilot, outfit: o.id), "mass": o.mass,
                "locked": lock == .locked, "sellOnly": sellOnly.contains(o.id),
                "canBuy": SpaceportShops.canBuyOutfit(o, game: c.game, galaxy: c.galaxy, spob: c.spob, state: pilot,
                                                      diplomacy: diplomacy, sellOnly: sellOnly),
                "canSell": PilotEconomy.canSellOutfit(pilot, o),
                "salePrice": PilotEconomy.outfitSalePrice(pilot, o, galaxy: c.galaxy, ownedAtOpen: outfitterOwned(o.id)),
                "plural": o.lowercasePluralDisplayName,
            ]
        }
        return Self.json(rows)
    }

    /// The outfit's description text (`dësc` 3000 + id − 128).
    @Callable(autoSnakeCase: true) func outfitterDescription(id: Int) -> String {
        game?.descText(id - 128 + 3000) ?? ""
    }

    /// The quantity prompt's ceiling: buy is capped by afford / max-installed
    /// headroom (each unit is still rule-checked by `buyOutfit(count:)`), sell by owned.
    @Callable(autoSnakeCase: true) func outfitterMax(id: Int, buying: Bool) -> Int {
        guard let c = shopContext(), let o = c.game.outfit(id) else { return 0 }
        if !buying { return PilotEconomy.owned(pilot, outfit: id) }
        guard PilotEconomy.canBuyOutfit(pilot, o, galaxy: c.galaxy) else { return 1 }
        let cost = PilotEconomy.effectiveCost(pilot, o, galaxy: c.galaxy)
        let affordable = cost > 0 ? pilot.credits / cost : Int.max
        let cap = PilotEconomy.maxInstallable(pilot, o, galaxy: c.galaxy)
        return cap > 0 ? min(affordable, max(0, cap - PilotEconomy.owned(pilot, outfit: id))) : affordable
    }

    /// Buy / sell `count` of outfit `id`; returns how many were transacted.
    @discardableResult
    @Callable(autoSnakeCase: true) func outfitterBuy(id: Int, count: Int) -> Int {
        guard let c = shopContext(), let o = c.game.outfit(id) else { return 0 }
        let sellOnly = SpaceportShops.outfitSellOnlyIDs(game: c.game, spob: c.spob, state: pilot,
                                                        diplomacy: c.galaxy.makeDiplomacy())
        guard !sellOnly.contains(id),
              c.game.lockState(for: o, pilot: pilot, at: c.spob, diplomacy: c.galaxy.makeDiplomacy()) == .available
        else { return 0 }
        let n = PilotEconomy.buyOutfit(&pilot, o, count: count, galaxy: c.galaxy)
        if n > 0 { visitDays.outfitTransaction = true }
        return n
    }

    @discardableResult
    @Callable(autoSnakeCase: true) func outfitterSell(id: Int, count: Int) -> Int {
        guard let c = shopContext(), let o = c.game.outfit(id) else { return 0 }
        let n = PilotEconomy.sellOutfit(&pilot, o, count: count, galaxy: c.galaxy, ownedAtOpen: outfitterOwned(id))
        if n > 0 { visitDays.outfitTransaction = true }
        return n
    }

    // Shipyard.

    /// `{credits, tradeIn}`.
    @Callable(autoSnakeCase: true) func shipyardState() -> String {
        guard let c = shopContext() else { return "{}" }
        return Self.json(["credits": pilot.credits,
                          "tradeIn": SpaceportShops.tradeInValue(pilot, at: c.spob, galaxy: c.galaxy)] as [String: Any])
    }

    /// Hulls for sale in order: `[{id, name, price (net of trade-in), locked,
    /// canBuy, current}]`.
    @Callable(autoSnakeCase: true) func shipyardList() -> String {
        guard let c = shopContext() else { return "[]" }
        let rows: [[String: Any]] = SpaceportShops.shipyardList(game: c.game, spob: c.spob, state: pilot).map { s in
            ["id": s.id, "name": s.displayName,
             "price": SpaceportShops.netPrice(pilot, of: s, at: c.spob, galaxy: c.galaxy),
             "locked": c.game.lockState(for: s, pilot: pilot) == .locked,
             "canBuy": SpaceportShops.canBuyShip(s, game: c.game, galaxy: c.galaxy, spob: c.spob, state: pilot),
             "current": s.id == pilot.shipType]
        }
        return Self.json(rows)
    }

    /// The Ship Info card: `{name, subtitle, description, stats[[label,value]],
    /// weapons[], outfits[], price}`.
    @Callable(autoSnakeCase: true) func shipyardInfo(id: Int) -> String {
        guard let c = shopContext(), let s = c.game.ship(id) else { return "{}" }
        let stats: [[String]] = [
            ["Speed", "\(s.speed)"], ["Accel", "\(s.acceleration)"], ["Turn", "\(s.turnRate)"],
            ["Mass", "\(s.mass)"], ["Cargo", "\(s.cargoSpace) t"], ["Free mass", "\(s.freeMass) t"],
            ["Fuel", "\(s.fuelCapacity / 100) jumps"], ["Shield", "\(s.shield)"], ["Armor", "\(s.armor)"],
            ["Guns", "\(s.maxGuns)"], ["Turrets", "\(s.maxTurrets)"], ["Crew", "\(s.crew)"],
        ]
        return Self.json([
            "name": s.displayName, "subtitle": s.subtitle.novaDisplayName,
            "description": SpaceportShops.classDescription(s, game: c.game), "stats": stats,
            "weapons": SpaceportShops.standardWeapons(s, game: c.game),
            "outfits": SpaceportShops.standardOutfits(s, game: c.game),
            "price": SpaceportShops.netPrice(pilot, of: s, at: c.spob, galaxy: c.galaxy),
        ] as [String: Any])
    }

    /// Buy hull `id` here (trade-in credited; the old fittings go with the old
    /// ship). The next launch flies the new hull.
    @Callable(autoSnakeCase: true) func shipyardBuy(id: Int) -> Bool {
        guard let c = shopContext(), let s = c.game.ship(id),
              SpaceportShops.shipyardList(game: c.game, spob: c.spob, state: pilot).contains(where: { $0.id == id }),
              SpaceportShops.canBuyShip(s, game: c.game, galaxy: c.galaxy, spob: c.spob, state: pilot)
        else { return false }
        let ok = SpaceportShops.buyShip(&pilot, s, at: c.spob, galaxy: c.galaxy)
        if ok { visitDays.shipPurchase = true }
        return ok
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

    // MARK: Pilots & saves
    //
    // The same `.evpilot` files the Apple app writes: `PilotArchive` (one
    // `<uuid>.evpilot` per save + rotating `Backups/`), driven through the portable
    // `PilotSaves` / `PilotFactory` / `PilotSavePolicy` in NovaSwiftStory. Godot
    // passes the directory (it resolves `user://pilots`); this section only
    // marshals. Lists cross as JSON strings — a handful of rows, once per menu
    // visit — which GDScript turns into Dictionaries with `JSON.parse_string`.

    /// The archive for `dir`, reused while the path is unchanged.
    private func archive(at dir: String) -> PilotArchive {
        if let a = pilotArchive, a.root.path == URL(fileURLWithPath: dir).path { return a }
        let a = PilotArchive(location: .local(URL(fileURLWithPath: dir, isDirectory: true)))
        pilotArchive = a
        return a
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// The starting scenarios (`chär`) as JSON
    /// `[{id, name, ship, cash}]` in the order the Apple picker shows them
    /// (`selectableScenarios`). Empty `[]` with no game loaded.
    @Callable(autoSnakeCase: true) func pilotScenarios() -> String {
        guard let game else { return "[]" }
        return Self.json(game.selectableScenarios().map { ch -> [String: Any] in
            ["id": ch.id, "name": ch.displayName,
             "ship": game.ship(ch.shipID)?.name ?? "", "cash": ch.cash]
        })
    }

    /// Saved pilots as JSON, one row per pilot (a pilot's save slots collapse to
    /// the most recently played, as the Apple roster does), newest first:
    /// `[{id, name, ship, system, credits, rating, scenario, updated}]`.
    @Callable(autoSnakeCase: true) func pilotList(dir: String) -> String {
        let saves = archive(at: dir).list()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        var best: [UUID: PilotSave] = [:]
        for s in saves where (best[s.pilotGroupID]?.updatedAt ?? .distantPast) < s.updatedAt {
            best[s.pilotGroupID] = s
        }
        let rows = best.values.sorted { $0.updatedAt > $1.updatedAt }.map { s -> [String: Any] in
            ["id": s.id.uuidString, "name": s.displayName, "ship": s.snapshot.shipName,
             "system": s.snapshot.systemName, "credits": s.snapshot.credits,
             "rating": s.snapshot.ratingTitle, "scenario": s.scenarioName,
             "updated": fmt.string(from: s.updatedAt)]
        }
        return Self.json(rows)
    }

    /// A random pilot name (the dice button; also what a pad player uses instead
    /// of typing). Shared with the Apple app's `PilotNames`.
    @Callable(autoSnakeCase: true) func pilotRandomName() -> String { PilotNames.random() }

    /// The new-pilot dialog's prefilled field from STR# 128 (0 pilot name,
    /// 1 nickname, 2 ship name), as `PilotFactory.defaultName` does.
    @Callable(autoSnakeCase: true) func pilotDefaultName(field: Int) -> String {
        guard let game else { return "" }
        let f: PilotFactory.NameField = field == 1 ? .nickname : (field == 2 ? .ship : .pilot)
        return PilotFactory.defaultName(f, game: game)
    }

    /// Longest name the new-pilot dialog accepts (`PilotFactory.maxNameLength`).
    @Callable(autoSnakeCase: true) func pilotMaxNameLength() -> Int { PilotFactory.maxNameLength }

    /// Create a pilot from scenario `scenarioID`, write it to `dir` and make it
    /// the live pilot. Returns the new save's id, or "" on failure. The frontend
    /// follows with `make_world(-1)`. Writes at once — a new pilot is an original
    /// save point (`PilotSaveReason.newPilot`).
    @Callable(autoSnakeCase: true)
    func pilotCreate(dir: String, scenarioID: Int, name: String, isMale: Bool,
                     nickname: String, shipName: String) -> String {
        guard let game, let scenario = game.selectableScenarios().first(where: { $0.id == scenarioID }),
              name.count <= PilotFactory.maxNameLength else { return "" }
        let a = archive(at: dir)
        var save = PilotSaves.makeNew(name: name, isMale: isMale, scenario: scenario, game: game,
                                      nickname: nickname, shipName: shipName.isEmpty ? nil : shipName)
        save.player.rosterID = save.id
        guard let written = try? a.save(save, backup: false) else { return "" }
        var state = written.player
        PilotSaves.migrate(&state, game: game)
        adoptPilot(state, saveID: written.id)
        return written.id.uuidString
    }

    /// Load save `id` from `dir` as the live pilot (`PilotSaves.prepareForPlay`:
    /// full shield/armor, vanished plug-in data pruned). The frontend follows
    /// with `make_world(-1)`, which builds the pilot's saved system and launches
    /// it from the stellar it saved at.
    @Callable(autoSnakeCase: true) func pilotLoad(dir: String, id: String) -> Bool {
        guard let game, let uuid = UUID(uuidString: id),
              let save = try? archive(at: dir).load(id: uuid) else { return false }
        let prepared = PilotSaves.prepareForPlay(save, game: game)
        adoptPilot(prepared.state, saveID: uuid)
        return true
    }

    /// Delete a pilot — every save slot and backup — as the roster's
    /// `deleteGroup` does. Clears the live binding if it was the live pilot.
    @Callable(autoSnakeCase: true) func pilotDelete(dir: String, id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        let a = archive(at: dir)
        let group = a.list().first { $0.id == uuid }?.pilotGroupID
        let ids = group.map { g in a.list().filter { $0.pilotGroupID == g }.map(\.id) } ?? [uuid]
        for slot in ids { try? a.delete(id: slot) }
        if let live = pilotSaveID, ids.contains(live) { pilotSaveID = nil }
        return true
    }

    /// Write the live pilot now (forced, with a backup rotation) — the explicit
    /// Save action. False with no live roster pilot or on a write failure.
    @Callable(autoSnakeCase: true) func pilotSaveNow() -> Bool { writePilot(backup: true) }

    /// Save for `reason` only if the original does at that moment
    /// (`PilotSaveReason.shouldSave`): new pilot / launch / quit-while-landed
    /// always, the rest only under the `frequentAutosave` enhancement, which the
    /// Godot build doesn't offer yet. `reason` is a `PilotSaveReason` case name
    /// ("launch", "background", "backgroundLanded", ...). Returns whether it wrote.
    @Callable(autoSnakeCase: true) func pilotAutosave(reason: String) -> Bool {
        guard let r = Self.saveReason(reason) else { return false }
        return autosave(r)
    }

    /// True when a roster pilot is bound (so autosave has somewhere to write).
    @Callable(autoSnakeCase: true) func hasPilotSave() -> Bool { pilotSaveID != nil }

    @Callable(autoSnakeCase: true) func pilotName() -> String { pilot.pilotName }

    private static func saveReason(_ name: String) -> PilotSaveReason? {
        switch name {
        case "newPilot": return .newPilot
        case "launch": return .launch
        case "podRespawn": return .podRespawn
        case "manual": return .manual
        case "land": return .land
        case "jump": return .jump
        case "event": return .event
        case "periodic": return .periodic
        case "background": return .background
        case "backgroundLanded": return .backgroundLanded
        default: return nil
        }
    }

    private func adoptPilot(_ state: PlayerState, saveID: UUID) {
        pilot = state
        pilot.rosterID = saveID
        pilotSaveID = saveID
        pilotStarted = true
    }

    /// `AppModel.autosave`, minus the settings the Godot build doesn't have yet.
    @discardableResult
    private func autosave(_ reason: PilotSaveReason) -> Bool {
        guard pilotSaveID != nil,
              reason.shouldSave(frequentAutosave: false, strictPlay: pilot.isStrictPlay) else { return false }
        return writePilot(backup: reason.wantsBackup)
    }

    private func writePilot(backup: Bool) -> Bool {
        guard let a = pilotArchive, let id = pilotSaveID else { return false }
        // Without `frequentAutosave` the original keeps no in-flight position: a
        // pilot reloads at the stellar it last launched from (UI-01).
        pilot.shipPositionX = nil
        pilot.shipPositionY = nil
        pilot.shipHeading = nil
        if let ship = world?.player, let game { Munitions.record(ship, into: &pilot, game: game) }
        return PilotSaves.persist(archive: a, id: id, state: pilot, game: game, backup: backup)
    }

    // MARK: Interactions
    //
    // The in-flight dialogs (godot/screens/Interactions.gd): hailing a ship or a
    // stellar, boarding + the Plunder window, the Escort Commands panel and the
    // Escorts window. Every rule is shared code the Apple app calls too —
    // `FlightComm` (comm windows: OriginalComms / StellarComm / PaymentWindow /
    // PersEncounter), `FlightPlunder` (boarding, plunder odds, capture) and
    // `FlightEscorts` (EscortCommandPanel, release, roster) — this section only
    // resolves the target and marshals. Dialog state crosses as JSON; the sim is
    // paused by the frontend while one is up (as the Apple app pauses it).

    private var interact = InteractionState()

    private func interactionJSON(_ result: String, message: String? = nil, beep: Int = 0,
                                 extra: [String: Any] = [:]) -> String {
        var d = extra
        d["result"] = result
        d["message"] = message ?? ""
        d["beep"] = beep
        return Self.json(d)
    }

    /// The nearest stellar to the player — Godot has no planet selection, so it
    /// stands in for the Apple app's selected planet.
    private func nearestStellarID() -> Int? {
        guard let world else { return nil }
        let p = world.player.position
        return world.systemContext.bodies.min { ($0.position - p).length < ($1.position - p).length }?.id
    }

    /// Hail the locked ship — or, with `stellar` (Alt-Y) or no ship target, the
    /// nearest stellar. JSON `{result: nothing|refused|escorts|window, message,
    /// beep}`; `beep` is the interface beep (1…5) the original sounds.
    @Callable(autoSnakeCase: true) func hailOpen(stellar: Bool) -> String {
        guard let world, let game, dockedSpobID == nil, world.player.isAlive else {
            return interactionJSON("nothing")
        }
        let opening: FlightComm.Opening
        if !stellar, let tid = world.player.currentTargetID, let ship = world.ship(id: tid), ship.isAlive {
            opening = interact.comm.openShip(entityID: tid, world: world, game: game, pilot: &pilot)
        } else if let spobID = nearestStellarID() {
            opening = interact.comm.openPlanet(spobID: spobID, world: world, game: game, pilot: &pilot,
                                               systemID: currentSystemID ?? -1)
        } else {
            opening = .nothing
        }
        switch opening {
        case .nothing: return interactionJSON("nothing")
        case let .refused(message): return interactionJSON("refused", message: message, beep: 4)
        case .escortWindow: return interactionJSON("escorts", beep: 5)
        case .window: return interactionJSON("window", beep: 5)
        }
    }

    /// The open comm window as JSON, or `{}`: `{kind, id, typeId, pict, name,
    /// classLine, status, statusHostile, text, top, middle, middleVisible,
    /// middleEnabled, close, payment: null | {message, accept, lower, price}}`.
    /// `pict` is the ship portrait / `pêrs` HailPict PICT id (-1 = none; a
    /// stellar's portrait is its space sprite, kind 5).
    @Callable(autoSnakeCase: true) func hailState() -> String {
        guard let game, let h = interact.comm.hail else { return "{}" }
        var d: [String: Any] = [
            "name": h.name, "classLine": h.classLine, "status": h.statusText ?? "",
            "statusHostile": h.statusHostile, "text": h.responseText, "top": h.topTitle,
            "middle": h.middleTitle, "middleVisible": h.middleVisible, "middleEnabled": h.middleEnabled,
            "close": h.closeTitle, "pict": -1, "typeId": -1,
        ]
        switch h.kind {
        case let .ship(entityID, shipTypeID):
            d["kind"] = "ship"; d["id"] = entityID; d["typeId"] = shipTypeID
            if let custom = h.customPictID, game.hasPICT(custom) {
                d["pict"] = custom
            } else if let p = game.ship(shipTypeID).flatMap({ game.shipPictID(for: $0) }), game.hasPICT(p) {
                d["pict"] = p
            }
        case let .planet(spobID):
            d["kind"] = "planet"; d["id"] = spobID
        }
        if let p = h.payment {
            d["payment"] = ["message": p.message, "accept": p.acceptTitle, "lower": p.lowerTitle, "price": p.price] as [String: Any]
        }
        return Self.json(d)
    }

    /// Greetings / Offer Bribe.
    @Callable(autoSnakeCase: true) func hailPressTop() {
        guard let world, let game else { return }
        interact.comm.pressTop(world: world, game: game, pilot: &pilot)
    }

    /// Request Assistance / Beg For Mercy / Release, or Demand Tribute / Release.
    @Callable(autoSnakeCase: true) func hailPressMiddle() {
        guard let world, let game else { return }
        interact.comm.pressMiddle(world: world, game: game, pilot: &pilot, systemID: currentSystemID ?? -1)
    }

    /// The negotiation window: Accept Price (`accept`) or Lower Price.
    @Callable(autoSnakeCase: true) func hailPressPayment(accept: Bool) {
        guard let world, let game else { return }
        interact.comm.pressPayment(accept ? .pay : .haggle, world: world, game: game, pilot: &pilot,
                                   systemID: currentSystemID ?? -1)
    }

    @Callable(autoSnakeCase: true) func hailClose() { interact.comm.close(world: world) }

    @Callable(autoSnakeCase: true) func hailIsOpen() -> Bool { interact.comm.isOpen }

    /// Test seam (godot/tests/interactions_selfcheck.gd): hold ship `id` disabled,
    /// park it beside the player and give it `credits` aboard. Returns false for
    /// an unknown ship. Not used by the game.
    @Callable(autoSnakeCase: true) func debugMakeHulk(id: Int, credits: Int) -> Bool {
        guard let world, let ship = world.ship(id: id), ship !== world.player else { return false }
        ship.heldDisabled = true
        ship.plunderCredits = credits
        ship.position = world.player.position + Vec2(60, 0)
        ship.velocity = Vec2()
        return true
    }

    /// Board: JSON `{result: nothing|recovered|window, message, beep}`.
    @Callable(autoSnakeCase: true) func boardAttempt() -> String {
        guard let world, let game, dockedSpobID == nil else { return interactionJSON("nothing") }
        let r = interact.plunder.board(world: world, game: game, pilot: &pilot)
        collectEvents(from: world)   // the boarding crime / escort rejoin sounds
        interact.messages += interact.plunder.drainMessages()
        switch r {
        case .nothing: return interactionJSON("nothing", beep: 4)     // snd 153 (0x0045a3d0)
        case let .recovered(line): return interactionJSON("recovered", message: line)
        case .window: return interactionJSON("window")
        }
    }

    @Callable(autoSnakeCase: true) func plunderIsOpen() -> Bool { interact.plunder.isOpen }

    /// The Plunder window as JSON, or `{}`: `{name, cargo: [{name, tons}],
    /// cargoTons, credits, ammo, energy, capture (percent, -1 = can't)}`.
    @Callable(autoSnakeCase: true) func plunderState() -> String {
        guard let world, let game, let galaxy,
              let v = interact.plunder.view(world: world, game: game, pilot: pilot, galaxy: galaxy) else { return "{}" }
        return Self.json([
            "name": v.name, "cargo": v.cargo.map { ["name": $0.name, "tons": $0.tons] as [String: Any] },
            "cargoTons": v.cargoTons, "credits": v.credits, "ammo": v.ammo, "energy": v.energy,
            "capture": v.captureChance ?? -1,
        ] as [String: Any])
    }

    /// A loot button (0 Energy · 1 Cargo · 2 Credits · 3 Ammo · 4 Capture Ship):
    /// JSON `{messages, closed, refused, choice}`; `choice` is true when a
    /// capture succeeded and `capture_resolve` must answer the question.
    @Callable(autoSnakeCase: true) func plunderPress(action: Int) -> String {
        guard let world, let game, let galaxy, let act = FlightPlunder.Action(rawValue: action) else { return "{}" }
        let r = interact.plunder.press(act, world: world, game: game, galaxy: galaxy, pilot: &pilot)
        if let c = r.choice { interact.captureChoice = c }
        collectEvents(from: world)
        return Self.json(["messages": r.messages, "closed": r.closed, "refused": r.refused,
                          "choice": r.choice != nil] as [String: Any])
    }

    /// Abort: leave the hulk adrift (snd 152 is the caller's).
    @Callable(autoSnakeCase: true) func plunderAbort() { interact.plunder.abort(world: world) }

    /// The pending "Ship captured!" question (DLOG 1018) or `{}`: `{name,
    /// shipType, message (STR# 2002 #118), prompt (#119), cancelled (#122),
    /// defaultName, canEscort}`. Use as Escort is only offered under the wing cap.
    @Callable(autoSnakeCase: true) func captureQuestion() -> String {
        guard let world, let game, let c = interact.captureChoice else { return "{}" }
        if interact.captureName == nil {
            interact.captureName = String(world.capturedShipDefaultName(shipTypeID: c.shipTypeID).prefix(63))
        }
        let s = game.stringList(2002)
        return Self.json([
            "name": c.name, "shipType": c.shipTypeID,
            "message": s?.string(at: 118) ?? "Do you want to use this ship as an escort, or would you rather trade places with its captain and use it as your own ship?",
            "prompt": s?.string(at: 119) ?? "Name your new ship.",
            "cancelled": s?.string(at: 122) ?? "Cancelled.",
            "defaultName": interact.captureName ?? "", "canEscort": PilotEconomy.canAddEscort(pilot),
        ] as [String: Any])
    }

    /// Answer it: Use as Escort, or Take Command under `name` (the captured hull
    /// becomes the flagship and the flight world is rebuilt around it). Returns
    /// the lines for the status line.
    @Callable(autoSnakeCase: true) func captureResolve(takeCommand: Bool, name: String) -> PackedStringArray {
        guard let world, let game, let choice = interact.captureChoice else { return PackedStringArray() }
        interact.captureChoice = nil
        interact.captureName = nil
        let lines: [String]
        if takeCommand {
            pilot.cargo = world.player.cargo
            lines = FlightPlunder.takeCommand(choice, name: name.isEmpty ? nil : name, world: world, game: game,
                                              pilot: &pilot)
            rebuildAfterShipSwap()
        } else {
            lines = FlightPlunder.useAsEscort(choice, world: world, game: game, pilot: &pilot)
        }
        return PackedStringArray(lines)
    }

    /// The name prompt was cancelled: the choice is dropped (the hulk stays adrift).
    @Callable(autoSnakeCase: true) func captureCancel() {
        interact.captureChoice = nil
        interact.captureName = nil
    }

    /// Take command: the pilot's hull changed — rebuild the flight world around
    /// the new ship where the old one was (the Apple app's `rebuildFlightHost`).
    private func rebuildAfterShipSwap() {
        guard let old = world?.player, let game, let galaxy, let sysID = currentSystemID else { return }
        let ship = galaxy.makeLoadedShip(pilot.shipType, extraOutfits: pilot.outfits, at: old.position,
                                         includeDefaultItems: false, includeHullWeapons: false) ?? old
        ship.cargo = pilot.cargo
        ship.fuel = pilot.fuel.map { min($0, ship.maxFuel) } ?? ship.maxFuel
        let (w, _) = GameSession.makeWorld(game: game, systemID: sysID, player: ship, galaxy: galaxy)
        ship.position = old.position
        ship.velocity = old.velocity
        ship.angle = old.angle
        self.world = w
        resetFrameState()
    }

    // Escorts. The panel's keys keep the original's table (E, 1–5, then F attack ·
    // D defend · V hold · C formation · Alt-C return to hangar); the codes are
    // `OriginalEscortCommand`: 0 formation · 1 defend · 2 attack · 3 return · 4 hold.

    /// E: JSON `{result: opened|closed|none, message}` (`beep` 1 / 1 / 4).
    @Callable(autoSnakeCase: true) func escortPressE() -> String {
        guard let world, let game else { return interactionJSON("none") }
        switch interact.escorts.pressE(world: world, game: game) {
        case .opened: return interactionJSON("opened", beep: 1)
        case .closed: return interactionJSON("closed", beep: 1)
        case let .noEscorts(line): return interactionJSON("none", message: line, beep: 4)
        }
    }

    @Callable(autoSnakeCase: true) func escortPanelOpen() -> Bool { interact.escorts.panel.isOpen }

    /// A group key while the panel is up (0 = key 1 … 4 = key 5): true when the
    /// key was consumed; `picked` sounds snd 152 (returned as 3, else 0).
    @Callable(autoSnakeCase: true) func escortGroupKey(k: Int) -> Int {
        guard let world else { return -1 }
        let r = interact.escorts.pressGroupKey(k, world: world)
        return r.consumed ? (r.picked ? 3 : 0) : -1
    }

    /// F / D / V / C / Alt-C. Returns the "New escort orders assigned" readout, if any.
    @Callable(autoSnakeCase: true) func escortOrder(code: Int) -> String {
        guard let world else { return "" }
        return interact.escorts.order(code, world: world) ?? ""
    }

    /// The Escort Commands panel: `{title, level, rows: [{label, order, enabled,
    /// selected}]}` or `{}` while it is hidden.
    @Callable(autoSnakeCase: true) func escortPanelState() -> String {
        guard let world, let game, let d = interact.escorts.display(world: world, game: game) else { return "{}" }
        return Self.json(["title": d.title, "level": d.level,
                          "rows": d.rows.map { ["label": $0.label, "order": $0.order,
                                                "enabled": $0.enabled, "selected": $0.selected] as [String: Any] }] as [String: Any])
    }

    /// The Escorts window (hailing your own escort): `[{entity, record, name,
    /// shield, armor, fighter, disabled, origin, canRelease}]`.
    @Callable(autoSnakeCase: true) func escortRoster() -> String {
        guard let world else { return "[]" }
        return Self.json(interact.escorts.members(world: world, pilot: pilot).map { m in
            ["entity": m.entityID, "record": m.recordID ?? -1, "name": m.name, "shield": m.shieldFraction,
             "armor": m.armorFraction, "fighter": m.isFighter, "disabled": m.disabled,
             "origin": m.originLabel, "canRelease": m.canRelease] as [String: Any]
        })
    }

    /// The Escorts window's labels: `{title, groups[5], orders{code: label}}`.
    @Callable(autoSnakeCase: true) func escortLabels() -> String {
        guard let game else { return "{}" }
        let l = FlightEscorts.windowLabels(game: game)
        return Self.json(["title": l.title, "groups": l.groups,
                          "orders": Dictionary(uniqueKeysWithValues: l.orders.map { (String($0.key), $0.value) })] as [String: Any])
    }

    /// An order from the Escorts window to one group (`category` -1 = all, else
    /// EscortType 0…3). Returns the "New escort orders assigned" readout, if any.
    @Callable(autoSnakeCase: true) func escortOrderGroup(category: Int, code: Int) -> String {
        guard let world else { return "" }
        return interact.escorts.orderGroup(category: category < 0 ? nil : category, command: code, world: world) ?? ""
    }

    /// Release the escort with roster `record` (0x004853a0).
    @Callable(autoSnakeCase: true) func escortRelease(record: Int) {
        guard let world, let game else { return }
        FlightEscorts.release(recordID: record, world: world, game: game, pilot: &pilot)
    }

    /// Lines for the status line raised by the above and by world events
    /// (a stellar submitting, an escort lost, a bribe's clearance).
    @Callable(autoSnakeCase: true) func drainInteractionMessages() -> PackedStringArray {
        let lines = interact.messages + interact.comm.drainMessages()
        interact.messages.removeAll()
        return PackedStringArray(lines)
    }

    /// Per frame: the Escort Commands panel's hold/fade clock and the roster map.
    private func tickInteractions(dt: Double) {
        guard let world else { return }
        interact.escorts.tick(dt: dt, world: world)
        interact.escorts.track(world: world)
    }

    /// A world event that persists into the pilot (tribute, a destroyed stellar,
    /// a lost escort).
    private func interactionsNote(_ event: WorldEvent) {
        guard let world, let game else { return }
        if let line = interact.comm.apply(event: event, game: game, pilot: &pilot,
                                          systemID: currentSystemID ?? -1, world: world) {
            interact.messages.append(line)
        }
        if let line = interact.escorts.note(event: event, pilot: &pilot) { interact.messages.append(line) }
    }

    /// A world was (re)built: close the windows and bring the saved escort wing
    /// back around the player.
    private func interactionsWorldRebuilt() {
        interact.resetForNewWorld(system: currentSystemID)
        if let world, game != nil { FlightEscorts.respawnRoster(world: world, pilot: pilot) }
    }

    // MARK: Story & missions
    //
    // Missions, crons and story text in the Godot build. Every rule is shared
    // code the Apple app calls too — `StoryEngine` (offers, lanes, accept /
    // decline, the landing / launch / flight passes, crons on `advanceDays`),
    // `FlightMissions` (mission ships in the world), `PlayerInfoPages`,
    // `SpaceportStory` — and `GodotGameServices` (Story.swift) is this build's
    // `AppGameServices`. This section only builds engines over the live pilot,
    // wires the world hooks, and marshals; texts / offers / pages cross as JSON.
    // GDScript side: godot/screens/StoryScreens.gd (modal texts and offers,
    // Player Info) and the Bar / Mission BBS screens in Spaceport.gd.

    private var storyState = StoryState()

    private func storyBindHooks() {
        guard !storyState.hooksBound else { return }
        storyState.hooksBound = true
        let s = storyState.services
        s.isLanded = { [weak self] in self?.dockedSpobID != nil }
        s.stellarName = { [weak self] id in self?.game?.spob(id)?.name ?? "A stellar object" }
        s.onPlaySound = { [weak self] id in
            self?.sound.pending.append(SoundCue(soundID: id, priority: OriginalAudio.Priority.beep))
        }
        s.onSpawnShips = { [weak self] in self?.storyState.spawnRequested = true }
        s.onChangeShip = { [weak self] _, _ in
            // Landed, the takeoff rebuild flies the new hull; in flight it is applied
            // between ticks (`storyApplyDeferred`).
            if self?.dockedSpobID == nil { self?.storyState.deferred.swapShip = true }
        }
        s.onMovePlayer = { [weak self] systemID, _ in
            guard let self else { return }
            self.currentSystemID = systemID
            if self.dockedSpobID == nil { self.storyState.deferred.moveToSystem = systemID }
        }
        s.onStellarDestroyed = { [weak self] id, destroyed in
            guard let self else { return }
            let name = self.game?.spob(id)?.name ?? "A stellar object"
            self.storyState.services.messages.append(destroyed ? "\(name) has been destroyed." : "\(name) has been restored.")
        }
        s.onReleaseShips = { [weak self] id in
            guard let self, let world = self.world, let galaxy = self.galaxy else { return }
            if self.dockedSpobID != nil {
                _ = world.despawnMissionShips(missionID: id)
            } else {
                _ = world.releaseMissionShips(missionID: id) { type in
                    AIType(raw: galaxy.game.ship(type)?.inherentAI ?? 0)
                }
            }
        }
        // An unpaid escort defects (EC-20): its ship leaves the system.
        s.onEscortDeparted = { [weak self] recordID in
            guard let world = self?.world else { return }
            for ship in world.playerEscorts where ship.escortRecordID == recordID {
                ship.brain?.leaderID = nil
                world.removeShip(entityID: ship.entityID)
            }
        }
        // The mission-failed notices sound snd 151 (#284, lost ship) / 153 (#285,
        // time limit); a `Q` message is the deferred line sounded with snd 154.
        s.onOverlay = { [weak self] text in
            guard let self else { return }
            let list = self.game?.stringList(2002)
            let beep = text == list?.string(at: 0x11c) ? 2 : (text == list?.string(at: 0x11d) ? 4 : 5)
            if let cue = SoundCues.beep(beep) { self.sound.pending.append(cue) }
            self.storyState.services.messages.append(text)
        }
    }

    /// A story engine over the live pilot, wired to the Godot services. Seeded per
    /// landing while docked (stable within a visit, as the Apple spaceport does).
    private func storyEngine() -> StoryEngine? {
        guard let game else { return nil }
        storyBindHooks()
        let seed = dockedSpobID.map { StoryEngine.landingSeed(player: pilot, spobID: $0) } ?? 0xE7CA11
        return StoryEngine(game: game, player: pilot, services: storyState.services, seed: seed)
    }

    /// Adopt the engine's pilot, then do what the engine asked of the world.
    private func storyCommit(_ engine: StoryEngine) {
        pilot = engine.player
        if storyState.spawnRequested {
            storyState.spawnRequested = false
            storySpawnShips()
        }
    }

    /// Drop active missions' ships into the live system (a no-op while docked:
    /// the takeoff rebuild does it).
    private func storySpawnShips() {
        guard dockedSpobID == nil, let host = storyState.host, let engine = storyEngine() else { return }
        if FlightMissions.spawnActiveShips(engine: engine, host: host,
                                           currentSystem: currentSystemID ?? pilot.currentSystem) {
            pilot = engine.player
        }
    }

    /// A world was (re)built (`resetFrameState`): re-attach the mission-ship host
    /// and populate it from the active missions.
    private func storyWorldRebuilt() {
        guard game != nil, let world else { return }
        storyState.host = WorldMissionShipHost(world: world, viewHalfExtent: storyState.viewHalfExtent)
        storyState.sightingClock = 0
        storyState.spawnRequested = false
        storySpawnShips()
    }

    /// Live auxiliary ships go back to their missions' budgets as the player
    /// leaves the system (0x0041ad50).
    private func storyLeavingSystem() {
        guard let game, let world else { return }
        FlightMissions.creditSurvivingAuxShips(world.collectSurvivingAuxiliaryShips(), state: &pilot, game: game)
    }

    /// A world event the story cares about, from `collectEvents`: a mission
    /// ship's goal / loss / aux arrival, and the player-state mission failures
    /// (`Flags2` 0x0004 disabled or destroyed, `Flags` 0x8000 boarded).
    private func storyNote(_ event: WorldEvent) {
        guard game != nil else { return }
        switch event {
        case let .missionShipGoalReached(missionID, _, goal, _):
            guard let engine = storyEngine() else { return }
            FlightMissions.shipGoalReached(engine: engine, missionID: missionID, goal: goal)
            storyCommit(engine)
            // Mission boarding can add cargo in flight: keep the hold in step.
            world?.player.cargo = pilot.cargo
            autosave(.event)
        case let .missionShipLost(missionID, goal):
            guard let engine = storyEngine() else { return }
            FlightMissions.shipLost(engine: engine, missionID: missionID, goal: goal)
            storyCommit(engine)
            autosave(.event)
        case let .missionAuxShipsArrived(missionID, count):
            guard let m = game?.mission(missionID), !m.infiniteAuxShips,
                  let i = pilot.activeMissions.firstIndex(where: { $0.missionID == missionID }) else { return }
            let left = pilot.activeMissions[i].auxShipsRemaining ?? m.auxShipCount
            pilot.activeMissions[i].auxShipsRemaining = max(0, left - count)
        case let .shipDisabled(entityID, _) where entityID == World.playerEntityID:
            storyFailActive("Your ship was disabled — mission failed.") { $0.failIfPlayerDisabled }
        case .playerDying:
            storyFailActive("Your ship was destroyed — mission failed.") { $0.failIfPlayerDisabled }
        case let .shipBoarded(entityID, _) where entityID == World.playerEntityID:
            storyFailActive("You were boarded — mission failed.") { $0.flags1 & 0x8000 != 0 }
        default:
            break
        }
    }

    private func storyFailActive(_ reason: String, where predicate: (MissionRes) -> Bool) {
        guard let engine = storyEngine(), FlightMissions.failActive(engine: engine, where: predicate) else { return }
        storyCommit(engine)
        storyState.services.messages.append(reason)
        if let cue = SoundCues.beep(2) { sound.pending.append(cue) }   // snd 151
        autosave(.event)
    }

    /// Per-frame story work, after the tick loop: the escort / observe sighting
    /// pass (every 3 s of flight, as the Apple heartbeat) and any world edit the
    /// story queued mid-tick.
    private func tickStory(dt: Double) {
        guard let game, let world else { return }
        storyState.sightingClock += dt
        if storyState.sightingClock >= 3 {
            storyState.sightingClock = 0
            if dockedSpobID == nil, world.player.isAlive, let host = storyState.host,
               !pilot.activeMissions.isEmpty {
                host.viewHalfExtent = storyState.viewHalfExtent
                let due = FlightMissions.dueSightings(state: pilot, game: game, host: host)
                if !due.isEmpty, let engine = storyEngine() {
                    for id in due { engine.missionShipsSighted(missionID: id) }
                    storyCommit(engine)
                }
            }
        }
        storyApplyDeferred()
    }

    /// The world edits the story asked for mid-tick: a hull swap rebuilds the
    /// flight world in place keeping the hull's damage and position (the Apple
    /// `rebuildFlightHost`), a move rebuilds at the new system.
    private func storyApplyDeferred() {
        let ops = storyState.deferred
        storyState.deferred = StoryWorldOps()
        guard dockedSpobID == nil, let world, let game, let galaxy, let sysID = currentSystemID else { return }
        if let target = ops.moveToSystem {
            let ship = world.player
            let (w, _) = GameSession.makeWorld(game: game, systemID: target, player: ship, galaxy: galaxy)
            ship.currentTargetID = nil
            self.world = w
            self.intent = ControlIntent()
            currentSystemID = target
            pilot.currentSystem = target
            pilot.exploredSystems.insert(target)
            refreshNavVisibility()
            resetFrameState()
        } else if ops.swapShip {
            let old = world.player
            guard let player = galaxy.makeLoadedShip(pilot.shipType, extraOutfits: pilot.outfits, at: old.position,
                                                      includeDefaultItems: false, includeHullWeapons: false)
            else { return }
            player.angle = old.angle
            player.velocity = old.velocity
            player.cargo = pilot.cargo
            player.fuel = pilot.fuel.map { min($0, player.maxFuel) } ?? player.maxFuel
            // The swap keeps the hull's damage; a disabled hull is then repaired
            // one armor point at a time until it no longer reads disabled (MS-18).
            player.armor = min(old.armor, player.maxArmor)
            player.shield = min(old.shield, player.maxShield)
            while player.disabled, player.armor < player.maxArmor { player.armor += 1 }
            let (w, _) = GameSession.makeWorld(game: game, systemID: sysID, player: player, galaxy: galaxy)
            player.position = old.position
            player.currentTargetID = nil
            self.world = w
            self.intent = ControlIntent()
            resetFrameState()
        }
    }

    // --- texts and offers ---

    /// A story text is waiting (a briefing, completion text, refusal, …).
    @Callable(autoSnakeCase: true) func storyTextPending() -> Bool { !storyState.services.texts.isEmpty }

    /// The head text as JSON `{title, text, pict}` (`pict` = the `dësc`'s PICT id or -1).
    @Callable(autoSnakeCase: true) func storyTextInfo() -> String {
        guard let t = storyState.services.texts.first else { return "{}" }
        let pict = t.descID.flatMap { game?.desc($0)?.pictureID }.flatMap { game?.hasPICT($0) == true ? $0 : nil } ?? -1
        return Self.json(["title": t.title, "text": t.text, "pict": pict] as [String: Any])
    }

    /// OK on the head text.
    @Callable(autoSnakeCase: true) func storyTextDismiss() {
        if !storyState.services.texts.isEmpty { storyState.services.texts.removeFirst() }
    }

    /// Anything modal is up (a text, or an offer drawn as its own dialog): the
    /// frontend pauses the sim while this is true.
    @Callable(autoSnakeCase: true) func storyBlocksFlight() -> Bool {
        !storyState.services.texts.isEmpty || offerModalPending()
    }

    private func offerModalPending() -> Bool {
        storyState.services.pendingOffer != nil && !storyState.inlineOffer
    }

    /// An offer wants its own dialog (landing / shop / bar / in-flight offers; not
    /// the one the Mission BBS pane is showing).
    @Callable(autoSnakeCase: true) func offerPending() -> Bool { offerModalPending() }

    /// The pending offer as JSON `{id, title, text, pict, accept, refuse, canRefuse,
    /// canAccept, destination}` or `{}`.
    @Callable(autoSnakeCase: true) func offerState() -> String {
        guard let o = storyState.services.pendingOffer else { return "{}" }
        var dest = ""
        if let engine = storyEngine(), let d = engine.offerDestination(for: o.mission) {
            dest = "\(d.stellar), \(d.system)"
        }
        let pict = o.pictureID.flatMap { game?.hasPICT($0) == true ? $0 : nil } ?? -1
        return Self.json(["id": o.mission.id, "title": o.title, "text": o.briefingText, "pict": pict,
                          "accept": o.acceptButton, "refuse": o.refuseButton, "canRefuse": o.canRefuse,
                          "canAccept": o.canAccept, "destination": dest] as [String: Any])
    }

    /// Accept the pending offer (lane / bar / in-flight offers close either way).
    @discardableResult
    @Callable(autoSnakeCase: true) func offerAccept() -> Bool {
        guard let offer = storyState.services.pendingOffer, let engine = storyEngine() else { return false }
        let ok = engine.accept(offer.mission.id)
        storyCommit(engine)
        autosave(.event)
        storyState.services.pendingOffer = nil
        storyState.inlineOffer = false
        return ok
    }

    @Callable(autoSnakeCase: true) func offerDecline() {
        guard let offer = storyState.services.pendingOffer, let engine = storyEngine() else { return }
        engine.decline(offer.mission.id)
        storyCommit(engine)
        autosave(.event)
        storyState.services.pendingOffer = nil
        storyState.inlineOffer = false
    }

    /// Offer the next mission in a location's lane (0x00448670): `where` is
    /// "spaceport" (once on landing), "trade", "shipyard", "outfitter" or "bar".
    /// 0 = nothing to offer, 1 = an offer window is up, 2 = a can't-refuse offer
    /// with no text activated silently.
    @Callable(autoSnakeCase: true) func offerRoll(at: String) -> Int {
        guard storyState.services.pendingOffer == nil, let spobID = dockedSpobID, let engine = storyEngine() else { return 0 }
        let location: MissionOfferLocation
        switch at {
        case "spaceport": location = .mainSpaceport
        case "trade": location = .tradeCenter
        case "shipyard": location = .shipyard
        case "outfitter": location = .outfitter
        case "bar": location = .bar
        default: return 0
        }
        let mission = engine.nextLaneOffer(at: location, spob: spobID)
        pilot = engine.player                        // the offer context latch
        guard let mission else { return 0 }
        storyState.inlineOffer = false
        if !engine.present(mission) {
            storyCommit(engine)
            autosave(.event)
            return 2
        }
        return 1
    }

    /// Leaving a shop resets the lane-offer context (0x00448660).
    @Callable(autoSnakeCase: true) func offerClearContext() {
        guard let engine = storyEngine() else { return }
        engine.clearLaneOfferContext()
        pilot = engine.player
    }

    // --- Mission BBS ---

    /// The Mission BBS button (0x0043c470): JSON `{open, text, date}` — when it can't
    /// open, `text` (maybe empty) says why; with `announce` it is also queued as a
    /// story text (the button press does, the silent re-open after an accept doesn't).
    @Callable(autoSnakeCase: true) func bbsOpen(announce: Bool) -> String {
        guard let engine = storyEngine(), let spobID = dockedSpobID else { return Self.json(["open": false, "text": ""] as [String: Any]) }
        let refusal = engine.missionBBSRefusal(spob: spobID)
        pilot = engine.player
        storyState.services.pendingOffer = nil
        storyState.inlineOffer = false
        // Why it won't open is a text dialog of its own (an empty reason shows none).
        if announce, let refusal, !refusal.isEmpty { storyState.services.showStoryText(refusal, title: "") }
        return Self.json(["open": refusal == nil, "text": refusal ?? "", "date": game.map { OriginalText(game: $0).date(for: pilot) } ?? ""] as [String: Any])
    }

    /// The board's listings `[{id, name}]`, highest weight first.
    @Callable(autoSnakeCase: true) func bbsList() -> String {
        guard let engine = storyEngine(), let spobID = dockedSpobID else { return "[]" }
        let rows = engine.missionComputerList(spob: spobID).map { ["id": $0.id, "name": engine.resolvedName(for: $0)] as [String: Any] }
        pilot = engine.player
        return Self.json(rows)
    }

    /// Show a listed mission in the pane. 1 = shown, 2 = it activated at once
    /// (a can't-refuse offer with no text counts as an accept).
    @Callable(autoSnakeCase: true) func bbsSelect(id: Int) -> Int {
        guard let engine = storyEngine(), let m = game?.mission(id) else { return 0 }
        storyState.inlineOffer = true
        if !engine.present(m) {
            storyCommit(engine)
            autosave(.event)
            storyState.services.pendingOffer = nil
            storyState.inlineOffer = false
            return 2
        }
        return 1
    }

    /// Accept the listing in the pane. A failed activation keeps the board open
    /// (its no-room text shows over it); returns whether it activated.
    @discardableResult
    @Callable(autoSnakeCase: true) func bbsAccept() -> Bool {
        guard let offer = storyState.services.pendingOffer, let engine = storyEngine() else { return false }
        let ok = engine.accept(offer.mission.id)
        storyCommit(engine)
        autosave(.event)
        if ok { storyState.services.pendingOffer = nil; storyState.inlineOffer = false }
        return ok
    }

    /// Leaving the board.
    @Callable(autoSnakeCase: true) func bbsClose() {
        storyState.services.pendingOffer = nil
        storyState.inlineOffer = false
        if let engine = storyEngine() { engine.clearLaneOfferContext(); pilot = engine.player }
    }

    // --- Bar and Holovid ---

    /// `{text, pict, canHire}` for the Bar screen (`dësc` spöb + 9872).
    @Callable(autoSnakeCase: true) func barInfo() -> String {
        guard let game, let spob = dockedSpob else { return "{}" }
        let pict = SpaceportStory.barPictureID(game: game, spob: spob).flatMap { game.hasPICT($0) ? $0 : nil } ?? -1
        return Self.json(["text": SpaceportStory.barText(game: game, spob: spob), "pict": pict,
                          "gamble": buttonLabel(11, "Gamble"), "holovid": buttonLabel(12, "Holovid"),
                          "leave": buttonLabel(1, "Leave")] as [String: Any])
    }

    /// `{pict, text}` for the Holovid news (read on demand, never forced on landing).
    @Callable(autoSnakeCase: true) func holovidInfo() -> String {
        guard let game, let spob = dockedSpob else { return "{}" }
        let h = SpaceportStory.holovid(game: game, player: pilot, spob: spob)
        return Self.json(["pict": game.hasPICT(h.pict) ? h.pict : -1, "text": h.text] as [String: Any])
    }

    /// Labels the story screens use (STR# 150): Mission BBS, Accept, Abort, Done,
    /// and the Player Info tabs.
    @Callable(autoSnakeCase: true) func storyLabels() -> String {
        Self.json(["missionBBS": buttonLabel(16, "Mission BBS"), "accept": buttonLabel(26, "Accept"),
                   "abort": buttonLabel(35, "Abort"), "done": buttonLabel(5, "Done"), "leave": buttonLabel(1, "Leave"),
                   "general": buttonLabel(36, "General"), "cargo": buttonLabel(37, "Cargo"),
                   "extras": buttonLabel(38, "Extras"), "honors": buttonLabel(39, "Honors"),
                   "jettison": buttonLabel(61, "Jettison Cargo")] as [String: String])
    }

    // --- Player Info and Mission Info ---

    /// The Player Info window (UI-13): `{general:{left,right,economy}, cargo,
    /// extras, honors, canJettison, date}` — rows are `[label, value]`. The stat
    /// grid reads the live ship when flying.
    @Callable(autoSnakeCase: true) func playerInfo() -> String {
        guard let game, let galaxy else { return "{}" }
        let pages = PlayerInfoPages(game: game, player: pilot)
        var figures: PlayerInfoPages.ShipFigures?
        if dockedSpobID == nil, let world, world.player.isAlive {
            let p = world.player
            let ticks = OriginalClock.ticksPerSecond
            figures = PlayerInfoPages.ShipFigures(
                turnDegPerTick: p.stats.playerTurnDegPerTick,
                thrustPerTick2: p.stats.acceleration / (ticks * ticks),
                maxSpeedPerTick: world.effectiveMaxSpeed(of: p) / ticks,
                shield: p.shield, maxShield: p.maxShield, armor: p.armor, maxArmor: p.maxArmor,
                destroyed: !p.isAlive, fuel: p.fuel)
        }
        func rows(_ r: [PlayerInfoPages.Row]) -> [[String]] { r.map { [$0.label, $0.value] } }
        return Self.json([
            "general": ["left": rows(pages.leftColumn(figures)), "right": rows(pages.rightColumn(figures)),
                        "economy": pages.dailyEconomy()] as [String: Any],
            "cargo": pages.cargo(shipCapacity: PilotEconomy.shipCargoCapacity(pilot, galaxy: galaxy),
                                 fleetCapacity: PilotEconomy.cargoCapacity(pilot, galaxy: galaxy)),
            "extras": pages.extras(tradeInValue: PilotEconomy.tradeInValue(pilot, game: game)),
            "honors": pages.honors(), "canJettison": pages.canJettison,
            "date": OriginalText(game: game).date(for: pilot),
        ] as [String: Any])
    }

    /// Player Info's Jettison Cargo (0x0041f330 with jettison-all, UI-13): the
    /// hold and every abortable mission's cargo go overboard. Returns the line to
    /// show ("Cargo jettisoned.", STR# 2002 #289) or "". The floating pods the
    /// Apple scene spawns are not drawn here.
    @Callable(autoSnakeCase: true) func jettisonCargo() -> String {
        guard let game, let engine = storyEngine() else { return "" }
        let docked = dockedSpobID != nil
        let thrown = engine.jettisonCargo(docked: docked)
        storyCommit(engine)
        world?.player.cargo = pilot.cargo
        autosave(.event)
        guard !docked, thrown.total > 0, !thrown.missionFailedShown else { return "" }
        return game.stringList(2002)?.string(at: 289) ?? ""
    }

    /// The Mission Info list (`activeMissionSummaries`, slot order): `[{id, name,
    /// brief, objective, destination, destinationId, system, systemId, canAbort,
    /// failed}]`.
    @Callable(autoSnakeCase: true) func missionList() -> String {
        guard let engine = storyEngine() else { return "[]" }
        let rows = engine.activeMissionSummaries().map { m -> [String: Any] in
            ["id": m.id, "name": m.name, "brief": m.payload, "objective": m.objective,
             "destination": m.destinationSpob, "system": m.destinationSystem,
             "destinationId": m.destinationSpobID ?? -1, "systemId": m.destinationSystemID ?? -1,
             "canAbort": m.canAbort, "failed": m.failed]
        }
        return Self.json(rows)
    }

    /// Abort Mission. False if the mission forbids it or isn't active.
    @discardableResult
    @Callable(autoSnakeCase: true) func missionAbort(id: Int) -> Bool {
        guard let m = game?.mission(id), m.canAbort, pilot.activeMission(id) != nil, let engine = storyEngine() else { return false }
        engine.abortMission(id)
        storyCommit(engine)
        autosave(.event)
        return true
    }

    // --- drains and flags ---

    /// Status-line lines the story raised (overlay messages, notices), drained.
    @Callable(autoSnakeCase: true) func drainStoryMessages() -> PackedStringArray {
        defer { storyState.services.messages.removeAll() }
        return PackedStringArray(storyState.services.messages)
    }

    /// A `Q` fired while landed: close whichever spaceport screen is open (once).
    @Callable(autoSnakeCase: true) func takeCloseSpaceportScreen() -> Bool {
        defer { storyState.services.closeScreenRequested = false }
        return storyState.services.closeScreenRequested
    }

    /// A `Q` fired while landed threw the pilot back into space: launch (once).
    @Callable(autoSnakeCase: true) func takeForcedLaunch() -> Bool {
        defer { storyState.services.forcedLaunch = false }
        return storyState.services.forcedLaunch
    }

    /// Half the visible play area in world units, for the observe goal.
    @Callable(autoSnakeCase: true) func setStoryViewSize(width: Double, height: Double) {
        storyState.viewHalfExtent = Vec2(width / 2, height / 2)
        storyState.host?.viewHalfExtent = storyState.viewHalfExtent
    }

    /// The pilot's galaxy date as the original prints it (header of the BBS etc.).
    @Callable(autoSnakeCase: true) func pilotDateText() -> String {
        game.map { OriginalText(game: $0).date(for: pilot) } ?? ""
    }

    /// The pilot's galaxy day number (for tests: cron / day-advance checks).
    @Callable(autoSnakeCase: true) func pilotDayNumber() -> Int { pilot.date.julianDay }

    /// Test aid (like `debugMakeHulk`): set the player down on stellar `spobID`'s
    /// pad at rest so `attempt_land` works headlessly.
    @Callable(autoSnakeCase: true) func debugPlacePlayerAtSpob(spobID: Int) -> Bool {
        guard let world, let body = world.systemContext.bodies.first(where: { $0.id == spobID }) else { return false }
        world.player.position = body.position
        world.player.velocity = Vec2()
        return true
    }

    // MARK: Audio
    //
    // Sound for the frontend, in three parts. (1) Decoded PCM per `snd ` id
    // (`NovaSwiftKit`'s SndDecoder → 16-bit mono, native rate; GDScript wraps it
    // in an AudioStreamWAV once per id, like `sprite_rgba`). (2) Cues: the shared
    // `SoundCues` table maps each `WorldEvent` (collected in `collectEvents`,
    // separately from `drain_events`/`drain_effects`, which Main.gd consumes) and
    // the non-event sites (docking, the jump cue, red alert, klaxxon) to a `snd `
    // + priority + position + stack guard. (3) The shared `SoundVoiceBoard` is the
    // original's 16-voice list; `drain_sound_cues` runs the pending cues through it
    // and returns what the frontend's 16 players must do. No mixing rule lives in
    // GDScript.

    /// `[sampleRate, channels, bitsPerSample, frames]` for `snd ` `id`, or empty
    /// if the data has no such sound or it can't be decoded.
    @Callable(autoSnakeCase: true) func soundInfo(id: Int) -> PackedInt32Array {
        guard let s = game?.sound(id), !s.samples.isEmpty else { return PackedInt32Array() }
        return PackedInt32Array([Int32(s.sampleRate.rounded()), 1, 16, Int32(s.frameCount)])
    }

    /// The sound as signed 16-bit little-endian mono PCM (`frames * 2` bytes), or
    /// empty. Call once per id and cache the stream.
    @Callable(autoSnakeCase: true) func soundPcm(id: Int) -> PackedByteArray {
        guard let s = game?.sound(id), !s.samples.isEmpty else { return PackedByteArray() }
        return PackedByteArray(s.pcm16LE())
    }

    /// Every `snd ` id the loaded data (and plug-ins) provide.
    @Callable(autoSnakeCase: true) func soundIds() -> PackedInt32Array {
        PackedInt32Array((game?.soundIDs() ?? []).map { Int32($0) })
    }

    /// Queue interface beep `n` (1…5 = snd 150…154, priority 1). The caller keeps
    /// the original's call-site table (which key sounds which beep).
    @Callable(autoSnakeCase: true) func soundBeep(n: Int) {
        if let cue = SoundCues.beep(n) { sound.pending.append(cue) }
    }

    /// Stop every voice playing `snd ` `id` (0 = all), e.g. when leaving the game.
    @Callable(autoSnakeCase: true) func soundStop(id: Int) { sound.board.stop(soundID: id) }

    /// Floats per `drain_sound_cues()` row and the number of voice players the
    /// frontend must own (the original's 16 virtual voices).
    @Callable(autoSnakeCase: true) func soundStride() -> Int { 6 }
    @Callable(autoSnakeCase: true) func soundVoiceCount() -> Int { OriginalAudio.slotCount }

    /// Run the pending cues through the voice list and return the player
    /// commands, packed 6 floats per row: `[node, soundID, gain, action, rate,
    /// interface]`. `node` is a player index 0..<`sound_voice_count()`; `action`
    /// 1 = start that sound on the node (replacing whatever it held), 0 = just
    /// re-level it, 2 = stop it; `gain` is 0…1 (0 for a voice past the 8 heard);
    /// `rate` the playback speed (the Warp up cue); `interface` 1 = also scale by
    /// the interface-volume slider. Positions are heard from the player, mono and
    /// unpanned, with the original's 200 px / 850²/d² law (`OriginalAudio`).
    /// Call once per frame; it is empty when nothing changed.
    @Callable(autoSnakeCase: true) func drainSoundCues() -> PackedFloat32Array {
        let now = ProcessInfo.processInfo.systemUptime
        let listener = world?.player.position ?? Vec2()
        let cues = sound.pending
        sound.pending.removeAll(keepingCapacity: true)
        for cue in cues {
            let length = soundLength(cue.soundID)
            let played = length > 0
                && sound.board.play(cue, listener: listener, duration: length, now: now)
            if cue.soundID == sound.chatterSoundID {
                // Hold the next chatter line until this one ends (`DAT_00591a8c`).
                sound.chatterSoundID = nil
                if played { sound.chatterEnd = now + length } else { world?.combatChatterPlaying = false }
            }
        }
        var rows: [Float] = []
        for c in sound.board.commands(now: now) {
            rows.append(contentsOf: [Float(c.node), Float(c.soundID), c.gain, Float(c.action.rawValue),
                                     Float(c.rate), c.interfaceVolume ? 1 : 0])
        }
        return PackedFloat32Array(rows)
    }

    /// A sample's length in seconds (0 = missing), decoded once per id.
    private func soundLength(_ id: Int) -> Double {
        if let hit = sound.durations[id] { return hit }
        let length = game?.sound(id).map { $0.samples.isEmpty ? 0 : $0.duration } ?? 0
        sound.durations[id] = length
        return length
    }

    /// The sounds that come from world state rather than a `WorldEvent`, ticked
    /// once per `step` like `GameScene.updateWarnings` / the jump phases: the
    /// threat Red Alert (snd 370), the death-timer Klaxxon (snd 371), the Warp up
    /// cue (spin-up start; cut at 350 / multiplier), and the chatter hold.
    private func tickSoundAlarms(dt: Double) {
        guard let world else { return }
        sound.rawCallAccumulator += max(0, dt) * OriginalClock.rawCallsPerSecond
        let calls = Int(sound.rawCallAccumulator)
        sound.rawCallAccumulator -= Double(calls)
        if sound.redAlert.advance(rawCalls: calls, lowVolume: false, inEscapePod: world.playerInEscapePod,
                                  threat: { world.isAnyShipThreatToPlayerSquad }) {
            sound.pending.append(SoundCues.redAlert)
        }
        if world.isPlayerDeathTimerRunning {
            sound.pending.append(SoundCues.klaxxon)      // only when none is sounding
        } else if sound.klaxxonOn {
            sound.board.stop(soundID: SoundCues.klaxxonID)
        }
        sound.klaxxonOn = world.isPlayerDeathTimerRunning

        if let jump = world.playerJump {
            if jump.phase == .spinUp, !sound.warpUpStarted {
                sound.warpUpStarted = true
                sound.pending.append(SoundCues.warpUp(multiplier: jump.multiplier, x2: jump.cueX2 == true))
            }
            if jump.phase == .spinUp, jump.warpUpCut, !sound.warpUpCut {
                sound.warpUpCut = true
                sound.board.stop(soundID: SoundCues.hyperspaceChargeID)
                sound.board.stop(soundID: SoundCues.warpUp2xID)
            }
        } else {
            sound.warpUpStarted = false
            sound.warpUpCut = false
        }

        if let end = sound.chatterEnd, ProcessInfo.processInfo.systemUptime >= end {
            sound.chatterEnd = nil
            world.combatChatterPlaying = false
        }
    }

    // MARK: App shell

    /// The title-music file name from `STR# 130` #2 (`FUN_004ab5d0`), or "" when
    /// absent. The frontend does the file lookup (`OriginalAudio.musicCandidates`).
    @Callable(autoSnakeCase: true) func titleMusicName() -> String {
        game?.stringList(130)?.string(at: 2) ?? ""
    }
}
