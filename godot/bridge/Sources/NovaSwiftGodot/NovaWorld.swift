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
    case shipAlt = 11        // the shän alternating-sprite overlay (plug-in hulls)
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
    /// The user settings that change how the world plays (see `// MARK: Settings plumbing`).
    private var plumbing = SettingsPlumbing()
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
    /// An original EV Nova pilot converted by `pilotImportPreview`, held until `pilotImportCommit`.
    private var pendingImport: EVNovaPilotImportResult?
    /// Progress / result of `loadGameAsync` (see PilotFiles.swift).
    private let asyncLoad = AsyncLoadState()
    /// Settings > Saved Games > Frequent autosave (Apple `GameplayEnhancements.frequentAutosave`):
    /// save on landing, jumping and a 180 s in-flight heartbeat, and keep the in-flight position.
    private var frequentAutosave = false
    /// Unpaused flight seconds since the last rotating in-flight backup (Apple `backupHeartbeat`).
    private var periodicClock = 0.0
    /// The flight-training sandbox (Apple `GameHost.makeTrainingHost`): a throwaway pilot that
    /// never saves; the real pilot waits here until `tutorialEnd`.
    private var training: TrainingSession?
    private var tutorialRun = TutorialProgression()
    private struct TrainingSession {
        var pilot: PlayerState
        var started: Bool
        var saveID: UUID?
        var landed = false
    }

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
    /// The status line's per-line durations, the frontend's busy flag, the HailQuote broadcaster.
    private var statusLine = StatusLineState()
    /// Per-ship overlay clocks, animated stellars, weapon visuals (see `// MARK: Flight visuals`).
    private let flightVisuals = FlightVisuals()

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
        statusLine.resetForNewWorld()   // HailQuote latches are per world
        travel.resetForNewWorld()    // selected stellar, landing clearance, gate state
        interactionsWorldRebuilt()   // close hail/plunder windows, bring the escort wing back
        storyWorldRebuilt()          // attach the mission-ship host, drop active missions' ships in
        gaps.resetForNewWorld()      // përs offer, self-destruct, pod respawn latches
        flightVisuals.reset()        // overlay clocks / stellar animators
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
        // Base data + the enabled plug-ins (Nova Plug-ins folder / user plug-in folder), merged in
        // load order exactly as the Apple app does — see Plugins.swift. Empty/missing base is rejected.
        guard let collection = PluginRuntime.shared.loadMerged(baseDir: URL(fileURLWithPath: baseDir)) else { return false }
        let g = NovaGame(collection)
        self.game = g
        self.galaxy = Galaxy(game: g, flightTuning: plumbing.flightTuning)
        return true
    }

    /// After `loadGame`, populate a real system with NPCs from its `düde`/`flët`
    /// spawn table via `GameSession.makeWorld`. Pass a negative id to use the
    /// data's starting system. Returns false if no game is loaded.
    @Callable(autoSnakeCase: true)
    func makeWorld(systemID: Int) -> Bool {
        guard let game = self.game else { return false }
        let galaxy = self.galaxy ?? Galaxy(game: game, flightTuning: plumbing.flightTuning)
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

        let (w, _) = makeConfiguredWorld(game: game, systemID: sysID, player: player, galaxy: galaxy)
        // A pilot saved at a spaceport (the original's only save point) resumes
        // at that stellar's centre, at rest, on a random whole-degree heading
        // (FL-20) — mirrors GameContainerView's resume placement.
        if let sid = pilot.landedSpob, let body = w.systemContext.bodies.first(where: { $0.id == sid }) {
            player.position = body.position
            player.angle = Double(Int.random(in: 0..<360)) * .pi / 180
            player.velocity = Vec2()
        } else if training != nil {
            player.position = w.systemContext.center + Vec2(0, -700)   // the sandbox flies, it doesn't launch
        } else if sysID == pilot.currentSystem, let x = pilot.shipPositionX, let y = pilot.shipPositionY {
            // A frequent-autosave pilot resumes where it was in flight (Apple `GameHost` restore).
            player.position = Vec2(x, y)
            player.angle = pilot.shipHeading ?? 0
            player.velocity = Vec2()
        }
        if training != nil { player.invulnerable = true }   // the trainee cannot die
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
        var live = settingsPlayerIntent(self.intent)  // Settings: invert turn, mouse aim, auto-landing
        live.selfDestruct = gaps.selfDestructHeld     // Alt-−, held
        world.intent = world.playerJump == nil ? live : ControlIntent()
        settingsAutoTarget(world)                     // Settings: auto-target after firing

        // Settings > Game speed, doubled while the original's Caps Lock 2x flag is up
        // (`GameSpeedRules`, the Apple `GameScene.update` clock): the multiplier rides
        // the timestep into the accumulator, so faster just means more ticks per frame.
        let speed = settingsSpeed(world)
        let fixed = Self.fixedStep
        // Clamp before the loop, not inside it: a 4-second stall should drop the
        // backlog, not simulate 4 seconds of combat in one frame.
        let cap = fixed * Double(GameSpeedRules.catchupTickCap(multiplier: speed, base: Self.maxCatchupTicks))
        simAccumulator = min(simAccumulator + max(0, dt) * speed, cap)
        while simAccumulator >= fixed {
            world.snapshotRenderState()   // pre-tick pose for render interpolation
            world.step(fixed)
            plumbing.ticks += 1
            simAccumulator -= fixed
            collectEvents(from: world)    // World.events is cleared by the next step
            gapsAfterTick(world)          // tribbles breed / perishables rot (EC-24)
        }
        tickSoundAlarms(dt: dt)       // red alert / klaxxon / warp-up cue
        tickInteractions(dt: dt)      // Escort Commands panel clock
        tickHailQuotes(dt: dt)        // pêrs HailQuote broadcasts (0x00433050)
        tickTravel()                  // the 250 px landing-clearance arm
        tickStory(dt: dt)             // sightings, queued world edits
        gapsTick()                    // the escape pod's respawn
        advanceHyperjump()            // arrival once the engine's jump has fired
        advanceFlightVisuals(dt: dt)  // hull overlay clocks, animated stellars
        tickPeriodicAutosave(dt: dt)  // frequent autosave's in-flight heartbeat
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
            if case let .shipDying(entityID, at, boomID) = event {
                // A dying hull is ten staggered bursts, not one bang (see `DeathBurstSounds`).
                sound.deaths.begin(entityID: entityID, at: at, boomID: boomID, game: game)
            } else {
                sound.pending.append(contentsOf: SoundCues.cues(for: event, game: game))
            }
            interactionsNote(event)       // tribute / lost escort -> pilot
            storyNote(event)              // mission ship goals / losses, fail-if-disabled
            gapsNote(event)               // scans, eject, pod respawn, game over
            polishNote(event)             // original STR# 2002 status lines
            flightVisuals.bodies = world.systemContext.bodies
            flightVisuals.note(event: event, game: game)   // weapon-glow flare on fire
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
            case let .shipDisabled(_, at):
                push(7, at, 0)
            case .playerDying:
                if let w = self.world { push(4, w.player.position, Float(w.player.explosionBoomID ?? -1), 1) }
            case let .areaBlast(at, blastRadius):
                push(8, at, Float(blastRadius))
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

    /// Test seam / "forgiving" lander: attempt to land on the nearest body in
    /// reach with no clearance exchange and no fee. The game itself lands through
    /// `press_land` (the original's two-press flow, below). Fails (returns false)
    /// if out of reach or moving too fast. On success the frontend should stop
    /// calling `step()` and show spaceport screens until `launch()`.
    @Callable(autoSnakeCase: true) func attemptLand() -> Bool {
        guard canLandNow(), let target = nearestReachableLandTarget() else { return false }
        touchDown(spobID: target.id, chargeFee: false)
        return true
    }

    /// Set the ship down at `spobID` and open the docked state.
    private func touchDown(spobID: Int, chargeFee: Bool) {
        // The training sandbox never docks: the landing just completes the lesson.
        if training != nil {
            training?.landed = true
            post("Docking clamps engaged — nicely done, Captain.")
            return
        }
        // Hand the flight ship's hold back to the pilot before the spaceport
        // screens read it. Anything picked up in flight — mined ore, plundered
        // cargo — lives on the `Ship` until touchdown, and `launch()` re-seeds
        // the ship from `pilot.cargo`, so without this handoff a run's takings
        // would be silently thrown away the moment it docked.
        // Fuel goes the same way: the pilot owns the tank level while docked
        // (refuelling is paid), and `launch()` carries it back out.
        if let ship = world?.player { pilot.cargo = ship.cargo; pilot.fuel = ship.fuel }
        // What was fired or lost in flight stays spent (UI-02), and the crimes / kills / garrison
        // changes the visit made are folded into the pilot (Apple `syncCombatStanding` + `recordMunitions`).
        if let ship = world?.player, let game { Munitions.record(ship, into: &pilot, game: game) }
        syncLiveStanding()
        // The landing fee (EC-05): the full `spöb` fee, waived at a dominated
        // stellar. Clearance already refused a landing the player couldn't pay for.
        if chargeFee, let spob = game?.spob(spobID) {
            let fee = LandedServices.landingFee(spob: spob, state: pilot)
            if fee > 0 { pilot.credits = max(0, pilot.credits - fee) }
        }
        storyLeavingSystem()                      // surviving aux ships go back to their budgets
        dockedSpobID = spobID
        sound.pending.append(SoundCues.docking)   // .shipLanded for entity 0: snd 390
        pilot.landedSpob = spobID
        // The landing pass: offer lists refresh, cargo is picked up / dropped, and a
        // mission whose objective is done here completes and pays (0x00443780).
        if let engine = storyEngine() {
            engine.playerLanded(onSpob: spobID)
            storyCommit(engine)
        }
        visitDays = SpaceportVisitDays()
        outfitterOwnedAtOpen = nil
        // The auto-refueller (oütf ModType 19) runs on docking, skipped at an
        // uninhabited stellar — shared with the Apple spaceport.
        if let galaxy, let spob = game?.spob(spobID) {
            SpaceportShops.autoRecharge(&pilot, spob: spob, galaxy: galaxy)
        }
        _ = autosave(.land)           // `frequentAutosave` only; the original saves on leaving
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
        gapsDeparting(from: spobID)   // escort sales / upgrades, one payroll period (EC-22, EC-20)
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
        let (w, _) = makeConfiguredWorld(game: game, systemID: currentSystemID ?? sysID, player: player, galaxy: galaxy)
        let ctx = w.systemContext
        // Lift off exactly as the original (`Stellar_RunDockAndLaunchSequence`
        // 0x00455e10) and the Apple `GameScene.reloadForDeparture`: at the
        // stellar's CENTRE, at rest, facing a random whole-degree heading, with
        // shields and armor refilled. (Placing the ship past the rim made it
        // visibly jump away from the planet on launch.)
        if let body = ctx.bodies.first(where: { $0.id == spobID }) {
            player.position = body.position
            player.angle = Double(w.rng.range(360)) * .pi / 180
            player.velocity = Vec2()
            player.shield = player.maxShield
            player.armor = player.maxArmor
        } else {
            player.position = ctx.center + Vec2(0, -700)
        }
        player.currentTargetID = nil
        self.world = w
        dockedSpobID = nil
        pilot.landedSpob = nil
        resetFrameState()
        // The launch line (0x00456134; UI-11): a staged mission `Q` message replaces it
        // (snd 154, 0x1f4 raw calls), else "Launching from X on <date>." (#55-60).
        if let launchMessage {
            if !launchMessage.isEmpty {
                beep(5)
                post(launchMessage, rawCalls: OriginalText.Duration.missionQuote)
            }
        } else {
            post(StatusLineBackend.launch(game: game, pilot: pilot, spobID: spobID))
        }
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
        if let line = world.strandedFighterWarning(game: game) { nav.messages.append(line) }   // "Wait for me!" (FL-23)
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
        syncLiveStanding()                           // the about-to-be-discarded world holds the legal record
        storyLeavingSystem()                         // surviving aux ships go back to their budgets
        let abandonedFighters = world.returnJumpingFighters()   // rides on the arrival line (UI-11)
        // AI-38: disabled escorts are lost, the rest keep shields/armor/fuel/ammo
        // into the next system (`respawn` consumes this on the rebuild below).
        interact.messages += interact.escorts.carryThroughJump(world: world, pilot: &pilot, game: game, via: .jump)
        let escortDays = world.attachedShipsTravelDays(galaxy: galaxy)
        ship.consumeJumpFuel()                       // one jump, however many hops (FL-06)
        nav.route.arrive(at: plan.destination, crossing: plan.hops, linked: nv.isLinked)
        nav.selected = nil
        pilot.cargo = ship.cargo
        let jumpDays = HyperjumpCommit.apply(&pilot, game: game, galaxy: galaxy, destination: plan.destination,
                              passedThrough: plan.passedThrough, shipFuel: ship.fuel, extraDays: escortDays,
                              services: storyState.services)
        gapsPayEscorts(periods: jumpDays)            // one payroll period per travel day (EC-20)
        // The mission pass runs after a jump's days: a deadline that ran out fails now.
        storyBindHooks()
        if !pilot.activeMissions.isEmpty, let engine = storyEngine() {
            engine.missionFlightPass()
            pilot = engine.player
        }

        let (w, _) = makeConfiguredWorld(game: game, systemID: plan.destination, player: ship, galaxy: galaxy)
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
        postArrivalLine(systemID: plan.destination, gateID: nil, abandonedFighters: abandonedFighters)
        sound.board.stop(soundID: SoundCues.hyperspaceChargeID)   // the jump cut its Warp up
        sound.board.stop(soundID: SoundCues.warpUp2xID)
        sound.pending.append(SoundCues.hyperspaceArrive)           // arriving: Warp out
        _ = autosave(.jump)                                        // `frequentAutosave` only (UI-01)
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
    /// - `7` ship disabled; `8` area blast (`p0` blast radius); `9` ship launched (`p0` entity id);
    ///   `10` ship landed (`p0` shïp id, `p1` heading frame, `r`/`g` the stellar's x/y to shrink into)
    ///
    /// Everything else in `WorldEvent` is narrative rather than visual and comes
    /// through `drainEvents()` by name only.
    @Callable(autoSnakeCase: true) func drainEffects() -> PackedFloat32Array {
        let rows = pendingEffects + flightVisuals.extraEffects
        pendingEffects.removeAll(keepingCapacity: true)
        flightVisuals.extraEffects.removeAll(keepingCapacity: true)
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
        case .shipAlt:       return untimed(game.altSprite(id))
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
    /// always, the rest only under the `frequentAutosave` setting (`set_frequent_autosave`).
    /// `reason` is a `PilotSaveReason` case name
    /// ("launch", "background", "backgroundLanded", ...). Returns whether it wrote.
    @Callable(autoSnakeCase: true) func pilotAutosave(reason: String) -> Bool {
        guard let r = Self.saveReason(reason) else { return false }
        return autosave(r)
    }

    /// True when a roster pilot is bound (so autosave has somewhere to write).
    @Callable(autoSnakeCase: true) func hasPilotSave() -> Bool { pilotSaveID != nil }

    @Callable(autoSnakeCase: true) func pilotName() -> String { pilot.pilotName }

    // MARK: New-pilot flow (intro, death, slots and backups, frequent autosave, training)
    //
    // Mirrors Apple's `IntroSequenceView`, `GameContainerView.onPlayerDestroyed`,
    // `PilotGroupDetailView` / `PilotBackupsView`, `frequentAutosave` and the flight-training
    // sandbox. The rules are shared (`PilotGroups`, `PilotSavePolicy`, `TutorialCurriculum`).

    /// The scenario's intro as JSON `{slides: [{pict, duration}], text}`: its `chär` intro PICTs
    /// (shown `duration` s each) and the intro `dësc` text. Both empty when it has none.
    @Callable(autoSnakeCase: true) func pilotIntro(scenarioID: Int) -> String {
        guard let game, let sc = game.selectableScenarios().first(where: { $0.id == scenarioID }) else {
            return "{\"slides\":[],\"text\":\"\"}"
        }
        let text = sc.introTextID.map { game.descText($0) } ?? ""
        return Self.json(["slides": sc.introSlides.map { ["pict": $0.pictID, "duration": $0.duration] as [String: Any] },
                          "text": text])
    }

    /// Settings > Saved Games > Frequent autosave.
    @Callable(autoSnakeCase: true) func setFrequentAutosave(on: Bool) { frequentAutosave = on }
    @Callable(autoSnakeCase: true) func frequentAutosaveOn() -> Bool { frequentAutosave }

    /// Pilots grouped into save slots, newest first, as JSON `[{group, name, scenario, most_recent,
    /// can_add, max_slots, slots: [{id, slot, ship, system, credits, rating, updated, backups}]}]`.
    @Callable(autoSnakeCase: true) func pilotGroups(dir: String) -> String {
        let a = archive(at: dir)
        let rows = PilotGroups.groups(a.list()).map { g -> [String: Any] in
            ["group": g.id.uuidString, "name": g.mostRecent.displayName, "scenario": g.mostRecent.scenarioName,
             "most_recent": g.mostRecent.id.uuidString, "can_add": g.canAddSlot,
             "max_slots": PilotGroups.maxSlotsPerPilot,
             "slots": g.slots.enumerated().map { i, s -> [String: Any] in
                var row = PilotFiles.row(s)
                row["slot"] = i + 1
                row["backups"] = a.backups(for: s.id).count
                return row
             }]
        }
        return Self.json(rows)
    }

    /// Every backup across the group's slots, newest first: JSON `[{slot_id, slot, path, system,
    /// credits, updated}]` (`PilotRoster.groupHistory`).
    @Callable(autoSnakeCase: true) func pilotGroupHistory(dir: String, groupID: String) -> String {
        let a = archive(at: dir)
        guard let gid = UUID(uuidString: groupID),
              let group = PilotGroups.groups(a.list()).first(where: { $0.id == gid }) else { return "[]" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return Self.json(PilotGroups.history(of: group, in: a).map { h -> [String: Any] in
            ["slot_id": h.slotID.uuidString, "slot": h.slotIndex + 1, "path": h.url.path,
             "system": h.save.snapshot.systemName, "ship": h.save.snapshot.shipName,
             "credits": h.save.snapshot.credits, "updated": fmt.string(from: h.save.updatedAt)]
        })
    }

    /// Roll slot `slotID` back to the backup file at `path` (the current state is backed up first,
    /// so this is undoable). The caller then plays it with `pilot_load`.
    @Callable(autoSnakeCase: true) func pilotRestore(dir: String, slotID: String, path: String) -> Bool {
        let a = archive(at: dir)
        guard let id = UUID(uuidString: slotID), a.exists(id: id) else { return false }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path.hasPrefix(a.backupsRoot.standardizedFileURL.path),
              (try? a.restore(id: id, from: url)) != nil else { return false }
        return true
    }

    /// Add a save slot to a group, cloned from its most recent slot (capped at 3). New slot's id or "".
    @Callable(autoSnakeCase: true) func pilotAddSlot(dir: String, groupID: String) -> String {
        let a = archive(at: dir)
        guard let gid = UUID(uuidString: groupID),
              let group = PilotGroups.groups(a.list()).first(where: { $0.id == gid }), group.canAddSlot,
              let created = try? a.createSlot(from: group.mostRecent.id) else { return "" }
        return created.id.uuidString
    }

    /// Rename every slot of a group (the display name is the pilot's identity).
    @Callable(autoSnakeCase: true) func pilotRenameGroup(dir: String, groupID: String, name: String) -> Bool {
        let a = archive(at: dir)
        guard let gid = UUID(uuidString: groupID), !name.isEmpty, name.count <= PilotFactory.maxNameLength,
              let group = PilotGroups.groups(a.list()).first(where: { $0.id == gid }) else { return false }
        for slot in group.slots {
            var s = slot
            s.displayName = name
            _ = try? a.save(s, backup: false)
        }
        return true
    }

    /// Delete one save slot and its backups, keeping the rest of the pilot.
    @Callable(autoSnakeCase: true) func pilotDeleteSlot(dir: String, id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        try? archive(at: dir).delete(id: uuid)
        if pilotSaveID == uuid { pilotSaveID = nil }
        return true
    }

    /// The death sequence ran out with no eject (`GameContainerView.onPlayerDestroyed`): under Strict
    /// Play the pilot is deleted outright (every slot and backup, FL-03), otherwise it is marked
    /// killed and resumes from its last launch. JSON `{result: "deleted"|"killed"|"none", id, name}`.
    @Callable(autoSnakeCase: true) func pilotKilled() -> String {
        guard training == nil, pilotStarted, let id = pilotSaveID, let a = pilotArchive else {
            return Self.json(["result": "none", "id": "", "name": ""])
        }
        let name = pilot.pilotName
        if pilot.strictPlayDeathDeletesPilot {
            PilotGroups.deleteGroupAfterStrictPlayDeath(id: id, in: a)
            pilotSaveID = nil          // nothing left to resume or autosave
            pilotStarted = false
            pilot = PlayerState()
            return Self.json(["result": "deleted", "id": id.uuidString, "name": name])
        }
        return Self.json(["result": "killed", "id": id.uuidString, "name": name])
    }

    // -- Flight training (Apple TutorialContainerView's throwaway GameHost) --

    /// Swap in a throwaway pilot for the training flight; nothing saves while it runs. The frontend
    /// follows with `make_world(-1)`. False with no game loaded or a session already running.
    @Callable(autoSnakeCase: true) func tutorialBegin() -> Bool {
        guard let game, training == nil else { return false }
        syncLiveStanding()   // the real pilot keeps what it earned; the trainee starts clean
        training = TrainingSession(pilot: pilot, started: pilotStarted, saveID: pilotSaveID)
        var p = PilotFactory.makeDefault(name: "Trainee", isMale: true, game: game)
        p.landedSpob = nil
        pilot = p
        pilotStarted = true
        pilotSaveID = nil
        dockedSpobID = nil
        return true
    }

    /// End the training flight: the real pilot (if any) is back, untouched.
    @Callable(autoSnakeCase: true) func tutorialEnd() {
        guard let t = training else { return }
        syncLiveStanding()   // the trainee's accrued standing is thrown away with it
        pilot = t.pilot
        pilotStarted = t.started
        pilotSaveID = t.saveID
        training = nil
        dockedSpobID = nil
    }

    @Callable(autoSnakeCase: true) func tutorialActive() -> Bool { training != nil }

    /// True once (then false) after the trainee set down on a planet.
    @Callable(autoSnakeCase: true) func tutorialTakeLanded() -> Bool {
        defer { training?.landed = false }
        return training?.landed ?? false
    }

    /// What the training ship can do, as JSON `{afterburner, secondary}` (steps it can't do are dropped).
    @Callable(autoSnakeCase: true) func tutorialCapabilities() -> String {
        let p = world?.player
        return Self.json(["afterburner": p?.afterburner != nil, "secondary": !(p?.secondaryWeaponIDs.isEmpty ?? true)])
    }

    @Callable(autoSnakeCase: true) func tutorialAfterburnerActive() -> Bool { world?.player.afterburnerActive ?? false }

    /// Begin the coached course (the shared `TutorialCurriculum` + `TutorialProgression` Apple's
    /// `TutorialRun` drives): worded for `style` ("keyboard" | "pad"), `labels` = JSON
    /// `{action: "label"}` naming each control (`TutorialAction` raw values). Steps the ship can't do
    /// are dropped (`has_afterburner` / `has_secondary` from `tutorial_capabilities`).
    @Callable(autoSnakeCase: true)
    func tutorialStart(style: String, labels: String, hasAfterburner: Bool, hasSecondary: Bool) {
        let names = (try? JSONSerialization.jsonObject(with: Data(labels.utf8))) as? [String: String] ?? [:]
        tutorialRun.configure(TutorialCurriculum.build(
            style: style == "pad" ? .pad : .keyboard,
            label: { names[$0.rawValue] ?? $0.rawValue },
            hasAfterburner: hasAfterburner, hasSecondary: hasSecondary))
    }

    /// The run's state as JSON `{index, count, number, finished, is_last, steps: [{id, title, icon, body,
    /// goal}]}`; `goal` is "" for a manual (Continue) card.
    @Callable(autoSnakeCase: true) func tutorialState() -> String {
        let r = tutorialRun
        return Self.json(["index": r.index, "count": r.stepCount, "number": r.stepNumber,
                          "finished": r.finished, "is_last": r.isLast,
                          "steps": r.steps.map { ["id": $0.id, "title": $0.title, "icon": $0.systemImage,
                                                  "body": $0.body, "goal": $0.goal?.rawValue ?? ""] as [String: Any] }])
    }

    /// Continue / Skip step.
    @Callable(autoSnakeCase: true) func tutorialAdvance() { tutorialRun.advance() }

    /// The frontend observed `goal` ("fly", "turn", "afterburner", "target", "fire", "changeWeapon",
    /// "land"); advances only if the current step waits on exactly that.
    @Callable(autoSnakeCase: true) func tutorialComplete(goal: String) {
        if let g = TutorialGoal(rawValue: goal) { tutorialRun.complete(g) }
    }

    /// The hint for docked screen `screen` ("hub" | "bbs" | "outfitter") as JSON `{id, title, message,
    /// key}`, or "" when that screen has none (`NovaHints.hint(forSpaceportScreen:)`).
    @Callable(autoSnakeCase: true) func gameHintForScreen(screen: String) -> String {
        guard let h = NovaHints.hint(forSpaceportScreen: screen) else { return "" }
        return Self.json(["id": h.id, "title": h.title, "message": h.message, "key": NovaHints.storageKey(h.id)])
    }

    /// The contextual hint catalog as JSON `[{id, title, message, key}]` (`NovaHints`).
    @Callable(autoSnakeCase: true) func gameHints() -> String {
        Self.json(NovaHints.all.map { ["id": $0.id, "title": $0.title, "message": $0.message,
                                       "key": NovaHints.storageKey($0.id)] as [String: Any] })
    }

    // MARK: Pilot files
    //
    // Pilots are real files: `<Pilots folder>/<uuid>.evpilot` (the Apple app's format). These
    // let the frontend open one from anywhere (the OS file picker) and bring in an original
    // EV Nova pilot (`EVNovaPilotImporter`), both ending up as `.evpilot` in the Pilots folder.

    /// The save file for `id` in `dir`.
    @Callable(autoSnakeCase: true) func pilotFilePath(dir: String, id: String) -> String {
        guard let uuid = UUID(uuidString: id) else { return "" }
        return archive(at: dir).fileURL(for: uuid).path
    }

    /// What `path` is, without changing anything: JSON `{kind: "evpilot" | "original" | "unknown",
    /// ...}`. evpilot rows match `pilot_list`'s (plus `id`); an original pilot gives its format
    /// and name (the full summary needs `pilot_import_preview` and the game data).
    @Callable(autoSnakeCase: true) func pilotInspectFile(path: String) -> String {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return Self.json(["kind": "unknown", "error": "File not found."]) }
        if let save = PilotFiles.decodeNative(url) { return Self.json(PilotFiles.row(save)) }
        if let blocks = try? EVNovaPilotFile.load(url: url) {
            return Self.json(["kind": "original", "format": blocks.format.rawValue,
                              "name": blocks.containerName ?? url.deletingPathExtension().lastPathComponent])
        }
        return Self.json(["kind": "unknown", "error": "This is not an EV Nova or NovaSwift pilot file."])
    }

    /// Open the `.evpilot` at `path` from anywhere: a file outside `dir` is copied in first (a
    /// copy already there is replaced only by a newer one), then it is loaded as the live
    /// pilot exactly as `pilot_load` does. Returns the save id, or "" when it is not a readable
    /// pilot. The frontend follows with `make_world(-1)`.
    @Callable(autoSnakeCase: true) func pilotOpenFile(dir: String, path: String) -> String {
        guard game != nil, var save = PilotFiles.decodeNative(URL(fileURLWithPath: path)) else { return "" }
        let a = archive(at: dir)
        let inside = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
            == a.root.standardizedFileURL.path
        if !inside {
            if a.exists(id: save.id), let have = try? a.load(id: save.id), have.updatedAt >= save.updatedAt {
                // keep the newer copy already in the Pilots folder
            } else {
                guard let written = try? a.save(save, backup: a.exists(id: save.id)) else { return "" }
                save = written
            }
        }
        return pilotLoad(dir: dir, id: save.id.uuidString) ? save.id.uuidString : ""
    }

    /// Step 1 of importing an original EV Nova pilot (`.plt` / Mac pilot): decode and convert
    /// it against the loaded game data, hold the result, and return its summary as JSON
    /// (`kind: "original"`, name, ship, credits, ..., `warnings`, `unmapped`) — or
    /// `{error}`. The source file is only ever read.
    @Callable(autoSnakeCase: true) func pilotImportPreview(path: String) -> String {
        pendingImport = nil
        guard let game else { return Self.json(["error": "Load the game data first."]) }
        do {
            let result = try EVNovaPilotImporter.importPilot(from: URL(fileURLWithPath: path), game: game)
            pendingImport = result
            return Self.json(PilotFiles.summaryJSON(result.summary, date: result.player.date.description))
        } catch {
            return Self.json(["error": error.localizedDescription])
        }
    }

    /// Step 2: write the held conversion into `dir` as a new `.evpilot` ("Imported from EV Nova",
    /// as Apple's `PilotRoster.importConverted`) and make it the live pilot. Returns the save id
    /// or "".
    @Callable(autoSnakeCase: true) func pilotImportCommit(dir: String) -> String {
        guard let game, let result = pendingImport else { return "" }
        let name = result.summary.pilotName
        var save = PilotSave(displayName: name.isEmpty ? "Captain" : name,
                             scenarioName: "Imported from EV Nova",
                             player: result.player, game: game,
                             dataFingerprint: PilotSaves.fingerprint(for: game))
        save.player.rosterID = save.id
        guard let written = try? archive(at: dir).save(save, backup: false) else { return "" }
        pendingImport = nil
        var state = written.player
        PilotSaves.migrate(&state, game: game)
        adoptPilot(state, saveID: written.id)
        return written.id.uuidString
    }

    // MARK: Async data load
    //
    // `load_game` blocks for as long as the ~60 MB of containers take to read and merge. This
    // runs the same work on a worker thread so the frontend's loading screen can animate;
    // GDScript polls `load_status` and the result is adopted on the main thread when it
    // reports `done` (the same call installs it, so no other bridge call may overlap).

    /// Start `load_game` for `baseDir` on a worker thread. False if a load is already running.
    @Callable(autoSnakeCase: true) func loadGameAsync(baseDir: String) -> Bool {
        guard asyncLoad.begin() else { return false }
        let state = asyncLoad
        let flightTuning = plumbing.flightTuning   // formationFlying is baked into the galaxy's ships
        Thread.detachNewThread {
            state.report("Finding resource files", 0.04)
            state.report("Reading game data and plug-ins", 0.12)
            // Same merge as `load_game`: base data + enabled plug-ins (Plugins.swift).
            guard let collection = PluginRuntime.shared.loadMerged(baseDir: URL(fileURLWithPath: baseDir)) else { state.finish(nil); return }
            state.report("Indexing the galaxy", 0.85)
            let g = NovaGame(collection)
            let galaxy = Galaxy(game: g, flightTuning: flightTuning)
            state.finish((g, galaxy))
        }
        return true
    }

    /// JSON `{running, done, ok, phase, fraction}`. When a finished load is first seen here the
    /// result is installed (like `load_game`) before this returns.
    @Callable(autoSnakeCase: true) func loadStatus() -> String {
        var snap = asyncLoad.snapshot()
        if snap["done"] as? Bool == true, snap["ok"] as? Bool == true, let (g, galaxy) = asyncLoad.take() {
            self.game = g
            self.galaxy = galaxy
        }
        snap["installed"] = game != nil
        return Self.json(snap)
    }

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
        syncLiveStanding()   // the outgoing pilot takes its own accrued standing, not the next one's
        pilot = state
        pilot.rosterID = saveID
        pilotSaveID = saveID
        pilotStarted = true
    }

    /// `AppModel.autosave`, minus the settings the Godot build doesn't have yet.
    @discardableResult
    private func autosave(_ reason: PilotSaveReason) -> Bool {
        guard pilotSaveID != nil,
              reason.shouldSave(frequentAutosave: frequentAutosave, strictPlay: pilot.isStrictPlay) else { return false }
        return writePilot(backup: reason.wantsBackup)
    }

    /// Apple's `backupHeartbeat`: every 180 s of unpaused flight, under `frequentAutosave`.
    private func tickPeriodicAutosave(dt: Double) {
        guard frequentAutosave, training == nil, dockedSpobID == nil else { return }
        periodicClock += dt
        if periodicClock >= 180 {
            periodicClock = 0
            _ = autosave(.periodic)
        }
    }

    private func writePilot(backup: Bool) -> Bool {
        guard let a = pilotArchive, let id = pilotSaveID else { return false }
        // Without `frequentAutosave` the original keeps no in-flight position: a
        // pilot reloads at the stellar it last launched from (UI-01).
        if frequentAutosave, let ship = world?.player {
            pilot.shipPositionX = ship.position.x
            pilot.shipPositionY = ship.position.y
            pilot.shipHeading = ship.angle
        } else {
            pilot.shipPositionX = nil
            pilot.shipPositionY = nil
            pilot.shipHeading = nil
        }
        if let ship = world?.player, let game { Munitions.record(ship, into: &pilot, game: game) }
        syncLiveStanding()   // legal record, rating, garrisons, stellar armor
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

    /// Hail the locked ship — or, with `stellar` (Alt-Y) or no ship target, the
    /// selected stellar (`GameScene.attemptHail`): nothing selected, nothing happens. JSON `{result: nothing|refused|escorts|window, message,
    /// beep}`; `beep` is the interface beep (1…5) the original sounds.
    @Callable(autoSnakeCase: true) func hailOpen(stellar: Bool) -> String {
        guard let world, let game, dockedSpobID == nil, world.player.isAlive else {
            return interactionJSON("nothing")
        }
        let opening: FlightComm.Opening
        if !stellar, let tid = world.player.currentTargetID, let ship = world.ship(id: tid), ship.isAlive {
            opening = interact.comm.openShip(entityID: tid, world: world, game: game, pilot: &pilot)
        } else if let spobID = travel.selectedSpob, world.systemContext.bodies.contains(where: { $0.id == spobID }) {
            opening = interact.comm.openPlanet(spobID: spobID, world: world, game: game, pilot: &pilot,
                                               systemID: currentSystemID ?? -1)
        } else {
            opening = .nothing
        }
        switch opening {
        case .nothing: return interactionJSON("nothing")
        case let .refused(message): return interactionJSON("refused", message: message, beep: 4)
        case .escortWindow: return interactionJSON("escorts", beep: 5)
        case .window:
            // A përs's LinkMission is offered over the hail like the bar's (Flags 0x0200 = on boarding).
            if let offer = interact.comm.persOffer { gapsPresentPersOffer(personID: offer.personID, missionID: offer.missionID) }
            return interactionJSON("window", beep: 5)
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
        case .window:
            gapsBoardedPersOffer()
            return interactionJSON("window")
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
        let (w, _) = makeConfiguredWorld(game: game, systemID: sysID, player: ship, galaxy: galaxy)
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
        let strs = game?.stringList(2002)
        return Self.json(interact.escorts.members(world: world, pilot: pilot).map { m in
            // Upgrade / Sell are toggle marks the fleet pass processes on leaving a shipyard
            // (NovaUi_RunEscortShipManagementWindow 0x004853a0, EC-22; STR# 2002 #292 / #295).
            let rec = m.recordID.flatMap { pilot.escort(id: $0) }
            let hull = game?.ship(m.shipTypeID)
            let target = (m.recordID != nil && game != nil)
                ? PilotEconomy.escortUpgradeTarget(pilot, recordID: m.recordID!, game: game!) : nil
            let status = rec?.pendingUpgradeTo != nil ? (strs?.string(at: 292) ?? "")
                : (rec?.pendingSale == true ? (strs?.string(at: 295) ?? "") : "")
            return ["entity": m.entityID, "record": m.recordID ?? -1, "name": m.name, "shield": m.shieldFraction,
                    "armor": m.armorFraction, "fighter": m.isFighter, "disabled": m.disabled,
                    "origin": m.originLabel, "canRelease": m.canRelease,
                    "canUpgrade": target != nil, "upgradeName": target?.displayName ?? "",
                    "upgradeCost": hull?.escortUpgradeCost ?? 0, "pendingUpgrade": rec?.pendingUpgradeTo != nil,
                    "canSell": m.recordID.map { PilotEconomy.canSellEscort(pilot, recordID: $0) } ?? false,
                    "sellValue": hull.map { PilotEconomy.escortSellValue(for: $0) } ?? 0,
                    "pendingSale": rec?.pendingSale == true, "status": status] as [String: Any]
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
        let lines = interact.messages + interact.comm.drainMessages() + travel.messages
        interact.messages.removeAll()
        travel.messages.removeAll()
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
        if let line = interact.escorts.note(event: event, pilot: &pilot, world: world, game: game) {
            interact.messages.append(line)
        }
    }

    /// A world was (re)built: close the windows and bring the saved escort wing
    /// back around the player.
    private func interactionsWorldRebuilt() {
        interact.resetForNewWorld(system: currentSystemID)
        if let world, game != nil { interact.escorts.respawn(world: world, pilot: pilot) }
    }

    // MARK: Flight travel
    //
    // What the Apple app's `GameScene` + `GameContainerView` do around the travel
    // channel: the ship-target keys of the original's table (cycle ` / Shift-` /
    // Alt-`, R, Alt-R, Alt-N), the selected stellar (1–4, N, H) and the Nav panel
    // readout, the original's two-press landing with clearance (request, the 250 px
    // arm, "cleared to land", bribes and `MinStatus` refusals, landing fee), and
    // hypergate / wormhole travel (land on a gate → pick a destination; gates spend
    // no fuel and no days). Every rule is shared code: `World.cyclePlayerTarget` /
    // `selectNearestEngaged` / `selectNearestHostileThreat`, `PlayerLanding`,
    // `LandedServices.landingClearance` + `refusalMessage`, `OriginalText`,
    // `SpobRes.playerMayUseGate`, `NovaGame.gateDestinations` /
    // `wormholeExitCandidates`, `World.placePlayerEmergingFromGate`. This section
    // marshals and keeps the per-visit selection / clearance state (Flight.swift).

    private var travel = TravelState()

    private func beep(_ n: Int) {
        if let cue = SoundCues.beep(n) { sound.pending.append(cue) }
    }

    private func post(_ line: String, rawCalls: Int = 0) {
        if line.isEmpty { return }
        travel.messages.append(line)
        statusLine.note(line, rawCalls: rawCalls)   // a non-default display length (the buoy, a quote)
    }

    /// Bodies the player can approach to land on / use (`GameScene.isPlayerLandTarget`).
    private func landTargets() -> [StellarBody] {
        world?.systemContext.bodies.filter { $0.isLandable || $0.isGate } ?? []
    }

    private func stellarBody(_ id: Int) -> StellarBody? {
        world?.systemContext.bodies.first { $0.id == id }
    }

    private func nearestLandTarget() -> StellarBody? {
        guard let world else { return nil }
        let p = world.player.position
        return landTargets().min { ($0.position - p).length < ($1.position - p).length }
    }

    /// A stellar takes the travel channel, which the original shares with the armed
    /// hyperspace jump: a new selection disarms the jump (H re-arms it).
    private func selectStellar(_ id: Int) {
        if travel.selectedSpob != id { nav.route.disarm() }
        travel.selectedSpob = id
    }

    // MARK: Targets and the travel selection

    private func beepForNearestTarget(found: Ship?, was: Int?) {
        if found == nil { beep(4) } else if found?.entityID != was { beep(3) }   // 0x0044b120
    }

    /// ` / Shift-` / Alt-`: step the ship target (UI-07) — in arrival order, no
    /// wrap (past the last it clears to "No Target"), no range limit; `squad`
    /// cycles only the player's escorts. Sounds snd 152 whatever it lands on.
    /// Returns the new target's id or -1.
    @Callable(autoSnakeCase: true) func cycleTarget(reverse: Bool, squad: Bool) -> Int {
        beep(3)
        if plumbing.enhancements.nearestFirstTargeting {   // the port's nearest-first, wrapping, 3000 px cycle
            return world?.cycleNearestFirst(reverse: reverse)?.entityID ?? -1
        }
        return world?.cyclePlayerTarget(forward: !reverse, squad: squad)?.entityID ?? -1
    }

    /// Test seam: why each live NPC is or isn't on the plain `cycleTarget` list, as
    /// `[{id, name, onCycle, squad, cloaked, hullFlags2}]`.
    @Callable(autoSnakeCase: true) func debugCycleCandidates() -> String {
        guard let world else { return "[]" }
        let on = Set(world.playerCycleCandidates(squad: false).map { $0.entityID })
        return Self.json(world.npcs.filter { $0.isAlive }.map {
            ["id": $0.entityID, "name": $0.name, "onCycle": on.contains($0.entityID),
             "squad": world.isInPlayerSquad($0), "cloaked": $0.isEffectivelyCloaked,
             "hullFlags2": $0.hullFlags2] as [String: Any]
        })
    }

    /// Alt-R: the nearest ship outside the player's squad, no range limit (0x00462850).
    @Callable(autoSnakeCase: true) func selectNearestEngaged() -> Int {
        let was = world?.player.currentTargetID
        let found = plumbing.enhancements.nearestFirstTargeting ? world?.selectNearestTarget(hostileOnly: false)
                                                                : world?.selectNearestEngaged()
        beepForNearestTarget(found: found, was: was)
        return found?.entityID ?? -1
    }

    /// R: the nearest ship attacking the player's squad, not disabled, no range
    /// limit (0x00462bd0).
    @Callable(autoSnakeCase: true) func selectNearestHostileThreat() -> Int {
        let was = world?.player.currentTargetID
        let found = plumbing.enhancements.nearestFirstTargeting ? world?.selectNearestTarget(hostileOnly: true)
                                                                : world?.selectNearestHostileThreat()
        beepForNearestTarget(found: found, was: was)
        return found?.entityID ?? -1
    }

    /// Alt-N: clear the ship target (snd 150 when there was one).
    @Callable(autoSnakeCase: true) func clearShipTarget() {
        if world?.player.currentTargetID != nil { beep(1) }
        world?.clearPlayerTarget()
    }

    /// N: the original's clear command — the travel selection (a selected stellar
    /// and an armed jump); snd 150.
    @Callable(autoSnakeCase: true) func clearTravelSelection() {
        beep(1)
        travel.selectedSpob = nil
        nav.route.disarm()
    }

    /// S: clear the secondary weapon selection (snd 152 when one was selected).
    @Callable(autoSnakeCase: true) func clearSecondaryWeapon() {
        guard let player = world?.player else { return }
        if player.selectedSecondaryID != nil { beep(3) }
        player.clearSecondary()
    }

    /// 1–4: the current system's first four nav stellars (snd 150). False when the
    /// system has no such stellar.
    @Callable(autoSnakeCase: true) func selectNavStellar(index: Int) -> Bool {
        guard let game, let sys = game.system(currentSystemID ?? -1), index >= 0, index < sys.spobs.count,
              stellarBody(sys.spobs[index]) != nil else { return false }
        beep(1)
        selectStellar(sys.spobs[index])
        return true
    }

    /// The selected stellar's `spöb` id, or -1.
    @Callable(autoSnakeCase: true) func selectedStellarID() -> Int { travel.selectedSpob ?? -1 }

    /// Test seam: select stellar `id` without the key's beep.
    @Callable(autoSnakeCase: true) func debugSelectStellar(id: Int) -> Bool {
        guard stellarBody(id) != nil else { return false }
        selectStellar(id)
        return true
    }

    /// H: the travel channel goes back to hyperspace, re-arming the plotted route's
    /// next hop (`StarMapRoute.selectHyperspace`).
    @Callable(autoSnakeCase: true) func hyperspaceArm() {
        travel.selectedSpob = nil
        guard let cur = currentSystemID, let nv = navigator() else { return }
        refreshNavVisibility()
        nav.route.selectHyperspace(current: cur, linked: nv.isLinked)
    }

    /// `\` (slot 0x0d; 0x0044b120): step the armed hyperspace link through the current
    /// system's links, wrapping, and arm it (snd 152). False without links.
    @Callable(autoSnakeCase: true) func cycleHyperspaceLink(forward: Bool) -> Bool {
        guard let cur = currentSystemID, let nv = navigator() else { return false }
        refreshNavVisibility()
        guard nav.route.cycleLink(links: nv.visibleNeighbors(cur), current: cur, forward: forward,
                                  linked: nv.isLinked) else { return false }
        beep(3)
        return true
    }

    /// The map window closed: the route head re-syncs (0x004a4fd0 → 0x004a8080).
    @Callable(autoSnakeCase: true) func navMapClosed() {
        guard let cur = currentSystemID, let nv = navigator() else { return }
        nav.route.sync(current: cur, linked: nv.isLinked)
    }

    /// The original Nav panel (0x0045e400; UI-10) as `[title, name, dim]`:
    /// "Hyperspace" (#345) with the armed next hop (dimmed until clear of the
    /// no-jump zone with a jump of fuel; "Unexplored System" #346 before it has been
    /// visited), "Hyperspace" / "No Destination" (#344) in travel mode 3 with
    /// nothing armed, "Stellar Navigation" (#343) with the selected stellar, else
    /// "Nav System Off" (#342). `dim` is "1" or "0".
    @Callable(autoSnakeCase: true) func navReadout() -> PackedStringArray {
        guard let game, let world else { return PackedStringArray() }
        let text = OriginalText(game: game)
        var hopName = ""
        if let hop = nav.route.hops.first, let sys = game.system(hop) {
            let known = pilot.exploredSystems.contains(hop) || (pilot.chartedSystems ?? []).contains(hop)
            hopName = known ? sys.displayName : text.misc(346)
        }
        if nav.route.armed, travel.selectedSpob == nil, !hopName.isEmpty {
            let radius = galaxy.map { PilotEconomy.hyperspaceNoJumpRadius(pilot, galaxy: $0) } ?? 1000
            let ready = world.isClearOfNoJumpZone(radius: radius) && world.player.fuel >= ShipFuel.perJump
            return PackedStringArray([text.misc(345), hopName, (!ready && world.playerJump == nil) ? "1" : "0"])
        } else if nav.route.hyperspaceMode, travel.selectedSpob == nil {
            return PackedStringArray([text.misc(345), text.misc(344), "0"])
        } else if let id = travel.selectedSpob {
            return PackedStringArray([text.misc(343), game.spob(id)?.displayName ?? text.misc(344), "0"])
        }
        return PackedStringArray([text.misc(342), "", "0"])
    }

    // MARK: Landing (the original's two presses)

    /// Why a second Land press on `id` cannot set down (UI-08): cloaked, or the
    /// original's too-fast / too-far split — too fast only when already cleared and
    /// inside the envelope, too far otherwise.
    private enum LandingProblem { case cloaked, tooFast, tooFar }

    private func landingProblem(_ id: Int) -> LandingProblem? {
        guard let p = world?.player, let body = stellarBody(id) else { return .tooFar }
        if p.isEffectivelyCloaked { return .cloaked }
        if canLand(on: body, p) { return nil }
        let d = body.position - p.position
        let rules = plumbing.landingRules
        let reach = rules.reach(radius: body.radius)
        let inside = abs(d.x) < reach && abs(d.y) < reach
        let slow = abs(p.velocity.x) <= rules.speedLimit && abs(p.velocity.y) <= rules.speedLimit
        let cleared = travel.cleared.contains(id)
        if (!cleared || !slow) && inside && cleared { return .tooFast }
        return .tooFar
    }

    /// Whether `p` may set down on `body` right now: inside the square envelope,
    /// under the per-axis speed limit, cleared, and not cloaked.
    private func canLand(on body: StellarBody, _ p: Ship) -> Bool {
        plumbing.landingRules.canLand(offset: body.position - p.position, radius: body.radius, velocity: p.velocity,
                                      cleared: travel.cleared.contains(body.id), cloaked: p.isEffectivelyCloaked)
    }

    /// The spöb to land on if the player may set down this instant: the selected one.
    private func attemptLandSelected() -> Int? {
        guard let id = travel.selectedSpob, let p = world?.player, p.isAlive, let body = stellarBody(id),
              body.isLandable || body.isGate, canLand(on: body, p) else { return nil }
        return id
    }

    private func landingRefusalReason(_ spob: SpobRes) -> String? {
        guard let game, let galaxy else { return nil }
        // `spöb.Flags` 0x0080 ("Can only land when destroyed"): a hidden base whose
        // cover has to be blown off first — checked before every other gate.
        if spob.landableOnlyWhenDestroyed, !pilot.isStellarDestroyed(spob.id) {
            return "There is nowhere to land here."
        }
        let clearance = LandedServices.landingClearance(
            spob: spob, system: currentSystemID ?? -1, state: pilot, game: game,
            diplomacy: galaxy.makeDiplomacy(), contributedBits: game.contributedBits(pilot: pilot),
            bribed: interact.comm.bribedStellars.contains(spob.id))
        return LandedServices.refusalMessage(clearance, spob: spob, game: game)
    }

    /// Whether the player is cleared to use hypergate `id` (wormholes always pass).
    private func playerMayUseGate(_ id: Int) -> Bool {
        guard let spob = game?.spob(id), let world else { return false }
        let dip = world.diplomacy
        return spob.playerMayUseGate(standing: dip?.reputationHere ?? 0,
                                     hostile: dip?.isHostileToPlayer(spob.government) ?? false,
                                     allied: dip?.areAllied(spob.government, world.player.government) ?? false)
    }

    /// Per `step`: reaching ±250 px of the stellar a landing was requested from
    /// grants clearance and sounds the clearance line (0x00459950).
    private func tickTravel() {
        guard let world, dockedSpobID == nil, world.player.isAlive else { return }
        if plumbing.enhancements.forgivingLanding {
            // `forgivingLanding`: every body arms on approach, silently (Apple `updateLanding`).
            for body in landTargets() where PlayerLanding.inClearanceRange(offset: body.position - world.player.position) {
                travel.cleared.insert(body.id)
            }
            return
        }
        guard let request = travel.landingRequest, !travel.cleared.contains(request),
              let body = stellarBody(request) else { return }
        if PlayerLanding.inClearanceRange(offset: body.position - world.player.position) {
            travel.cleared.insert(request)
            postLandingClearance(request)
        }
    }

    /// "Cleared to land" and its variants, then "Commence final approach." or
    /// "Welcome to <stellar>.", and the landing fee when one is due.
    private func postLandingClearance(_ id: Int) {
        guard let game, let spob = game.spob(id), !spob.isUninhabited || spob.isGate else { return }
        let fee = pilot.hasDominated(id) ? 0 : spob.landingFee
        beep(2)   // NovaUi_UpdateTravelEngagementProgress 0x00459950
        post(OriginalText(game: game).landingClearance(
            body: OriginalText.Body(spob), stellar: spob.displayName, pilot: pilot.pilotName, fee: fee) { Int.random(in: 0..<$0) },
             rawCalls: OriginalText.Duration.landing)
    }

    /// The land hint for the nearest approachable stellar in reach, as `[kind, name]`
    /// with kind `land` ("Press L to land on X"), `request` ("…to request landing on
    /// X"), `slowDown` or `none` — `PlayerLanding.prompt`, as the HUD shows it.
    @Callable(autoSnakeCase: true) func landPrompt() -> PackedStringArray {
        guard let world, let game, dockedSpobID == nil, world.player.isAlive, let near = nearestLandTarget(),
              plumbing.landingRules.inReach(offset: near.position - world.player.position, radius: near.radius)
        else { return PackedStringArray(["none", ""]) }
        let p = world.player
        let canNow = !world.playerInEscapePod && canLand(on: near, p)
        let forgiving = plumbing.enhancements.forgivingLanding
        let prompt = PlayerLanding.prompt(canLandNow: canNow, slowEnough: plumbing.landingRules.isSlowEnough(p.velocity),
                                          needsRequest: !forgiving && !travel.cleared.contains(near.id), cloaked: p.isEffectivelyCloaked)
        let name = game.spob(near.id)?.displayName ?? ""
        switch prompt {
        case .land: return PackedStringArray(["land", name])
        case .request: return PackedStringArray(["request", name])
        case .slowDown: return PackedStringArray(["slowDown", name])
        case .none: return PackedStringArray(["none", ""])
        }
    }

    /// The Land key (0x00457580; UI-08). With nothing selected the nearest approachable
    /// stellar is selected first. The first press on the selected stellar requests
    /// clearance — a denied stellar says so (#81–83, or the fee line #61–64) and drops
    /// the selection, an uninhabited one answers "No response." (#53) and is cleared
    /// at once, any other gets a request line unless the ship is already inside 250 px
    /// — and the clearance line follows on reaching 250 px. The second press lands,
    /// or says why not: cloaked (#73), too fast (#69–72), too far (#65–68). A bribe
    /// accepted from the comm window clears a refused stellar. Landing on a gate uses
    /// it. JSON `{result: none | messages | landed | gate | transported, spob, name}`;
    /// the lines are in `drain_interaction_messages`.
    @Callable(autoSnakeCase: true) func pressLand() -> String {
        guard let world, let game, dockedSpobID == nil, world.playerJump == nil, travel.gatePicker == nil,
              world.player.isAlive else { return landJSON("none") }
        if travel.selectedSpob == nil, let near = nearestLandTarget() { selectStellar(near.id) }
        if plumbing.autoLanding || plumbing.enhancements.forgivingLanding {
            return settingsPressLand(world)   // Settings: auto-landing / forgiving landing replace the two presses
        }
        guard let id = travel.selectedSpob, let spob = game.spob(id) else { return landJSON("none") }
        let text = OriginalText(game: game)
        let kind = OriginalText.Body(spob)
        if pilot.destroyedStellars?.contains(id) == true, !spob.landableOnlyWhenDestroyed {
            beep(4)
            post(text.unableToLand(body: kind, stellar: spob.displayName), rawCalls: OriginalText.Duration.landing)
            return landJSON("messages")
        }
        if landingProblem(id) == .cloaked {
            beep(4)
            post(text.misc(73), rawCalls: OriginalText.Duration.landing)
            return landJSON("messages")
        }
        guard travel.landingRequest == id else {
            // First press: the request.
            if spob.isUninhabited && !spob.isGate {
                beep(1)   // 0x00459950: the "No response." line sounds snd 150
                post(text.misc(53), rawCalls: OriginalText.Duration.landing)
                travel.landingRequest = id
                travel.cleared.insert(id)
                if let land = attemptLandSelected() { return requestLanding(land) }
                return landJSON("messages")
            }
            // Clearance reads the per-system reputation: fold in this session's crimes first (EC-02).
            syncLiveStanding()
            let refusal = spob.isGate ? nil : landingRefusalReason(spob)
            let denied = spob.isGate ? !(spob.isWormhole || playerMayUseGate(id)) : refusal != nil
            if denied {
                beep(2)
                post(refusal ?? text.landingDenied(body: kind), rawCalls: OriginalText.Duration.landing)
                travel.selectedSpob = nil
                return landJSON("messages")
            }
            travel.landingRequest = id
            if let body = stellarBody(id), PlayerLanding.inClearanceRange(offset: body.position - world.player.position) {
                return landJSON("messages")   // the clearance line follows on the next tick
            }
            beep(2)
            post(text.landingRequest(body: kind, stellar: spob.displayName, pilot: pilot.pilotName) { Int.random(in: 0..<$0) }, rawCalls: OriginalText.Duration.landing)
            return landJSON("messages")
        }
        // Second press: land, or say why not.
        if let land = attemptLandSelected() { return requestLanding(land) }
        beep(4)
        switch landingProblem(id) {
        case .tooFast?: post(text.tooFast(body: kind), rawCalls: OriginalText.Duration.approach)
        case .cloaked?: post(text.misc(73), rawCalls: OriginalText.Duration.landing)
        default: post(text.tooFar(body: kind), rawCalls: OriginalText.Duration.approach)
        }
        return landJSON("messages")
    }

    private func landJSON(_ result: String, spob: Int = -1) -> String {
        Self.json(["result": result, "spob": spob, "name": game?.spob(spob)?.displayName ?? ""] as [String: Any])
    }

    /// Commit a landing the second press allowed: a gate is used rather than docked
    /// with; a refusal that still stands (a bribe that lapsed, a destroyed stellar)
    /// says so.
    private func requestLanding(_ id: Int, confirmed: Bool = false) -> String {
        guard let game, let spob = game.spob(id) else { return landJSON("none") }
        if pilot.destroyedStellars?.contains(id) == true, !spob.landableOnlyWhenDestroyed {
            post("Nothing but wreckage remains.")
            return landJSON("messages")
        }
        if spob.isGate { return handleGateLanding(spob) }
        if let reason = landingRefusalReason(spob) {
            post(reason)
            return landJSON("messages")
        }
        if plumbing.confirmLanding, !confirmed {
            plumbing.pendingLandConfirm = id   // Settings > Confirm landing: "Land here?" first
            return landJSON("confirm", spob: id)
        }
        plumbing.pendingLandConfirm = nil
        touchDown(spobID: id, chargeFee: true)
        return landJSON("landed", spob: id)
    }

    // MARK: Hypergates and wormholes

    /// Landing on a gate. A wormhole flings you through (no choice); a hypergate
    /// you're cleared for opens its destination picker; one you aren't refuses.
    private func handleGateLanding(_ spob: SpobRes) -> String {
        guard let game else { return landJSON("none") }
        if spob.isWormhole { return beginWormholeTransport(from: spob) }
        if playerMayUseGate(spob.id) {
            // A gate with no links does nothing: `Stellar_EnterHypergate` 0x00456480
            // returns -1 with no message or beep.
            guard !game.gateDestinations(from: spob).isEmpty else { return landJSON("none") }
            travel.openGates.insert(spob.id)
            travel.gatePicker = spob.id
            return landJSON("gate", spob: spob.id)
        }
        beep(2)   // 0x00457580: snd 151 + STR# 2002 #81
        post(OriginalText(game: game).misc(81))
        return landJSON("messages")
    }

    /// A wormhole spits you out at a visible linked wormhole, or a random other
    /// link-less one if it has no links (OS-06); no choice, no exit = "Unable to use".
    private func beginWormholeTransport(from wormhole: SpobRes) -> String {
        guard let game else { return landJSON("none") }
        let story = StoryEngine(game: game, player: pilot)
        let exits = game.wormholeExitCandidates(from: wormhole, currentSystem: currentSystemID,
                                                isVisible: { story.isSystemVisible($0) })
        guard let dest = exits.randomElement() else {
            beep(4)   // Stellar_EnterWormhole 0x00456ca0
            post(OriginalText(game: game).misc(84) + " " + OriginalText(game: game).misc(86))
            return landJSON("messages")
        }
        travel.openGates.insert(wormhole.id)
        return transportThroughGate(destSystem: dest.systemID, destGate: dest.gateSpobID)
            ? landJSON("transported", spob: dest.gateSpobID) : landJSON("none")
    }

    /// The hypergate picker, or `{}`: `{gate, name, here, destinations: [{gate, system,
    /// name, x, y}]}`. Destinations are always shown — using a gate bypasses fog of war.
    @Callable(autoSnakeCase: true) func gatePickerState() -> String {
        guard let game, let gateID = travel.gatePicker, let gate = game.spob(gateID) else { return "{}" }
        let dests = game.gateDestinations(from: gate, hidden: game.hiddenSystemIDs(for: pilot)).compactMap { d -> [String: Any]? in
            guard let s = game.system(d.systemID) else { return nil }
            return ["gate": d.gateSpobID, "system": d.systemID, "name": s.displayName, "x": s.x, "y": s.y]
        }
        let here = game.system(currentSystemID ?? -1)
        return Self.json(["gate": gateID, "name": gate.displayName, "here": currentSystemID ?? -1,
                          "prompt": OriginalText(game: game).misc(340),
                          "hereX": here?.x ?? 0, "hereY": here?.y ?? 0, "destinations": dests] as [String: Any])
    }

    @Callable(autoSnakeCase: true) func gatePickerOpen() -> Bool { travel.gatePicker != nil }

    /// Leave the picker without travelling.
    @Callable(autoSnakeCase: true) func gatePickerCancel() { travel.gatePicker = nil }

    /// Travel through the open gate to the destination whose far gate is `destGate`.
    /// False if the picker isn't open or the gate isn't one of its destinations.
    @Callable(autoSnakeCase: true) func gatePickerChoose(destGate: Int) -> Bool {
        guard let game, let gateID = travel.gatePicker, let gate = game.spob(gateID),
              let dest = game.gateDestinations(from: gate, hidden: game.hiddenSystemIDs(for: pilot))
                  .first(where: { $0.gateSpobID == destGate }) else { return false }
        travel.gatePicker = nil
        return transportThroughGate(destSystem: dest.systemID, destGate: dest.gateSpobID)
    }

    /// Hypergate / wormhole connections between known systems (`spöb` HyperLink1-8,
    /// each gate mapped to its containing system; undirected, deduped; a wormhole
    /// whose links are all random contributes nothing), as `[a, b, wormhole]` triples.
    /// The original draws these spokes only in the gate picker; the map shows them
    /// everywhere only as the opt-in "gate links" enhancement.
    @Callable(autoSnakeCase: true) func navGateLinks() -> PackedInt32Array {
        guard let game, let nv = navigator() else { return PackedInt32Array() }
        let known = knownSets()
        let adjacent = nv.adjacentToKnown(explored: known.explored, charted: known.charted)
        func shown(_ id: Int) -> Bool {
            StarMapNavigator.visibility(of: id, explored: known.explored, adjacent: adjacent, charted: known.charted) != .unknown
        }
        var spobSystem: [Int: Int] = [:]
        let systems = game.systems()
        for s in systems { for sp in s.spobs { spobSystem[sp] = s.id } }
        var seen = Set<Int>()
        var flat: [Int32] = []
        for s in systems where !nav.hidden.contains(s.id) {
            for sp in s.spobs {
                guard let gate = game.spob(sp), gate.isGate else { continue }
                for target in gate.hyperLinks {
                    guard let other = spobSystem[target], other != s.id, !nav.hidden.contains(other) else { continue }
                    let a = s.id, b = other
                    guard shown(a), shown(b) else { continue }
                    if seen.insert(min(a, b) * 100_000 + max(a, b)).inserted {
                        flat += [Int32(a), Int32(b), gate.isWormhole ? 1 : 0]
                    }
                }
            }
        }
        return PackedInt32Array(flat)
    }

    /// The nebulae the map draws (0x004a51f0), as JSON `[{id, x, y, w, h, picts}]`:
    /// by default only active ones the player has explored; `all` = every nebula
    /// (the opt-in enhancement look). `picts` are the seven zoom-level PICT ids,
    /// smallest first, then the full-size fallback (`NovaGame.nebulaImageID`).
    @Callable(autoSnakeCase: true) func navNebulae(all: Bool) -> String {
        guard let game else { return "[]" }
        let drawn = all ? nil : storyEngine()?.exploredActiveNebulaIDs()
        let rows = game.nebulae().compactMap { neb -> [String: Any]? in
            if let drawn, !drawn.contains(neb.id) { return nil }
            let base = 9500 + 7 * (neb.id - 128)
            let variants = (0..<7).map { base + $0 }.filter { game.hasPICT($0) }
            let full = [game.nebulaImageID(index: neb.id - 128), game.nebulaImageID(index: neb.id - 128) - 1,
                        game.nebulaImageID(index: neb.id - 128) - 2].first { game.hasPICT($0) }
            guard !variants.isEmpty || full != nil else { return nil }
            return ["id": neb.id, "x": neb.x, "y": neb.y, "w": neb.width, "h": neb.height,
                    "picts": variants, "full": full ?? -1]
        }
        return Self.json(rows)
    }

    /// The map's Find (`StarMapFind.find`, 0x004aab30): the known system (visited,
    /// revealed or charted) whose name shares the longest prefix with `query`, or -1
    /// (a beep). A hit selects it (never arms or plots) and sounds snd 154, a miss
    /// snd 153.
    @Callable(autoSnakeCase: true) func navFind(query: String) -> Int {
        guard let game else { return -1 }
        let known = game.systems().filter { !nav.hidden.contains($0.id) && pilot.isSystemExplored($0.id) }
        if let id = StarMapFind.find(query, in: known.map { ($0.id, $0.displayName) }) {
            nav.selected = id
            beep(5)
            return id
        }
        beep(4)
        return -1
    }

    /// Whether hypergate `id` has been switched on this visit (a landing lights it).
    @Callable(autoSnakeCase: true) func gateIsOpen(id: Int) -> Bool { travel.openGates.contains(id) }

    /// The gate transport (`NovaTravel_CompleteRestrictedTravel`, OS-06): spend **no**
    /// fuel and **no** days, need no hyperspace link, rebuild the destination reusing
    /// the player's ship (damage/cargo carry), put it on the far gate on that gate's
    /// emergence angle at half top speed, bring the escort wing out of the same gate
    /// with its damage, and arrive with the Warp out sound. The frontend sees the
    /// arrival through `take_jump_arrival`, as for a hyperjump.
    private func transportThroughGate(destSystem: Int, destGate: Int) -> Bool {
        guard let world, let game, let galaxy, dockedSpobID == nil, world.playerJump == nil else { return false }
        let ship = world.player
        storyLeavingSystem()
        let abandonedFighters = world.returnJumpingFighters()
        interact.messages += interact.escorts.carryThroughJump(world: world, pilot: &pilot, game: game, via: .gate(destGate))
        pilot.cargo = ship.cargo
        pilot.fuel = ship.fuel
        storyBindHooks()
        let engine = StoryEngine(game: game, player: pilot, services: storyState.services)
        engine.playerJumped(toSystem: destSystem, via: [])
        if !engine.player.activeMissions.isEmpty { engine.missionFlightPass() }
        pilot = engine.player

        let (w, _) = makeConfiguredWorld(game: game, systemID: destSystem, player: ship, galaxy: galaxy)
        if let gate = w.systemContext.bodies.first(where: { $0.id == destGate }) {
            w.placePlayerEmergingFromGate(gate)
        } else {
            w.placePlayerAtHyperspaceArrival(bearing: ship.angle)
        }
        ship.currentTargetID = nil
        ship.wantsToDepart = false
        self.world = w
        self.intent = ControlIntent()
        currentSystemID = destSystem
        pilot.currentSystem = destSystem
        nav.pending = nil
        nav.selected = nil
        refreshNavVisibility()
        if let nv = navigator() { nav.route.arriveViaGate(at: destSystem, linked: nv.isLinked) }
        nav.arrivedIn = game.system(destSystem)?.displayName ?? ""
        resetFrameState()
        postArrivalLine(systemID: destSystem, gateID: destGate, abandonedFighters: abandonedFighters)
        travel.openGates.insert(destGate)          // the arrival gate glows as you pop out
        sound.pending.append(SoundCues.hyperspaceArrive)   // gate travel plays only Warp out
        return true
    }

    /// Test seam: how many death-burst sound cues have been raised so far, and a way
    /// to start one for `entityID` heard from the player's position.
    @Callable(autoSnakeCase: true) func debugDeathCuesEmitted() -> Int { sound.deathCuesEmitted }
    @Callable(autoSnakeCase: true) func debugBeginDeathBursts(entityID: Int, boomID: Int) {
        sound.deaths.begin(entityID: entityID, at: world?.player.position ?? Vec2(), boomID: boomID, game: game)
    }
    /// A bööm id whose sound exists, or -1 (for the test above).
    @Callable(autoSnakeCase: true) func debugBoomWithSound() -> Int {
        (128...1100).first { game?.boom($0)?.soundID != nil } ?? -1
    }

    /// Test seam: the escorts' state for the carry-across-a-jump check, as JSON
    /// `[{record, entity, shield, armor}]` (fractions of the hull's maximum) in the live wing.
    @Callable(autoSnakeCase: true) func debugEscortStates() -> String {
        guard let world else { return "[]" }
        return Self.json(world.playerEscorts.map {
            ["record": $0.escortRecordID ?? -1, "entity": $0.entityID,
             "shield": $0.shieldFraction, "armor": $0.armorFraction] as [String: Any]
        })
    }

    /// Test seam: hire a `shipType` escort into the roster and bring it out beside the
    /// player. Returns its record id, or -1.
    @Callable(autoSnakeCase: true) func debugAddEscort(shipType: Int) -> Int {
        guard let world, game?.ship(shipType) != nil else { return -1 }
        let rec = pilot.registerEscort(shipType: shipType, name: "Test escort", origin: .hired, hireFee: 0, dailyFee: 0)
        interact.escorts.respawn(world: world, pilot: pilot)
        return rec.id
    }

    /// Test seam: candidate (system, stellar) pairs for a refused landing — inhabited
    /// stellars owned by a government with a positive `MinStatus` — as a flat list.
    @Callable(autoSnakeCase: true) func debugRefusedStellars() -> PackedInt32Array {
        guard let game else { return PackedInt32Array() }
        var flat: [Int32] = []
        for spob in game.spobs() where spob.isLandable && !spob.isUninhabited && !spob.isGate
            && spob.government >= 128 && spob.minStatus > 0 && spob.minStatus < 32767 && spob.landingFee == 0 {
            if let sys = game.systemContaining(spob: spob.id) { flat += [Int32(sys), Int32(spob.id)] }
            if flat.count >= 80 { break }
        }
        return PackedInt32Array(flat)
    }

    /// Test seam: set the player's legal record in the current system (a stock
    /// hypergate needs positive standing with its owner).
    @Callable(autoSnakeCase: true) func debugSetReputation(value: Int) {
        world?.diplomacy?.setReputationHere(value)
    }

    /// Test seam: (system, gate) pairs of hypergates (`wormhole` false) or wormholes
    /// (true), with the first destination `(system, gate)` after.
    @Callable(autoSnakeCase: true) func debugGates(wormhole: Bool) -> PackedInt32Array {
        guard let game else { return PackedInt32Array() }
        var flat: [Int32] = []
        for spob in game.spobs() where spob.isGate && spob.isWormhole == wormhole {
            guard let sys = game.systemContaining(spob: spob.id) else { continue }
            let dests = wormhole ? game.wormholeExitCandidates(from: spob, currentSystem: sys)
                                 : game.gateDestinations(from: spob)
            if let d = dests.first { flat += [Int32(sys), Int32(spob.id), Int32(d.systemID), Int32(d.gateSpobID)] }
            if flat.count >= 40 { break }
        }
        return PackedInt32Array(flat)
    }

    /// Test seam: knock `fraction` (0…1) off every live escort's armor and shield.
    @Callable(autoSnakeCase: true) func debugDamageEscorts(fraction: Double) {
        for s in world?.playerEscorts ?? [] {
            s.armor = s.maxArmor * (1 - fraction)
            s.shield = s.maxShield * (1 - fraction)
        }
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
            let (w, _) = makeConfiguredWorld(game: game, systemID: target, player: ship, galaxy: galaxy)
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
            let (w, _) = makeConfiguredWorld(game: game, systemID: sysID, player: player, galaxy: galaxy)
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
        if ok { gapsPersOfferAccepted(offer, engine: engine) }   // a përs's flags: leave / never again / replaced
        gaps.persOfferPerson = nil
        autosave(.event)
        storyState.services.pendingOffer = nil
        storyState.inlineOffer = false
        return ok
    }

    @Callable(autoSnakeCase: true) func offerDecline() {
        guard let offer = storyState.services.pendingOffer, let engine = storyEngine() else { return }
        engine.decline(offer.mission.id)
        storyCommit(engine)
        gaps.persOfferPerson = nil
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
                          "hire": buttonLabel(13, "Hire Escort"), "canHire": PilotEconomy.canAddEscort(pilot),
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
        syncLiveStanding()   // a kill a moment ago must show in the rating
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
    /// show ("Cargo jettisoned.", STR# 2002 #289) or "". The floating pods are
    /// freeflight objects (`freeflight_transforms`).
    @Callable(autoSnakeCase: true) func jettisonCargo() -> String {
        guard let game, let engine = storyEngine() else { return "" }
        let docked = dockedSpobID != nil
        let thrown = engine.jettisonCargo(docked: docked)
        storyCommit(engine)
        world?.player.cargo = pilot.cargo
        autosave(.event)
        if !docked, thrown.total > 0 { gapsSpawnJettisonPods(total: thrown.total, ordinaryTotal: thrown.ordinaryTotal) }
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

    // MARK: Story Map (Story Guide)
    //
    // The Apple Story Guide, minus SwiftUI: `StorylineAnalyzer.storyMap(for:)` over the
    // live pilot, built on a background queue (`StoryMapState`), each lane linearized by
    // the shared `StoryGuideLogic.flow` (NovaSwiftStory/StoryFlowLayout.swift, the same
    // code `StoryGuideModel` calls). GDScript side: godot/screens/StoryGuide.gd.
    // Poll `story_map_ready()` after `story_map_begin()`; the previous map stays readable
    // while a rebuild runs.

    private var storyMapState = StoryMapState()

    /// Start (or restart) the background build for the current pilot.
    @discardableResult
    @Callable(autoSnakeCase: true) func storyMapBegin() -> Bool {
        guard let game else { return false }
        storyMapState.begin(game: game, player: pilot)
        return true
    }

    /// True once a map exists and no build is outstanding.
    @Callable(autoSnakeCase: true) func storyMapReady() -> Bool {
        storyMapState.hasMap && !storyMapState.isBuilding
    }

    /// `{lanes:[{key,title,done,total,complete,govt,govtName,color,plugin,current,
    /// currentName,currentStatus}], untagged}`.
    @Callable(autoSnakeCase: true) func storyMapLanes() -> String {
        guard let game else { return "{\"lanes\":[],\"untagged\":0}" }
        return Self.json(storyMapState.lanesJSON(game: game))
    }

    /// One storyline's flow rows: `[{id,name,step,status,depth,connector,current,objective,
    /// reward,offeredAt,synopsis,govt,govtName,blockers,jumps,cross,deadEnds,canAbort}]`.
    @Callable(autoSnakeCase: true) func storyFlow(key: String) -> String {
        guard let game else { return "[]" }
        return Self.json(storyMapState.flowJSON(key: key, game: game, player: pilot))
    }

    /// The mission's storyline tag `{key,title}`, or "" (untagged, or the tag table is
    /// still prewarming -- the first call starts that; see `story_tags_ready`).
    @Callable(autoSnakeCase: true) func storyTag(missionId: Int) -> String {
        guard let game, let t = storyMapState.tag(forMission: missionId, game: game) else { return "" }
        return Self.json(["key": t.key, "title": t.title])
    }

    @Callable(autoSnakeCase: true) func storyTagsReady() -> Bool { storyMapState.tagsReady }

    /// Test aid: set / clear a control bit on the live pilot.
    @Callable(autoSnakeCase: true) func debugSetBit(bit: Int, on: Bool) {
        if on { pilot.setBit(bit) } else { pilot.clearBit(bit) }
    }

    /// Test aid: start mission `id` and complete it as if its objective were done
    /// (runs OnAccept / OnSuccess scripts, marks it completed).
    @Callable(autoSnakeCase: true) func debugCompleteMission(id: Int) -> Bool {
        guard let engine = storyEngine() else { return false }
        engine.startMission(id)
        engine.completeMission(id)
        storyCommit(engine)
        return pilot.completedMissions.contains(id)
    }

    // MARK: Flight visuals
    //
    // Per-ship overlay state (shän layers), animated + destroyed stellars, weapon visual specs and the
    // target reticle for the Godot flight renderer (godot/flight/). The rules are the Apple Classic
    // path's own (HullAnimConfig / ShieldFlare / StellarAnimator / MurkFog -- see FlightVisuals.swift);
    // GDScript only draws what these return.

    /// Advance once per display frame, after the sim ticks (as `GameScene.syncNPCs` runs on `frameDT`).
    private func advanceFlightVisuals(dt: Double) {
        guard let world = self.world else { return }
        flightVisuals.advance(world: world, game: game, dt: dt, playerThrusting: intent.thrust,
                              renderAngle: { self.renderAngle(of: $0) }, renderPosition: { self.renderPosition(of: $0) })
        flightVisuals.advanceStellars(world: world, game: game, systemID: currentSystemID, dt: dt,
                                      destroyed: pilot.destroyedStellars ?? [])
    }

    /// Test seam: bring a `shipType` NPC out of hyperspace 500 px from the player along the player's heading
    /// (mode 0 = jump-in, 1 = gate emergence at the first gate). Returns its entity id, or -1.
    @Callable(autoSnakeCase: true) func debugSpawnArrival(shipType: Int, mode: Int) -> Int {
        guard let world, let galaxy else { return -1 }
        let p = world.player
        let pos = Vec2(p.position.x + 500 * sin(p.angle), p.position.y + 500 * cos(p.angle))
        guard let ship = galaxy.makeShip(shipType, at: pos, angle: p.angle + .pi) else { return -1 }
        _ = mode
        return world.addNPC(ship, arrival: .hyperspace)
    }

    /// Floats per ship in `shipLayers()`.
    @Callable(autoSnakeCase: true) func shipLayerStride() -> Int { FlightVisuals.layerStride }

    /// Per live ship, SAME order as `shipTransforms()`, `shipLayerStride()` floats each:
    /// 0 base set, 1 heading frame within a set, 2 framesPerSet, 3 alt-layer set, 4 running-light alpha (0 = off),
    /// 5 weapon-glow alpha (0 = off), 6 shield-flare alpha (0 = off), 7 engine-glow alpha (0 = off), 8 disabled,
    /// 9 bank (+1 left / -1 right), 10 hull opacity (shän BaseTransp), 11-13 tint multiply rgb, 14 murk fog level 0-31,
    /// 15 blend factor 0-1 (murk / ionize / gate wash), 16-18 blend rgb, 19 gate-hidden, 20 gate-white,
    /// 21 ion intensity, 22 thrust (0 / 1 / 2 afterburner), 23 raw shield flare, 24 jump-in over-speed still
    /// braking (px/s), 25 gate emergence in progress.
    /// Overlay frame = `(set * framesPerSet + heading) % sheetFrameCount` (the original's Sprite_SetCurrentFrame wrap).
    @Callable(autoSnakeCase: true) func shipLayers() -> PackedFloat32Array {
        guard let world = self.world else { return PackedFloat32Array() }
        return PackedFloat32Array(flightVisuals.shipLayerRows(world: world))
    }

    /// Per stellar body, SAME order as `bodyTransforms()`: `[animation frame, destroyed (0/1), murk fog level]`.
    @Callable(autoSnakeCase: true) func stellarStates() -> PackedFloat32Array {
        PackedFloat32Array(flightVisuals.stellarRows)
    }

    /// Per live shot, SAME order as `projectileTransforms()`: `[wëap id, animFrame, heading degrees]`.
    @Callable(autoSnakeCase: true) func projectileExtra() -> PackedFloat32Array {
        guard let world = self.world else { return PackedFloat32Array() }
        var flat: [Float] = []
        flat.reserveCapacity(world.projectiles.count * 3)
        for shot in world.projectiles {
            flat.append(Float(shot.weaponID)); flat.append(Float(shot.animFrame)); flat.append(Float(shot.headingDegrees))
        }
        return PackedFloat32Array(flat)
    }

    /// Per live beam, SAME order as `beamSegments()`: the `wëap` id.
    @Callable(autoSnakeCase: true) func beamWeapons() -> PackedInt32Array {
        guard let world = self.world else { return PackedInt32Array() }
        return PackedInt32Array(world.activeBeams.map { Int32($0.weaponID) })
    }

    /// One weapon's visual spec (trail, smoke, hit sparks, lightning); see `FlightVisuals.weaponVisual`. Empty = unknown.
    @Callable(autoSnakeCase: true) func weaponVisual(weaponID: Int) -> PackedFloat32Array {
        PackedFloat32Array(flightVisuals.weaponVisual(weaponID, game: game))
    }

    /// Classic preferences the bridge needs: "Ship Animations" (no banking / animation sets when off) and
    /// "Reduce flashing" (steady exhaust).
    @Callable(autoSnakeCase: true) func setFlightOptions(shipAnimations: Bool, reduceFlashing: Bool) {
        flightVisuals.setShipAnimations(shipAnimations)
        flightVisuals.reduceFlashing = reduceFlashing
    }

    /// The ship target's reticle: `[x, y, hullRadius, class]` (class 0 threat, 1 other, 2 squad, 3 disabled --
    /// `cicn` 10008 + 4 * class + corner), render-interpolated; empty with no target.
    @Callable(autoSnakeCase: true) func targetReticle() -> PackedFloat32Array {
        guard let world = self.world, let tid = world.player.currentTargetID, let ship = world.ship(id: tid)
        else { return PackedFloat32Array() }
        let r = renderPosition(of: ship)
        let cls: Float
        switch world.reticleClass(of: ship) {
        case .threat: cls = 0
        case .other: cls = 1
        case .squad: cls = 2
        case .disabled: cls = 3
        }
        return PackedFloat32Array([Float(r.x), Float(r.y), Float(ship.radius), cls])
    }

    /// Whether the player has dominated stellar `id` (the nav cursor then uses cicn 10004-10007).
    @Callable(autoSnakeCase: true) func stellarDominatedVisual(id: Int) -> Bool {
        world?.dominatedStellars.contains(id) ?? false
    }

    /// The player's top speed (px/s), for the look-ahead camera's lead.
    @Callable(autoSnakeCase: true) func playerMaxSpeed() -> Double {
        guard let w = world else { return 0 }
        return w.player.stats.maxSpeed
    }

    /// A `cicn` as raw RGBA: `[w, h]` in `cicnInfo`, the pixels from `cicnRGBA`; empty if absent. Used for the
    /// target reticle (10008-10023), nav cursor (10000-10007) and smoke puffs (1000 + 8n).
    @Callable(autoSnakeCase: true) func cicnInfo(id: Int) -> PackedInt32Array {
        guard let d = flightVisuals.cicn(id, game: game) else { return PackedInt32Array() }
        return PackedInt32Array([Int32(d.surfaceWidth), Int32(d.surfaceHeight)])
    }

    @Callable(autoSnakeCase: true) func cicnRgba(id: Int) -> PackedByteArray {
        guard let d = flightVisuals.cicn(id, game: game) else { return PackedByteArray() }
        return PackedByteArray(d.rgba)
    }

    // MARK: Gameplay gaps
    //
    // What the Apple app does around hire / escorts / gambling / scans / përs
    // offers / the eject, cloak and self-destruct keys / click-to-select that the
    // earlier bridge sections didn't carry. Every rule is shared NovaSwiftStory
    // code (`EscortHire`, `RaceSession`, `ContrabandScan.scanPlayer`,
    // `FlightPersOffer`, `EscapePodRespawn`, `PilotEconomy` escort + junk
    // functions); this section resolves the docked spöb / live world and marshals.
    // GDScript side: godot/screens/BarScreens.gd (Hire Escort, Gamble), the Escorts
    // window in Interactions.gd, Main.gd (keys, click, pods).

    private var gaps = GapsState()

    // --- Hire Escort (the bar) ---

    /// The bar's Hire Escort browser (HireEscortView): `{ships: [{id, name, category,
    /// shield, armor, guns, turrets, price, perDay, description, pict, locked,
    /// canHire}], credits, hasRoom, labels{hire, done}}`.
    @Callable(autoSnakeCase: true) func hireList() -> String {
        guard let c = shopContext() else { return "{}" }
        let rows: [[String: Any]] = EscortHire.stock(game: c.game, spob: c.spob, state: pilot).map { s in
            let pict = c.game.shipPictID(for: s).flatMap { c.game.hasPICT($0) ? $0 : nil } ?? -1
            return ["id": s.id, "name": s.displayName, "category": EscortHire.categoryLabel(s.escortCategory),
                    "shield": s.shield, "armor": s.armor, "guns": s.maxGuns, "turrets": s.maxTurrets,
                    "price": EscortHire.price(s, state: pilot, spob: c.spob, galaxy: c.galaxy),
                    "perDay": s.escortDailyFee, "description": EscortHire.pilotDescription(s, game: c.game),
                    "pict": pict, "locked": !NCBTest(s.availBits).evaluate(pilot),
                    "canHire": EscortHire.canHire(s, state: pilot, spob: c.spob, galaxy: c.galaxy)]
        }
        return Self.json(["ships": rows, "credits": pilot.credits, "hasRoom": PilotEconomy.canAddEscort(pilot),
                          "labels": ["hire": buttonLabel(13, "Hire Escort"), "done": buttonLabel(5, "Done")]]
                         as [String: Any])
    }

    /// Hire ship `id` (must be on today's list): the price leaves the credits, the
    /// escort joins on takeoff. False if refused (not on offer, wing full, too poor).
    @discardableResult
    @Callable(autoSnakeCase: true) func hireEscort(id: Int) -> Bool {
        guard let c = shopContext(), let ship = c.game.ship(id),
              EscortHire.stock(game: c.game, spob: c.spob, state: pilot).contains(where: { $0.id == id })
        else { return false }
        return EscortHire.hire(&pilot, ship, spob: c.spob, galaxy: c.galaxy)
    }

    // --- Escorts window: Upgrade / Sell marks (processed leaving a shipyard) ---

    @discardableResult
    @Callable(autoSnakeCase: true) func escortRequestUpgrade(record: Int) -> Bool {
        guard let game else { return false }
        return PilotEconomy.requestEscortUpgrade(&pilot, recordID: record, game: game) != nil
    }

    @Callable(autoSnakeCase: true) func escortCancelUpgrade(record: Int) {
        PilotEconomy.cancelEscortUpgrade(&pilot, recordID: record)
    }

    @discardableResult
    @Callable(autoSnakeCase: true) func escortRequestSale(record: Int) -> Bool {
        PilotEconomy.requestEscortSale(&pilot, recordID: record)
    }

    @Callable(autoSnakeCase: true) func escortCancelSale(record: Int) {
        PilotEconomy.cancelEscortSale(&pilot, recordID: record)
    }

    /// Leaving a spaceport (`Player_ProcessEscortFleetAtStellar` 0x004229d0, EC-22,
    /// then one payroll period, EC-20): marked sales and upgrades at a shipyard
    /// stellar — one text reports them — then the hired escorts' daily fees.
    private func gapsDeparting(from spobID: Int) {
        guard let game, let spob = game.spob(spobID) else { return }
        let disabled = Set(world?.playerEscorts.filter(\.disabled).compactMap(\.escortRecordID) ?? [])
        let pass = PilotEconomy.processEscortFleetAtStellar(&pilot, spob: spob, game: game, disabled: disabled)
        if pass.transactions > 0 {
            visitDays.escortsSoldOrUpgraded += pass.transactions
            storyState.services.showStoryText(PilotEconomy.escortFleetPassText(pass, game: game), title: "")
        }
        gapsPayEscorts(periods: 1)
    }

    /// Escort payroll (EC-20): `periods` periods — one per spaceport visit, the
    /// travel days per jump. An unpaid escort defects.
    private func gapsPayEscorts(periods: Int) {
        guard periods > 0, !pilot.hiredEscorts.isEmpty, let engine = storyEngine() else { return }
        let disabled = Set(world?.playerEscorts.filter(\.disabled).compactMap(\.escortRecordID) ?? [])
        engine.processEscortPayroll(periods: periods, skipping: disabled)
        pilot = engine.player
    }

    // --- Gambling (the bar) ---

    /// The Galaxy Racing Network chooser: `{colors: [{name, idle, chosen, win, lose}]
    /// (PICT ids, -1 = none), chooser, credits, standard, max, prompt, winLabel,
    /// labels{bet1000, bet, leave}}`.
    @Callable(autoSnakeCase: true) func gambleInfo() -> String {
        guard let game else { return "{}" }
        func pict(_ id: Int) -> Int { game.hasPICT(id) ? id : -1 }
        let s = game.stringList(2002)
        let colors: [[String: Any]] = RaceColor.allCases.map {
            ["name": $0.name, "idle": pict($0.idlePictID), "chosen": pict($0.chosenPictID),
             "win": pict($0.winPictID), "lose": pict($0.losePictID)]
        }
        return Self.json([
            "colors": colors, "chooser": pict(RaceColor.chooserPictID), "credits": pilot.credits,
            "standard": LandedServices.RaceBet.standardWager(credits: pilot.credits),
            "max": LandedServices.RaceBet.maxPromptedWager(credits: pilot.credits),
            "prompt": s?.string(at: 372) ?? "Amount to bet:", "winLabel": s?.string(at: 370) ?? "Your winnings",
            "labels": ["bet1000": buttonLabel(14, "Bet 1000"), "bet": buttonLabel(59, "Bet"),
                       "leave": buttonLabel(1, "Leave")],
        ] as [String: Any])
    }

    /// Bet `wager` credits on colour `pick` (0 blue … 3 red) and run the race: the
    /// stake leaves the credits, a win pays four times it. JSON `{ok, winner, pick,
    /// stake, payout, net, credits, text}`; `ok` false = refused, nothing charged.
    @Callable(autoSnakeCase: true) func gambleBet(pick: Int, wager: Int) -> String {
        guard let color = RaceColor(index: pick) else { return Self.json(["ok": false] as [String: Any]) }
        var credits = pilot.credits
        guard let o = gaps.race.place(pick: color, amount: wager, credits: &credits,
                                      rand: { Int.random(in: 0..<$0) }) else {
            return Self.json(["ok": false, "credits": pilot.credits] as [String: Any])
        }
        pilot.credits = credits
        let text = game.map { OriginalText(game: $0) }
        let unit = text?.misc(o.stake < 2 ? 32 : 33) ?? "credits"
        let line: String
        if o.won {
            line = "\(game?.stringList(2002)?.string(at: 370) ?? "Your winnings"): \(OriginalText.grouped(o.payout)) \(unit)"
        } else {
            line = "\(o.winner.name) wins — you lose \(OriginalText.grouped(o.stake)) \(unit)."
        }
        return Self.json(["ok": true, "winner": o.winner.index, "pick": pick, "stake": o.stake, "payout": o.payout,
                          "net": o.net, "credits": pilot.credits, "text": line] as [String: Any])
    }

    // --- Contraband scans and junk cargo in flight ---

    /// A government ship finished scanning the player (`GameScene.onPlayerScanned`):
    /// fail-if-scanned smuggling missions, then the `ScanFine` / `SmugPenalty`.
    @discardableResult
    private func gapsPlayerScanned(by govt: Int) -> PlayerScanOutcome? {
        guard let game, let world, govt >= 0 else { return nil }
        pilot.cargo = world.player.cargo             // pickups made in flight
        let out = ContrabandScan.scanPlayer(state: &pilot, game: game, scannerGovt: govt, services: storyState.services)
        if !out.failedMissionIDs.isEmpty { beep(2) } // Ship_ScanPlayerForContraband 0x00401800, snd 151
        if let r = out.result, r.foundContraband {
            // The smuggling flood goes to the live per-system record (EC-02).
            if r.smugglingPenalty > 0 { world.diplomacy?.recordSmuggling(against: govt) }
            beep(5)                                  // the scan result line sounds snd 154
        }
        for line in out.messages { post(line) }
        world.player.cargo = pilot.cargo
        if !out.failedMissionIDs.isEmpty || out.result != nil { _ = autosave(.event) }
        return out
    }

    /// Tribbles breed and perishables rot, on the original's 0…1024 frame counter
    /// (EC-24); run once per sim tick, in flight only.
    private func gapsAfterTick(_ world: World) {
        guard world.player.isAlive, let galaxy else { return }
        for _ in 0..<world.rawCallsThisStep {
            gaps.junkFrame = (gaps.junkFrame + 1) % PilotEconomy.junkCargoFramePeriod
            guard PilotEconomy.junkCargoEventDue(frame: gaps.junkFrame) else { continue }
            var held = pilot
            held.cargo = world.player.cargo
            if PilotEconomy.runJunkCargoEvent(&held, galaxy: galaxy) {
                world.player.cargo = held.cargo
                pilot.cargo = held.cargo
            }
        }
        gapsHazardTick(world)
    }

    /// Bomb outfits (OS-08): the fuse counts the player's 30 Hz flight ticks; the rules are
    /// `HazardOutfits.tick` (Apple `checkHazardOutfits`).
    private func gapsHazardTick(_ world: World) {
        guard dockedSpobID == nil, let game, !pilot.outfits.isEmpty else { gaps.bombFuse = nil; return }
        switch HazardOutfits.tick(fuse: &gaps.bombFuse, pilot: &pilot, ship: world.player, game: game) {
        case .none:
            break
        case let .detonated(line, _):
            post(line)
        case let .nonlethal(_, boomID):
            world.emitExplosion(at: world.player.position, radius: 24, boomID: boomID)
        }
    }

    /// The player's mining scoop collected a box (a destroyed rock's yield, a spilled load): it
    /// goes into the hold, clamped to free space (Apple `onAsteroidMined`).
    private func gapsMined(cargoType: Int, quantity: Int) {
        guard let world, let galaxy else { return }
        var held = pilot
        held.cargo = world.player.cargo
        guard WorldPilotLink.collectMined(cargoType: cargoType, quantity: quantity, pilot: &held, galaxy: galaxy) != nil
        else { return }
        world.player.cargo = held.cargo
        pilot.cargo = held.cargo
    }

    /// An NPC boarded the player (AI-29): the boarders take cargo and credits, snd 151 and
    /// the original's status line (Apple `onPlayerBoardedBy`).
    private func gapsPlayerBoarded(by boarderID: Int, ratio: Int) {
        guard let world, let game else { return }
        var cargo = world.player.cargo
        var credits = pilot.credits
        let line = WorldPilotLink.resolveBoarding(world: world, game: game, boarderID: boarderID, ratio: ratio,
                                                  cargo: &cargo, credits: &credits)
        world.player.cargo = cargo
        pilot.cargo = cargo
        pilot.credits = credits
        if let line, !line.isEmpty {
            post(line)
            beep(2)   // Boarding_BoardShipAndTransferCargo 0x00412550, snd 151
        }
    }

    // --- World events the section reacts to (called from collectEvents) ---

    private func gapsNote(_ event: WorldEvent) {
        guard let game else { return }
        switch event {
        case let .shipScanned(scannerID, targetID, _) where targetID == World.playerEntityID:
            post("You are being scanned.")
            if let govt = world?.ship(id: scannerID)?.government { gapsPlayerScanned(by: govt) }
        case let .playerEjected(previous, newClass, intoPod, _):
            // OS-02: the old hull's OnRetire, the outfits that don't stay with the pilot
            // go with it, the pod (or bay fighter) is what the pilot now owns; a pod
            // can't lead, so the escorts are released.
            EscapePodRespawn.eject(&pilot, from: previous, into: newClass, game: game)
            if intoPod { pilot.escorts = nil }
            let strs = game.stringList(2002)
            if intoPod { post(strs?.string(at: 38) ?? "") }
            else { post("\(strs?.string(at: 52) ?? "") \(game.ship(newClass)?.displayName ?? "").") }
            _ = autosave(.event)
        case let .asteroidMined(cargoType, quantity, _):
            gapsMined(cargoType: cargoType, quantity: quantity)
        case let .playerBoarded(boarderID, ratio):
            gapsPlayerBoarded(by: boarderID, ratio: ratio)
        case .personGrudge, .personDefeated, .reinforcementsCalled:
            // The pilot remembers who it wronged / defeated (never respawns) and which
            // systems' reinforcements are on their retrigger delay (Apple `onPersGrudge` etc.).
            if WorldPilotLink.note(event: event, pilot: &pilot) { _ = autosave(.event) }
        case .escapePodRespawn:
            gaps.podRespawnPending = true
        case .playerDestroyed:
            gaps.playerDestroyed = true
        default:
            break
        }
    }

    /// After the tick loop: the pod's respawn (`respawnFromEscapePod`) rebuilds the world,
    /// so it can't run inside it.
    private func gapsTick() {
        if gaps.podRespawnPending {
            gaps.podRespawnPending = false
            gapsRespawnFromPod()
        }
    }

    /// The escape pod landed: every mission is abandoned, the pilot is a class-zero
    /// ship at the nearest friendly shipyard the death system's neighbours offer, the
    /// pod drifted 15…44 days (`EscapePodRespawn`, OS-02).
    private func gapsRespawnFromPod() {
        guard let game, let galaxy, var engine = storyEngine() else { return }
        let deathSystem = currentSystemID ?? pilot.currentSystem
        for id in pilot.activeMissions.map(\.missionID) { engine.abortMission(id) }
        pilot = engine.player
        EscapePodRespawn.resetToClassZero(&pilot, game: game)
        engine = storyEngine() ?? engine
        let target = EscapePodRespawn.respawnStellar(from: deathSystem, state: pilot, game: game,
                                                     isVisible: { engine.isSystemVisible($0) })
        let systemID = target?.system ?? game.systems().first?.id ?? deathSystem
        pilot.currentSystem = systemID
        pilot.exploredSystems.insert(systemID)
        pilot.landedSpob = nil
        var rng = NovaRandom(seed: UInt64(pilot.date.julianDay) &* 2_654_435_761 &+ UInt64(systemID))
        if let days = storyEngine() {
            days.advanceDays(EscapePodRespawn.driftDays(roll30: rng.range(30)))
            pilot = days.player
        }
        EscapePodRespawn.finishRespawn(&pilot, game: game, galaxy: galaxy,
                                       registrationDigits: (0..<4).map { _ in rng.range(9) + 1 })
        _ = autosave(.podRespawn)
        _ = makeWorld(systemID: systemID)
        world?.player.position = Vec2(50, -50)
        world?.player.angle = 0
        storyState.services.showStoryText(game.descText(13999), title: "")
    }

    /// The death sequence ran out with no eject (once): a game over — the frontend lets the
    /// explosion play, then returns to the main menu. Nothing is saved, so the pilot
    /// resumes from its last launch.
    @Callable(autoSnakeCase: true) func takePlayerDestroyed() -> Bool {
        defer { gaps.playerDestroyed = false }
        return gaps.playerDestroyed
    }

    // --- përs LinkMission offers on hail / board ---

    /// Present the LinkMission `missionID` that përs `personID` offers right now, as the
    /// in-flight accept/decline dialog (the story screens poll it).
    private func gapsPresentPersOffer(personID: Int, missionID: Int) {
        guard let game, let engine = storyEngine() else { return }
        if FlightPersOffer.present(missionID: missionID, engine: engine, game: game) {
            storyState.inlineOffer = false
            gaps.persOfferPerson = personID
            beep(5)    // Ship_HandlePlayerTargetActionCommand 0x00454910: the offer sounds snd 154
        } else {
            storyCommit(engine)    // a can't-refuse offer with no text activated silently
        }
    }

    /// A boarded përs offering its LinkMission on boarding rather than hailing (Flags 0x0200).
    private func gapsBoardedPersOffer() {
        guard let world, let game, let sid = interact.plunder.shipID,
              let pid = world.ship(id: sid)?.personID, let pers = game.pers(pid),
              let engine = storyEngine() else { return }
        let enc = PersEncounter.hail(pers, player: pilot, game: game, engine: engine, boarding: true)
        if let mid = enc.offerMissionID { gapsPresentPersOffer(personID: pid, missionID: mid) }
    }

    /// The pending përs offer was accepted / declined: the person's flags apply.
    private func gapsPersOfferAccepted(_ offer: MissionOffer, engine: StoryEngine) {
        guard let game, let pid = gaps.persOfferPerson else { return }
        gaps.persOfferPerson = nil
        FlightPersOffer.afterAccept(personID: pid, offer: offer, engine: engine, state: &pilot, world: world, game: game)
    }

    // --- Flight keys ---

    /// Alt-− is held (the self-destruct command, UI-15): the countdown runs while it stays down.
    @Callable(autoSnakeCase: true) func setSelfDestruct(held: Bool) { gaps.selfDestructHeld = held }

    /// U: toggle the cloaking device (oütf ModType 17). Refused with snd 153 if none is fitted.
    @Callable(autoSnakeCase: true) func toggleCloak() {
        guard let world else { return }
        if !world.player.hasCloak { beep(4) }   // 0x0044b120
        world.togglePlayerCloak()
        if world.player.hasCloak {
            post(world.player.cloakEngaged ? "Cloaking device engaged." : "Cloaking device disengaged.")
        }
    }

    /// Alt-X: abandon ship — works while disabled or going down, with an escape pod or an
    /// ejectable fighter bay (OS-02).
    @Callable(autoSnakeCase: true) func requestEject() { world?.requestEject() }

    @Callable(autoSnakeCase: true) func canEject() -> Bool { world?.canPlayerEject ?? false }

    /// Call every deployed fighter home.
    @Callable(autoSnakeCase: true) func recallFighters() {
        guard let world, !world.player.fighterBays.isEmpty else { return }
        world.playerRecallFighters()
    }

    // --- Jettisoned cargo pods and resource boxes ---

    /// Every floating box (a jettison's pods, a destroyed rock's yield) as `[x, y]`, eased
    /// between ticks.
    @Callable(autoSnakeCase: true) func freeflightTransforms() -> PackedFloat32Array {
        guard let world else { return PackedFloat32Array() }
        var flat: [Float] = []
        for box in world.freeflightObjects {
            flat.append(Float(lerp(box.renderPrevPosition.x, box.position.x, interpolationAlpha)))
            flat.append(Float(lerp(box.renderPrevPosition.y, box.position.y, interpolationAlpha)))
        }
        return PackedFloat32Array(flat)
    }

    /// Per box, SAME order: `[spïn id (500 + set), rotation frame]` — draw it as sprite kind 7.
    @Callable(autoSnakeCase: true) func freeflightStyles() -> PackedInt32Array {
        guard let world else { return PackedInt32Array() }
        var flat: [Int32] = []
        for box in world.freeflightObjects { flat.append(Int32(500 + box.spriteSet)); flat.append(Int32(box.spriteFrame)) }
        return PackedInt32Array(flat)
    }

    /// The jettison's floating pods (0x0041f330, UI-13): the player ship throws
    /// `clamp(trunc(total / 5), 1, 12)`, and every non-mission freighter escort (InherentAI < 3)
    /// its share of the ordinary cargo.
    private func gapsSpawnJettisonPods(total: Int, ordinaryTotal: Int) {
        guard let world, let galaxy else { return }
        func pods(_ tons: Double) -> Int { tons > 0 ? min(12, max(1, Int(tons / 5))) : 0 }
        world.spawnJettisonedPods(from: world.player, count: pods(Double(total)))
        let fleet = PilotEconomy.cargoCapacity(pilot, galaxy: galaxy)
        guard fleet > 0 else { return }
        for escort in world.playerEscorts where escort.missionID == nil && escort.escortRecordID != nil {
            guard let hull = galaxy.game.ship(escort.shipTypeID), hull.inherentAI < 3 else { continue }
            let share = Double(ordinaryTotal) * Double(hull.cargoSpace) / Double(fleet)
            world.spawnJettisonedPods(from: escort, count: pods(share))
        }
    }

    // --- Click to select (GameScene.selectAt) ---

    /// A click at world point (`x`, `y`): the first targetable ship under it is locked; else the
    /// nearest stellar within its radius + 15 takes the travel selection (a hypergate
    /// powers up if the player is cleared, a wormhole says so); a click on the player's own
    /// ship clears the ship target; empty space clears the travel stellar. JSON
    /// `{kind: ship|stellar|player|none, id}`.
    @Callable(autoSnakeCase: true) func clickSelect(x: Double, y: Double) -> String {
        guard let world, let game, dockedSpobID == nil, world.player.isAlive else {
            return Self.json(["kind": "none", "id": -1] as [String: Any])
        }
        let p = Vec2(x, y)
        // The mouse pick of 0x00438fc7: the sprite rect, grown by 16 on every side when narrower than 48 px.
        if let npc = world.npcs.first(where: { npc in
            guard npc.isAlive, world.canTarget(npc, by: world.player) else { return false }
            let half = npc.radius * 2 < 48 ? npc.radius + 16 : npc.radius
            let d = npc.position - p
            return abs(d.x) <= half && abs(d.y) <= half
        }) {
            _ = world.selectTarget(id: npc.entityID)
            return Self.json(["kind": "ship", "id": npc.entityID] as [String: Any])
        }
        let hit = world.systemContext.bodies
            .filter { (($0.position - p).length) <= $0.radius + 15 }
            .min { ($0.position - p).length < ($1.position - p).length }
        if let body = hit {
            selectStellar(body.id)
            if let spob = game.spob(body.id) { gapsGateClicked(spob) }
            return Self.json(["kind": "stellar", "id": body.id] as [String: Any])
        }
        if (world.player.position - p).length <= world.player.radius + 24 {
            world.clearPlayerTarget()
            return Self.json(["kind": "player", "id": 0] as [String: Any])
        }
        travel.selectedSpob = nil
        return Self.json(["kind": "none", "id": -1] as [String: Any])
    }

    /// Clicking a hypergate powers it up if the player is cleared to use it (a wormhole
    /// needs nothing); `GameScene.handleGateClick`.
    private func gapsGateClicked(_ spob: SpobRes) {
        guard let game else { return }
        if spob.isWormhole {
            post("Wormhole — fly into it to be swept across the galaxy.")
        } else if spob.isHypergate {
            if playerMayUseGate(spob.id) {
                post(travel.openGates.insert(spob.id).inserted
                     ? "\(spob.name) hypergate online — land on it to travel." : "\(spob.name) hypergate is online.")
            } else {
                beep(2)     // 0x00457580: snd 151 + STR# 2002 #81
                post(OriginalText(game: game).misc(81))
            }
        }
    }

    // --- Test seams (godot/tests/gameplay_gaps_selfcheck.gd). Not used by the game. ---

    @Callable(autoSnakeCase: true) func debugSetCredits(amount: Int) { pilot.credits = amount }

    @Callable(autoSnakeCase: true) func debugGiveCargo(id: Int, tons: Int) {
        pilot.cargo[id, default: 0] += tons
        world?.player.cargo = pilot.cargo
    }

    /// Dock at any stellar without flying there (shop screens read the spöb only).
    @Callable(autoSnakeCase: true) func debugDockAt(spobID: Int) -> Bool {
        guard game?.spob(spobID) != nil else { return false }
        touchDown(spobID: spobID, chargeFee: false)
        return true
    }

    /// `[{junk, name, boughtAt: [spöb…], soldAt: [spöb…]}]` for every jünk type.
    @Callable(autoSnakeCase: true) func debugJunkSpots() -> String {
        guard let game else { return "[]" }
        return Self.json(game.junks().map {
            ["junk": $0.id, "name": $0.name, "boughtAt": $0.highs, "soldAt": $0.lows, "flags": Int($0.flags),
             "scanMask": Int($0.scanMask)] as [String: Any]
        })
    }

    /// Run the in-flight scan consequence for a ship of `govt`; JSON of what happened.
    @Callable(autoSnakeCase: true) func debugScanPlayer(govt: Int) -> String {
        guard let out = gapsPlayerScanned(by: govt) else { return "{}" }
        return Self.json(["fine": out.result?.fine ?? 0, "found": out.result?.foundContraband ?? false,
                          "warning": out.result?.warningOnly ?? false, "cargo": out.result?.contrabandCargo ?? [],
                          "failed": out.failedMissionIDs, "credits": pilot.credits, "messages": out.messages] as [String: Any])
    }

    /// `[{id, scanMask, scanFine, smugPenalty}]` for every government that polices something.
    @Callable(autoSnakeCase: true) func debugPolicingGovts() -> String {
        guard let game else { return "[]" }
        return Self.json(game.govts().filter { $0.scanMask != 0 && $0.smugglePenalty != 0 }.map {
            ["id": $0.id, "scanMask": Int($0.scanMask), "scanFine": $0.scanFine, "smugPenalty": $0.smugglePenalty] as [String: Any]
        })
    }

    /// One junk-cargo event on the hold (tribbles breed, perishables rot); true if it changed.
    @Callable(autoSnakeCase: true) func debugRunJunkEvent() -> Bool {
        guard let world, let galaxy else { return false }
        var held = pilot
        held.cargo = world.player.cargo
        let changed = PilotEconomy.runJunkCargoEvent(&held, galaxy: galaxy)
        world.player.cargo = held.cargo
        pilot.cargo = held.cargo
        return changed
    }

    /// Fit the player an escape pod and disable the hull so Alt-X can eject.
    @Callable(autoSnakeCase: true) func debugPrepareEject() {
        world?.player.hasEscapePod = true
        world?.player.heldDisabled = true
    }

    @Callable(autoSnakeCase: true) func debugPlayerShipType() -> Int { world?.player.shipTypeID ?? -1 }

    /// The pilot's escort roster with its pending marks.
    @Callable(autoSnakeCase: true) func debugEscortRecords() -> String {
        Self.json(pilot.escortWing.map { ["record": $0.id, "ship": $0.shipType, "origin": "\($0.origin)",
                                          "pendingSale": $0.pendingSale == true, "pendingUpgrade": $0.pendingUpgradeTo ?? -1,
                                          "dailyFee": $0.dailyFee,
                                          "sellValue": game?.ship($0.shipType).map { PilotEconomy.escortSellValue(for: $0) } ?? 0,
                                          "upgradeCost": game?.ship($0.shipType)?.escortUpgradeCost ?? 0] as [String: Any] })
    }

    /// Register a captured (free, sellable) escort of `shipType` in the roster; its record id.
    @Callable(autoSnakeCase: true) func debugAddCapturedEscort(shipType: Int) -> Int {
        guard let game, let ship = game.ship(shipType) else { return -1 }
        return pilot.registerEscort(shipType: shipType, name: ship.name, origin: .captured).id
    }

    /// `[shipType, upgradesTo, cost]` of a hull the escort window would offer Upgrade for (the
    /// target's availability passing), or empty.
    @Callable(autoSnakeCase: true) func debugUpgradableShip() -> PackedInt32Array {
        guard let game else { return PackedInt32Array() }
        for s in game.ships() where s.escortUpgradesTo >= 128 && s.escortUpgradeCost > 0 {
            guard let t = game.ship(s.escortUpgradesTo), NCBTest(t.availBits).evaluate(pilot) else { continue }
            return PackedInt32Array([Int32(s.id), Int32(t.id), Int32(s.escortUpgradeCost)])
        }
        return PackedInt32Array()
    }

    /// Empty the escort roster (a clean slate for a test).
    @Callable(autoSnakeCase: true) func debugClearEscorts() {
        for e in pilot.escortWing { pilot.removeEscort(id: e.id) }
    }

    /// Put the player ship at (`x`, `y`) at rest.
    @Callable(autoSnakeCase: true) func debugMovePlayer(x: Double, y: Double) {
        world?.player.position = Vec2(x, y)
        world?.player.velocity = Vec2()
    }

    /// Tons of cargo `id` aboard the flying ship.
    @Callable(autoSnakeCase: true) func debugCargoHeld(id: Int) -> Int { world?.player.cargo[id] ?? 0 }

    @Callable(autoSnakeCase: true) func debugPilotShipType() -> Int { pilot.shipType }

    /// Own a cloaking device (oütf ModType 17) and rebuild the world so the ship carries it.
    @Callable(autoSnakeCase: true) func debugEquipCloak() -> Bool {
        guard let game, let o = game.outfits().first(where: { $0.has(.cloak) }) else { return false }
        pilot.grantOutfit(o.id)
        return makeWorld(systemID: currentSystemID ?? -1)
    }

    /// `[{pers, mission, onBoard, deactivate, leave}]` — përs that offer a LinkMission.
    @Callable(autoSnakeCase: true) func debugPersOffers() -> String {
        guard let game else { return "[]" }
        return Self.json(game.perses().filter { $0.linkMission >= 128 && game.mission($0.linkMission) != nil }.map {
            ["pers": $0.id, "mission": $0.linkMission, "onBoard": $0.offerMissionOnBoard,
             "deactivate": $0.deactivateAfterMission, "leave": $0.leaveAfterMission] as [String: Any]
        })
    }

    /// Present përs `personID`'s LinkMission `missionID` as a hail would. True if a dialog is up.
    @Callable(autoSnakeCase: true) func debugPresentPersOffer(personID: Int, missionID: Int) -> Bool {
        gapsPresentPersOffer(personID: personID, missionID: missionID)
        return storyState.services.pendingOffer != nil
    }

    // --- Live-wiring test seams (godot/tests/live_wiring_selfcheck.gd). Not used by the game. ---

    /// `{rating, legal, strict, seed}` of the pilot AFTER folding the live world into it.
    @Callable(autoSnakeCase: true) func debugStanding() -> String {
        syncLiveStanding()
        let here = world?.diplomacy?.reputationHere ?? 0
        return Self.json(["rating": pilot.combatRating, "worldRating": world?.playerCombatRating ?? -1,
                          "legalHere": here, "pilotLegal": pilot.systemReputation?[currentSystemID ?? -1] ?? 0,
                          "strictWorld": world?.strictPlay ?? false, "strictPilot": pilot.isStrictPlay,
                          "system": currentSystemID ?? -1, "sysGovt": world?.diplomacy?.currentSystemGovernment ?? -1,
                          "credits": pilot.credits, "ranks": Array(pilot.activeRanks).sorted()] as [String: Any])
    }

    /// Ids of the first `limit` systems in the data (test aid for hopping between worlds).
    @Callable(autoSnakeCase: true) func debugSystemIds() -> PackedInt32Array {
        PackedInt32Array((game?.systems().prefix(8) ?? []).map { Int32($0.id) })
    }

    /// Commit a crime against `govt` in the current system as the engine would (a kill, a
    /// disable, a boarding), without needing a victim in range.
    @Callable(autoSnakeCase: true) func debugCommitCrime(kind: String, govt: Int, strength: Int) {
        guard let dip = world?.diplomacy else { return }
        switch kind {
        case "kill": dip.recordKill(of: govt, shipStrength: strength)
        case "disable": dip.recordDisable(of: govt)
        case "board": dip.recordBoard(of: govt)
        default: dip.recordSmuggling(against: govt)
        }
    }

    /// Destroy the first live NPC as the player's kill (credited to the legal record and the combat
    /// rating by the engine itself). Returns the victim's `{govt, strength, person}`.
    @Callable(autoSnakeCase: true) func debugKillNpc() -> String {
        guard let world, let npc = world.npcs.first(where: { $0.isAlive && $0.missionID == nil }) else { return "{}" }
        npc.killedByPlayer = true
        npc.killCredited = true
        npc.armor = 0
        let out: [String: Any] = ["govt": npc.government, "strength": Int(npc.combatStrength), "person": npc.personID ?? -1]
        step(dt: Self.fixedStep * 2)
        return Self.json(out)
    }

    /// Hand the player ship a mining scoop outfit and rebuild the world, then drop `tons` of
    /// cargo `cargoType` boxes on top of it. True once the scoop is fitted.
    @Callable(autoSnakeCase: true) func debugEquipScoop() -> Bool {
        guard let game, let o = game.outfits().first(where: { $0.has(.miningScoop) }) else { return false }
        pilot.grantOutfit(o.id)
        return makeWorld(systemID: currentSystemID ?? -1)
    }

    /// Spawn `count` resource boxes of `cargoType` on the player; returns how many tons the
    /// hold gained after `ticks` of flight (the scoop collects what fits).
    @Callable(autoSnakeCase: true) func debugMineBoxes(cargoType: Int, count: Int, ticks: Int) -> Int {
        guard let world else { return 0 }
        let before = world.player.cargo[cargoType] ?? 0
        for _ in 0..<count { world.spawnFreeflightObject(at: world.player.position, cargoType: cargoType, spriteSet: 0) }
        for _ in 0..<ticks { step(dt: Self.fixedStep) }
        return (world.player.cargo[cargoType] ?? 0) - before
    }

    /// Tons of the hold still free (the mining scoop's gate).
    @Callable(autoSnakeCase: true) func debugHoldHasRoom() -> Bool { world?.playerHoldHasRoom() ?? false }

    /// The world's view of përs `id`: `[eligible, grudge]` as 0/1.
    @Callable(autoSnakeCase: true) func debugPersGate(id: Int) -> PackedInt32Array {
        guard let world else { return PackedInt32Array() }
        return PackedInt32Array([world.persSpawnEligible(id) ? 1 : 0, world.playerPersGrudges.contains(id) ? 1 : 0])
    }

    /// Let përs `id` be defeated / wronged as the engine reports it.
    @Callable(autoSnakeCase: true) func debugPersEvent(id: Int, defeated: Bool) {
        let e: WorldEvent = defeated ? .personDefeated(personID: id) : .personGrudge(personID: id)
        gapsNote(e)
    }

    /// A pêrs with an `ActiveOn` expression, else a plain one: `[id, hasActiveOn]`.
    @Callable(autoSnakeCase: true) func debugGatedPers() -> PackedInt32Array {
        guard let game else { return PackedInt32Array() }
        if let p = game.perses().first(where: { !$0.activeOn.isEmpty }) { return PackedInt32Array([Int32(p.id), 1]) }
        if let p = game.perses().first { return PackedInt32Array([Int32(p.id), 0]) }
        return PackedInt32Array()
    }

    /// An NPC boards the player: `{cargo, credits, line}` lost. Uses the first live NPC as the boarder.
    @Callable(autoSnakeCase: true) func debugBoardPlayer(ratio: Int) -> String {
        guard let world, let boarder = world.npcs.first(where: { $0.isAlive }) else { return "{}" }
        let c0 = world.player.cargo.values.reduce(0, +), cr0 = pilot.credits
        gapsNote(.playerBoarded(byShipID: boarder.entityID, ratio: ratio))
        return Self.json(["cargoLost": c0 - world.player.cargo.values.reduce(0, +),
                          "creditsLost": cr0 - pilot.credits] as [String: Any])
    }

    /// Stellar defense state the pilot holds: `{garrisons: {spob: n}, reinforce: {sys: days}, armor: {spob: v}}`.
    @Callable(autoSnakeCase: true) func debugDefenseState() -> String {
        syncLiveStanding()
        func keyed<V>(_ m: [Int: V]?) -> [String: Any] { Dictionary(uniqueKeysWithValues: (m ?? [:]).map { (String($0.key), $0.value as Any) }) }
        return Self.json(["garrisons": keyed(pilot.stellarGarrisons), "reinforce": keyed(pilot.reinforcementRetriggerDays),
                          "armor": keyed(pilot.stellarStrengthLeft),
                          "worldGarrisons": keyed(world?.stellarGarrisons),
                          "worldArmor": keyed(world?.stellarArmor)] as [String: Any])
    }

    /// Take a garrison ship from stellar `spobID`'s pool, as a defense launch does (marks it touched).
    @Callable(autoSnakeCase: true) func debugSetGarrison(spobID: Int, count: Int) {
        world?.debugSetGarrison(spobID: spobID, count: count)
    }

    /// A stellar of the current system that has a defense fleet (`DefCount` > 0), else -1.
    @Callable(autoSnakeCase: true) func debugDefendedStellar() -> Int {
        guard let world, let game else { return -1 }
        return world.systemContext.bodies.first { game.spob($0.id)?.hasDefenseFleet == true }?.id ?? -1
    }

    /// Demand tribute from `spobID` with a combat rating high enough to open the contest.
    @Callable(autoSnakeCase: true) func debugDemandTribute(spobID: Int) -> String {
        guard let world else { return "" }
        world.playerCombatRating = 20_000
        return "\(world.demandTribute(spobID: spobID))"
    }

    /// Fire a `reinforcementsCalled` report for the current system as the spawner does.
    @Callable(autoSnakeCase: true) func debugReinforcementsCalled(days: Int) {
        gapsNote(.reinforcementsCalled(systemID: currentSystemID ?? -1, retriggerDays: days))
    }

    /// `{seed, day}` the current system's world is seeded with today (Apple `currentWorldSeed`).
    @Callable(autoSnakeCase: true) func debugSpawnSeed() -> String {
        Self.json(["seed": String(GameSession.worldSeed(systemID: currentSystemID ?? 0, day: pilot.date.julianDay)),
                   "day": pilot.date.julianDay] as [String: Any])
    }

    /// Let `days` game days pass (the travel/landing clock) so the next world builds on a new seed.
    @Callable(autoSnakeCase: true) func debugAdvanceDays(days: Int) {
        guard let engine = storyEngine() else { return }
        engine.advanceDays(days)
        pilot = engine.player
    }

    /// A hull whose `AppearOn` test is non-blank, else -1.
    @Callable(autoSnakeCase: true) func debugGatedShip() -> Int {
        game?.ships().first { !$0.appearOn.isEmpty }?.id ?? -1
    }

    /// The `AppearOn` expression of hull `id`.
    @Callable(autoSnakeCase: true) func debugShipAppearOn(id: Int) -> String { game?.ship(id)?.appearOn ?? "" }

    /// Whether the live world lets hull `id` appear.
    @Callable(autoSnakeCase: true) func debugShipGate(id: Int) -> Bool { world?.shipSpawnEligible(id) ?? true }

    /// `[system, stellar]` of a stellar with a defense fleet, else empty.
    @Callable(autoSnakeCase: true) func debugSystemWithDefendedStellar() -> PackedInt32Array {
        guard let game else { return PackedInt32Array() }
        for spob in game.spobs() where spob.hasDefenseFleet {
            if let sys = game.systemContaining(spob: spob.id) { return PackedInt32Array([Int32(sys), Int32(spob.id)]) }
        }
        return PackedInt32Array()
    }

    /// Damage a destroyable stellar as combat would leave it: `value` strength remaining.
    @Callable(autoSnakeCase: true) func debugSetStellarArmor(spobID: Int, value: Double) {
        world?.stellarArmor[spobID] = value
    }

    /// Run the bomb fuse `ticks` ticks of flight; the outfit counts as detonated if the hull took damage / died.
    @Callable(autoSnakeCase: true) func debugGiveBomb(lethal: Bool) -> Bool {
        guard let game, let o = game.outfits().first(where: { $0.modifiers.contains { $0.0 == (lethal ? .bomb : .nonlethalBomb) } })
        else { return false }
        pilot.grantOutfit(o.id)
        gaps.bombFuse = 300
        return true
    }

    /// Whether përs `id` is recorded as never to appear again.
    @Callable(autoSnakeCase: true) func debugPersDefeated(id: Int) -> Bool { pilot.isPersDefeated(id) }

    // MARK: Settings plumbing
    //
    // The Settings that change how the world plays. GDScript (`SettingsPlumbing.gd`, an autoload
    // watching `Prefs`) packs the engine-relevant ones into one JSON object -- Apple's
    // `GameSettings` property names and raw values -- and calls `apply_settings`; `Settings.swift`
    // holds the state, the rules are the engine's own (`GameSettingsRules.swift`, `GameSpeedRules`,
    // `GameplayEnhancements`), shared with the Apple app. Applied to every world built from here
    // on (`makeConfiguredWorld`) and to the live one at once.

    /// `GameSession.makeWorld` with the settings in force: combat tuning (difficulty), the spawn
    /// model (System Aliveness, from the initial fill on) and the enhancement toggles; the
    /// population scale lands right after, as in Apple's `GameScene.init`.
    private func makeConfiguredWorld(game: NovaGame, systemID: Int, player: Ship,
                                     galaxy: Galaxy) -> (world: World, galaxy: Galaxy) {
        // Carry the pilot into the new world exactly as the Apple `GameHost` does (A1/A3/A5/A7):
        // what the outgoing world accrued is folded in first (the diplomacy table is cached per
        // galaxy and the seed below overwrites it), then the legal record + ranks are seeded,
        // the per-day seed varies the cast between visits, and the pilot's gating / Strict Play /
        // defense state land before the initial fill.
        syncLiveStanding()
        WorldPilotLink.seedDiplomacy(galaxy.makeDiplomacy(), pilot: pilot, game: game, systemID: systemID)
        let built = GameSession.makeWorld(game: game, systemID: systemID, player: player, galaxy: galaxy,
                                          combatTuning: plumbing.combatTuning,
                                          seed: GameSession.worldSeed(systemID: systemID, day: pilot.date.julianDay),
                                          spawnModel: plumbing.traffic.spawnModel,
                                          enhancements: plumbing.enhancements,
                                          configure: { [weak self] w in
            guard let self else { return }
            WorldPilotLink.configure(world: w, game: game, pilot: { [weak self] in self?.pilot ?? PlayerState() })
            WorldPilotLink.applyDefenseState(world: w, game: game, pilot: self.pilot, systemID: systemID,
                                             escortOrdersChanged: { [weak self] in self?.pilot.escortCategoryOrders = $0 })
        })
        plumbing.configure(built.world)
        plumbing.resetForNewWorld()
        return built
    }

    /// Fold what the live world accrued into the pilot (A1/A5): crimes into the per-system legal
    /// record, crime-sensitive rank revocation, kills into the combat rating, damaged stellars'
    /// armor and touched garrisons. Apple `GameContainerView.syncCombatStanding`; the rules are
    /// `WorldPilotLink.syncLive`. Called at every point the world might be discarded or read
    /// (landing, jump, launch, save, Player Info, comm windows).
    private func syncLiveStanding() {
        guard let game else { return }
        if let world {
            WorldPilotLink.syncLive(world: world, game: game, pilot: &pilot)
        } else if let galaxy {
            WorldPilotLink.foldStanding(galaxy.makeDiplomacy(), game: game, pilot: &pilot)
        }
    }

    /// Replace the gameplay settings from JSON (see Settings.swift for the keys). False if the
    /// text isn't a JSON object. Takes effect on the live world immediately.
    @Callable(autoSnakeCase: true) func applySettings(json: String) -> Bool {
        let formation = plumbing.enhancements.formationFlying
        guard plumbing.apply(json: json) else { return false }
        if let game, plumbing.enhancements.formationFlying != formation {
            // Tight formations change the ships' flight model, which the galaxy bakes in: the
            // next world built uses a fresh galaxy (Apple builds it per launch).
            galaxy = Galaxy(game: game, flightTuning: plumbing.flightTuning)
        }
        if let world { plumbing.configure(world) }
        return true
    }

    /// What the engine is running with, as JSON: the settings as parsed, the live world's
    /// damage scale / spawn model / population scale / time scale, the effective speed
    /// multiplier and the 2x flag, ticks run since the world was built, the auto-landing
    /// target (-1 none).
    @Callable(autoSnakeCase: true) func settingsState() -> String { plumbing.stateJSON(world: world) }

    /// Caps Lock is the original's 2x mode (`GameSpeedRules`). Godot cannot ask the OS for the
    /// lock's state, so the frontend tracks the key and pushes it here.
    @Callable(autoSnakeCase: true) func setCapsLock(on: Bool) { plumbing.capsLock = on }

    /// Desktop mouse aim (Apple `GameScene.updateMouseAim`): `heading` is the compass angle
    /// (radians, 0 = up, clockwise) from the ship to the pointer; `active == false` clears it.
    /// A stick's aim (`set_aim_heading`) and the turn keys win over it, as on Apple.
    @Callable(autoSnakeCase: true) func setMouseAim(active: Bool, heading: Double) {
        plumbing.mouseAimHeading = active ? heading : nil
    }

    /// The colorblind-assist filter (`none`, `protanopia`, `deuteranopia`, `tritanopia`) as the 16
    /// floats of its 4x4 colour matrix, row-major, rows R, G, B, A (Apple's `CIColorMatrix`
    /// vectors: out.r = dot(row0, rgba), ...); empty for `none` or an unknown name.
    @Callable(autoSnakeCase: true) func colorblindMatrix(mode: String) -> PackedFloat32Array {
        guard let rows = ColorblindFilter(rawValue: mode)?.matrixRows else { return PackedFloat32Array() }
        return PackedFloat32Array(rows.flatMap { $0 }.map { Float($0) })
    }

    /// Test aids (settings self-check): the ids of the bodies the player could land on or use, the
    /// position of one, and a teleport that leaves the ship at rest.
    @Callable(autoSnakeCase: true) func debugLandTargets() -> PackedInt32Array {
        PackedInt32Array(landTargets().map { Int32($0.id) })
    }
    @Callable(autoSnakeCase: true) func debugStellarPosition(id: Int) -> Vector2 {
        stellarBody(id).map { Vector2(x: Float($0.position.x), y: Float($0.position.y)) } ?? Vector2()
    }
    @Callable(autoSnakeCase: true) func debugTeleportPlayer(x: Double, y: Double) {
        world?.player.position = Vec2(x, y)
        world?.player.velocity = Vec2()
    }

    /// The simulation speed the last `step` ran at (Settings game speed x Caps Lock 2x).
    @Callable(autoSnakeCase: true) func speedMultiplier() -> Double { plumbing.multiplier }

    /// The original's x2 indicator condition: the effective speed is exactly 2x.
    @Callable(autoSnakeCase: true) func x2Active() -> Bool { abs(plumbing.multiplier - 2) < 1e-9 }

    /// Whether the auto-landing autopilot is flying the ship.
    @Callable(autoSnakeCase: true) func isAutoLanding() -> Bool { plumbing.autoLandTarget != nil }

    /// Hand control back (the Land key cancels too).
    @Callable(autoSnakeCase: true) func cancelAutoLand() { plumbing.autoLandTarget = nil }

    /// The `spöb` id awaiting the "Land here?" confirmation (Settings > Confirm landing), or -1.
    @Callable(autoSnakeCase: true) func pendingLandConfirm() -> Int { plumbing.pendingLandConfirm ?? -1 }

    /// Answer the confirmation: land (same JSON as `press_land`), or drop it.
    @Callable(autoSnakeCase: true) func confirmLanding(accept: Bool) -> String {
        guard let id = plumbing.pendingLandConfirm else { return landJSON("none") }
        plumbing.pendingLandConfirm = nil
        guard accept, dockedSpobID == nil, world?.player.isAlive == true else { return landJSON("none") }
        return requestLanding(id, confirmed: true)
    }

    /// The player's intent for this frame: invert turn, then (in this order) the auto-landing
    /// autopilot, which any manual turn/thrust hands back, or the mouse-aim heading.
    private func settingsPlayerIntent(_ raw: ControlIntent) -> ControlIntent {
        func inverted(_ r: ControlIntent) -> ControlIntent {
            var i = r
            if plumbing.invertTurn { swap(&i.turnLeft, &i.turnRight) }   // "Invert turn direction"
            return i
        }
        if let id = plumbing.autoLandTarget {
            if raw.turnLeft || raw.turnRight || raw.thrust || raw.reverse {
                plumbing.autoLandTarget = nil
                return inverted(raw)
            }
            guard let world, dockedSpobID == nil, let body = stellarBody(id), body.isLandable || body.isGate else {
                plumbing.autoLandTarget = nil
                return ControlIntent()
            }
            switch AutoLandPilot.step(player: world.player, body: body, rules: plumbing.landingRules,
                                      cleared: travel.cleared.contains(id)) {
            case .arrived:
                plumbing.autoLandTarget = nil
                _ = requestLanding(id)   // the Apple container's `onAutoLandArrived`
                return ControlIntent()
            case .fly(let flying):
                return flying
            }
        }
        var i = inverted(raw)
        if i.desiredHeading == nil, let heading = plumbing.mouseAimHeading, world?.playerJump == nil {
            i.desiredHeading = heading
        }
        return i
    }

    /// Settings game speed x the original's Caps Lock 2x flag -> the world's `timeScale`.
    private func settingsSpeed(_ world: World) -> Double {
        plumbing.x2Flag = plumbing.evaluateX2Flag(world)
        let m = GameSpeedRules.effectiveMultiplier(setting: plumbing.gameSpeed.multiplier, x2Flag: plumbing.x2Flag)
        plumbing.multiplier = m
        world.timeScale = m
        world.x2Mode = plumbing.x2Flag
        return m
    }

    /// "Auto-target after firing": the shot that opens fire with nothing locked locks the
    /// nearest hostile (`GameScene.update`).
    private func settingsAutoTarget(_ world: World) {
        let firing = intent.firePrimary
        if plumbing.autoTargetAfterFiring, firing, !plumbing.wasFiring, world.player.currentTargetID == nil {
            let found = plumbing.enhancements.nearestFirstTargeting ? world.selectNearestTarget(hostileOnly: true)
                                                                    : world.selectNearestHostileThreat()
            beepForNearestTarget(found: found, was: nil)
        }
        plumbing.wasFiring = firing
    }

    /// The Land key under Auto-landing / Forgiving landing (`GameContainerView`'s `.land` action):
    /// auto-landing flies to the selected (or nearest) body and sets down on arrival, a second
    /// press cancelling; forgiving landing lands on the nearest body in its wide envelope in one
    /// press, with no clearance exchange.
    private func settingsPressLand(_ world: World) -> String {
        if plumbing.autoLanding {
            if plumbing.autoLandTarget != nil {
                plumbing.autoLandTarget = nil
                return landJSON("none")
            }
            for id in [travel.selectedSpob, nearestLandTarget()?.id].compactMap({ $0 }) {
                guard let body = stellarBody(id), body.isLandable || body.isGate else { continue }
                plumbing.autoLandTarget = id
                selectStellar(id)
                // The autopilot is the Land press: request clearance so the 250 px arm runs for this body.
                if !plumbing.enhancements.forgivingLanding, travel.landingRequest != id { travel.landingRequest = id }
                return landJSON("autoland", spob: id)
            }
        }
        let p = world.player
        if plumbing.enhancements.forgivingLanding {
            if let near = nearestLandTarget(), canLand(on: near, p) { return requestLanding(near.id) }
        } else if let id = attemptLandSelected() {
            return requestLanding(id)
        }
        return landJSON("none")
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
        let bursts = sound.deaths.advance(dt: dt)
        sound.deathCuesEmitted += bursts.count
        sound.pending.append(contentsOf: bursts)
        sound.rawCallAccumulator += max(0, dt) * OriginalClock.rawCallsPerSecond
        let calls = Int(sound.rawCallAccumulator)
        sound.rawCallAccumulator -= Double(calls)
        if sound.redAlert.advance(rawCalls: calls, lowVolume: statusLine.lowVolume, inEscapePod: world.playerInEscapePod,
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

    // MARK: Classic UI
    //
    // Data for godot/ui/classic/ (the authentic-UI kit). Thin forwards into
    // ClassicUI.swift; PICT pixels come from `pict_info` / `pict_rgba` (Spaceport
    // section). All reads are empty when no game is loaded.

    /// DLOG/DITL `id` as JSON — see `ClassicUIBackend.dialog`. `{}` if absent.
    @Callable(autoSnakeCase: true) func classicDialog(id: Int) -> String {
        game.map { ClassicUIBackend.dialog($0, id) } ?? "{}"
    }

    /// Neighbour indices `[up, down, left, right]` per rect (-1 = none) for a flat
    /// `[l,t,r,b, …]` array — gamepad / keyboard focus derived from DITL geometry.
    @Callable(autoSnakeCase: true) func classicFocusNeighbours(rects: PackedInt32Array) -> PackedInt32Array {
        PackedInt32Array(ClassicUIBackend.focusNeighbours(rects.map { $0 }))
    }

    /// The scale to draw a `frameW`x`frameH` 1:1 layout at inside the viewport
    /// (>= 1, snapped down to 0.5 steps so nearest-filtered art stays even).
    @Callable(autoSnakeCase: true) func classicCrispScale(frameW: Int, frameH: Int, viewW: Double, viewH: Double) -> Double {
        ClassicUIBackend.crispScale(frameW: frameW, frameH: frameH, viewW: viewW, viewH: viewH)
    }

    /// Height of the three-state button art (25 in the stock data).
    @Callable(autoSnakeCase: true) func classicButtonHeight() -> Int {
        game.map { ClassicUIBackend.buttonHeight($0) } ?? 25
    }

    /// A composed `width` x `classic_button_height()` button, RGBA8. `state`: 0
    /// normal, 1 pressed, 2 grey. No label (the frontend draws it).
    @Callable(autoSnakeCase: true) func classicButtonRGBA(width: Int, state: Int) -> PackedByteArray {
        guard let game else { return PackedByteArray() }
        return PackedByteArray(ClassicUIBackend.buttonRGBA(game, width: width, state: state))
    }

    /// The `cölr` palette + fonts as JSON (`"#rrggbb"` colours).
    @Callable(autoSnakeCase: true) func classicColors() -> String {
        game.map { ClassicUIBackend.colors($0) } ?? "{}"
    }

    /// The `ïntf` id for hull `shipType` (its govt's status bar), 128 default.
    @Callable(autoSnakeCase: true) func classicInterfaceID(shipType: Int) -> Int {
        game.map { ClassicUIBackend.interfaceID($0, shipType: shipType) } ?? 128
    }

    /// `ïntf` `id` as JSON: backdrop PICT id/size, rects `[l,t,r,b]`, colours, fonts.
    @Callable(autoSnakeCase: true) func classicInterface(id: Int) -> String {
        game.map { ClassicUIBackend.interface($0, id) } ?? "{}"
    }

    /// Every string of `STR#` `id` (entry n at index n-1; the game counts from 1).
    @Callable(autoSnakeCase: true) func classicStrings(id: Int) -> PackedStringArray {
        PackedStringArray(game.map { ClassicUIBackend.strings($0, id) } ?? [])
    }

    /// Whether the loaded data has PICT `id`.
    @Callable(autoSnakeCase: true) func classicHasPict(id: Int) -> Bool {
        game?.hasPICT(id) ?? false
    }

    /// The part `[x, y, w, h]` of a bar rect (`l,t,w,h`) between fractions `a`..`b`
    /// — wide bars fill from the left, tall ones from the bottom, in whole pixels.
    @Callable(autoSnakeCase: true) func classicBarSegment(l: Int, t: Int, w: Int, h: Int, a: Double, b: Double) -> PackedInt32Array {
        let r = ClassicUIGeometry.barSegment(left: l, top: t, width: w, height: h, from: a, to: b)
        return PackedInt32Array([Int32(r.x), Int32(r.y), Int32(r.w), Int32(r.h)])
    }

    /// The jump-meter fuel gauge as `[full, partial]` fractions of the bar: `0..full`
    /// is whole hyperjumps (ïntf fuelFull), `full..full+partial` the remainder
    /// (fuelPartial). `[0, 0]` with no world.
    @Callable(autoSnakeCase: true) func classicFuelBar() -> PackedFloat64Array {
        guard let p = world?.player, p.maxFuel > 0 else { return PackedFloat64Array([0, 0]) }
        let jumps = Int((p.fuel / ShipFuel.perJump).rounded(.down))
        let s = ClassicUIGeometry.fuelSplit(fuelFraction: max(0, min(1, p.fuel / p.maxFuel)),
                                            jumps: jumps, maxFuelUnits: p.maxFuel)
        return PackedFloat64Array([s.full, s.partial])
    }

    // -- Main menu / pilot dialogs (screens/MainMenu.gd, PilotMenu.gd classic paths) --

    /// The authentic main menu's layout JSON (see `ClassicUIBackend.mainMenu`); `{}` with no game.
    @Callable(autoSnakeCase: true) func classicMainMenu() -> String {
        game.map { ClassicUIBackend.mainMenu($0) } ?? "{}"
    }

    /// `[frameW, frameH, frameCount]` of `spïn` `spin`; `mode` 0 = its sheet, 1 = rlëD / stacked-PICT tiles.
    @Callable(autoSnakeCase: true) func classicSpinInfo(spin: Int, mode: Int) -> PackedInt32Array {
        PackedInt32Array(game.map { ClassicUIBackend.spinInfo($0, spin: spin, mode: mode) } ?? [])
    }

    /// RGBA8 of one spïn frame (`w*h*4`, w/h from `classic_spin_info`), or empty.
    @Callable(autoSnakeCase: true) func classicSpinTileRgba(spin: Int, frame: Int, mode: Int) -> PackedByteArray {
        guard let game, let t = ClassicUIBackend.spinTile(game, spin: spin, frame: frame, mode: mode) else { return PackedByteArray() }
        return PackedByteArray(t.rgba)
    }

    /// The main-menu readout for a one-line state: `"killed"` (<name> has been killed, the Kenny line),
    /// `"creating"` (Creating Pilot...) or `""` (the normal readout).
    @Callable(autoSnakeCase: true) func classicMenuReadoutState(dir: String, id: String, state: String) -> String {
        guard let game else { return "{}" }
        let save = UUID(uuidString: id).flatMap { try? archive(at: dir).load(id: $0) }
        return ClassicUIBackend.menuReadout(game, save: save, state: state)
    }

    /// The main-menu pilot readout JSON for save `id` in `dir` (`""` = no pilot loaded).
    @Callable(autoSnakeCase: true) func classicMenuReadout(dir: String, id: String) -> String {
        guard let game else { return "{}" }
        let save = UUID(uuidString: id).flatMap { try? archive(at: dir).load(id: $0) }
        return ClassicUIBackend.menuReadout(game, save: save)
    }

    /// The ship-name prompt after the new-pilot dialog (STR# 2002 #121 + hull name).
    @Callable(autoSnakeCase: true) func pilotShipNamePrompt(scenarioID: Int) -> String {
        guard let game, let sc = game.selectableScenarios().first(where: { $0.id == scenarioID }) else { return "" }
        return PilotFactory.shipNamePrompt(scenario: sc, game: game)
    }

    /// `pilot_create` with the dialog's Strict Play box.
    @Callable(autoSnakeCase: true)
    func pilotCreateStrict(dir: String, scenarioID: Int, name: String, isMale: Bool, nickname: String,
                           shipName: String, strictPlay: Bool) -> String {
        guard let game, let scenario = game.selectableScenarios().first(where: { $0.id == scenarioID }),
              name.count <= PilotFactory.maxNameLength else { return "" }
        let a = archive(at: dir)
        var save = PilotSaves.makeNew(name: name, isMale: isMale, strictPlay: strictPlay, scenario: scenario, game: game,
                                      nickname: nickname, shipName: shipName.isEmpty ? nil : shipName)
        save.player.rosterID = save.id
        guard let written = try? a.save(save, backup: false) else { return "" }
        var state = written.player
        PilotSaves.migrate(&state, game: game)
        adoptPilot(state, saveID: written.id)
        return written.id.uuidString
    }

    /// `dësc` `id` text (About Nova = 32767, Acknowledgements = 32766).
    @Callable(autoSnakeCase: true) func classicDescText(id: Int) -> String { game?.descText(id) ?? "" }

    /// Play `snd ` `id` as a menu sound (the main-menu click 600/601, shutter 602/603).
    @Callable(autoSnakeCase: true) func soundMenu(id: Int) {
        sound.pending.append(SoundCue(soundID: id, priority: OriginalAudio.Priority.menuTransition))
    }

    /// The original galaxy map's info text for system `id` (see `ClassicUIBackend.mapInfo`).
    @Callable(autoSnakeCase: true) func classicMapInfo(systemID: Int) -> String {
        game.map { ClassicUIBackend.mapInfo($0, pilot: pilot, system: systemID) } ?? "{}"
    }

    // -- Ambient starfield (the shared OriginalRendering rules) --

    /// The current system's raw `sÿst` murk (stars hide while it is negative).
    @Callable(autoSnakeCase: true) func systemMurk() -> Int {
        guard let game, let id = currentSystemID else { return 0 }
        return game.system(id)?.murk ?? 0
    }

    /// `OriginalRendering.starCount`: live stars for a view `viewHeight` px tall (<= 20).
    @Callable(autoSnakeCase: true) func starCount(viewHeight: Double) -> Int { OriginalRendering.starCount(viewHeight: viewHeight) }

    /// `OriginalRendering.starFactor`: a star's extra drift for `Random(35)` = `random35`.
    @Callable(autoSnakeCase: true) func starFactor(random35: Int, parallax: Bool) -> Double {
        OriginalRendering.starFactor(random35: random35, parallax: parallax)
    }

    /// `OriginalRendering.starTint`: the 5-bit tint (32 = neutral) for the system's raw murk.
    @Callable(autoSnakeCase: true) func starTint(rawMurk: Int) -> Int { OriginalRendering.starTint(rawMurk: rawMurk) }

    // -- Authentic status-bar extras (ui/classic/AuthenticHUD.gd) --

    /// The target panel's text, as `GameScene.updateOriginalTargetText` builds it: `{name, subtitle, shipType,
    /// hidesLine, statusLabel, statusValue, code, noTarget}`; `{}` with no target.
    @Callable(autoSnakeCase: true) func hudTargetInfo() -> String {
        guard let world, let game, let target = lockedTarget else { return "{}" }
        let misc = { (n: Int) -> String in game.stringList(2002)?.string(at: n) ?? "" }
        let hull = game.ship(target.shipTypeID)
        let pers = target.personID.flatMap { game.pers($0) }
        var name = target.displayName ?? target.name
        if target.displayName == nil, let pers, !pers.name.isEmpty { name = pers.name.novaDisplayName }
        var subtitle = target.displaySubtitle ?? ""
        if target.displaySubtitle == nil, let hull { subtitle = hull.subtitle }
        let hides = (hull?.hidesShieldArmorOnStatusDisplay ?? false) || (pers?.shieldMod ?? 0) < 0
        var label = "", value = ""
        if target.disabled {
            let threshold = target.hullFlags & 0x10 != 0 ? 10.0 : 33.333
            let waiting = target.missionShipGoal == .rescue && target.armorFraction * 100 >= threshold
            value = misc(waiting ? 348 : 347)
        } else if target.shield > 0 {
            label = misc(13); value = "\(Int(target.shieldFraction * 100))%"
        } else if hull?.showArmorOnTargetDisplay == true {
            label = misc(16); value = "\(Int(target.armorFraction * 100))%"
        } else {
            value = misc((hull?.shield ?? 0) < 1 ? 14 : 15)
        }
        var code = game.govt(target.government)?.targetCode ?? ""
        if world.isPlayerEscort(target) { code = misc((hull?.mass ?? 100) < 100 ? 169 : 168) }
        return Self.json(["name": name, "subtitle": subtitle, "shipType": target.shipTypeID >= 128 ? target.shipTypeID : -1,
                          "hidesLine": hides, "statusLabel": label, "statusValue": value, "code": code])
    }

    /// The cargo panel (`GameContainerView.cargoPanel`): `{rows:[{name,tons}], special, free}`.
    @Callable(autoSnakeCase: true) func hudCargoPanel() -> String {
        guard let game, let galaxy else { return "{}" }
        let mission = PilotEconomy.missionCargo(pilot, game: game)
        var rows: [[String: Any]] = []
        for c in Commodity.allCases {
            let tons = (pilot.cargo[c.cargoID] ?? 0) - (mission[c.cargoID] ?? 0)
            if tons > 0 { rows.append(["name": game.commodityName(c), "tons": tons]) }
        }
        let loaded = pilot.activeMissions.filter { am in
            am.isCarryingCargo && (am.resolvedCargoType ?? game.mission(am.missionID)?.cargoType ?? -1) != -1
        }
        let junk = pilot.cargo.filter { $0.key >= 128 && $0.value > 0 }.keys.sorted()
        var special = ""
        if !loaded.isEmpty || !junk.isEmpty {
            let misc = game.stringList(2002)
            if loaded.count == 1, let am = loaded.first {
                let type = am.resolvedCargoType ?? game.mission(am.missionID)?.cargoType ?? -1
                special = Commodity(rawValue: type).map { game.commodityName($0) } ?? game.junk(type)?.name ?? (misc?.string(at: 21) ?? "")
            } else if loaded.isEmpty, junk.count == 1 {
                special = game.junk(junk[0])?.name ?? ""
            } else {
                special = misc?.string(at: 21) ?? "Multiple"
            }
        }
        return Self.json(["rows": rows, "special": special, "free": PilotEconomy.cargoFree(pilot, galaxy: galaxy)])
    }

    /// Whether the player's ship carries an IFF (oütf ModType 14): the radar then colours contacts.
    @Callable(autoSnakeCase: true) func hudHasIff() -> Bool {
        guard let game, let galaxy else { return false }
        return PilotEconomy.loadout(pilot, galaxy: galaxy)?.outfits.keys.contains { game.outfit($0)?.has(.iff) == true } ?? false
    }

    /// Per live ship, SAME order as `ship_transforms()`: the IFF class `Ship_GetShipRadarColor` picks --
    /// 0 disabled (grey), 1 threat (red), 2 squad (green), 3 other (blue), 4 the player.
    @Callable(autoSnakeCase: true) func shipIffClasses() -> PackedInt32Array {
        guard let world = self.world else { return PackedInt32Array() }
        var flat: [Int32] = [4]
        for npc in world.npcs where npc.isAlive {
            switch world.radarIFFClass(of: npc) {
            case .disabled: flat.append(0)
            case .threat: flat.append(1)
            case .squad: flat.append(2)
            case .other: flat.append(3)
            }
        }
        return PackedInt32Array(flat)
    }

    /// The player's chance (percent) that a radar refresh shows only static (OS-05).
    @Callable(autoSnakeCase: true) func radarStaticChance() -> Int {
        guard let world else { return 0 }
        return world.radarStaticChance(for: world.player)
    }

    // MARK: App shell

    /// The title-music file name from `STR# 130` #2 (`FUN_004ab5d0`), or "" when
    /// absent. The frontend does the file lookup (`OriginalAudio.musicCandidates`).
    @Callable(autoSnakeCase: true) func titleMusicName() -> String {
        game?.stringList(130)?.string(at: 2) ?? ""
    }

    // MARK: UI polish
    //
    // Original message lines and the generic `dësc` dialog's shared rules. The Apple
    // app posts these from GameScene.processWorldEvents / GameContainerView; the
    // lines ride the same status-line channel as the travel messages
    // (`drain_interaction_messages`). Nothing here is invented: every line is a
    // STR# 2002 entry (or the literal GameScene posts), and the frontend shows ONE line
    // that replaces the last, as MessageLogView does.

    /// Status-line lines for the world events GameScene narrates (called from
    /// collectEvents). Events the Apple app does not narrate (a target dying, a
    /// ship docking, ...) post nothing.
    private func polishNote(_ event: WorldEvent) {
        guard let game else { return }
        let strs = game.stringList(2002)
        switch event {
        case let .shipDisabled(entityID, _) where entityID == World.playerEntityID:
            post(strs?.string(at: 287) ?? "")                 // WP-03
        case .playerDying:
            post(strs?.string(at: 288) ?? "")                 // "Ship destroyed"
        case .playerDestroyed:
            post("Your ship has been destroyed.")
        case let .repairSystemEngaged(entityID) where entityID == World.playerEntityID:
            post(strs?.string(at: 37) ?? "")                  // OS-07
        case let .assistanceDelivered(entityID):
            post("\(world?.ship(id: entityID)?.name ?? "Ally") transfers fuel and makes repairs.")
        case let .escortRejoined(_, fighter):
            post(strs?.string(at: fighter ? 128 : 127) ?? "")
        case let .fighterRecoveredToBay(_, captured):
            post(strs?.string(at: captured ? 129 : 128) ?? "")
        case let .shipCapturedByNPC(_, _, stolenLine):
            if let stolenLine, let what = strs?.string(at: stolenLine), let tail = strs?.string(at: 374) {
                post(what + " " + tail)
            }
        case let .overlayMessage(text, frames):
            post(text, rawCalls: frames)   // a HailQuote runs 0x1a4 raw calls
        default:
            break
        }
    }

    /// The arrival line after a jump or gate (B1): the buoy, else "Arriving in the X system on
    /// <date>." Queued on the status-line channel like every other message.
    private func postArrivalLine(systemID: Int, gateID: Int?, abandonedFighters: Int) {
        guard let game, let line = StatusLineBackend.arrival(game: game, pilot: pilot, systemID: systemID,
                                                             gateID: gateID, abandonedFighters: abandonedFighters) else { return }
        post(line.text, rawCalls: line.rawCalls)
    }

    /// The pêrs HailQuote broadcast (B3; `GameScene.broadcastHailQuotes`, 0x00433050): ships and
    /// named pilots speak on the status line, 1 in 140 raw calls after a 45 s rest, gated by the
    /// pêrs flags. The shared broadcaster posts the world's overlay message; `polishNote` shows it.
    private func tickHailQuotes(dt: Double) {
        guard let world, let game, dockedSpobID == nil, world.player.isAlive, dt > 0 else { return }
        let engine = storyEngine()
        let quotes = statusLine.quotes.step(
            world: world, game: game, elapsed: dt, barBusy: statusLine.busy,
            grudge: { [pilot] in pilot.persHoldsGrudge($0) },
            hostile: { [weak self] in self?.isEffectivelyHostileToPlayer($0) ?? false },
            missionAvailable: { [pilot] pers in
                guard let engine else { return true }
                return PersEncounter.offeredMission(pers, player: pilot, game: game, engine: engine,
                                                    boarding: pers.offerMissionOnBoard) != nil
            },
            roll: { Double.random(in: 0..<1) })
        // (the world's own .overlayMessage event is cleared by the next step uncollected: post once, here)
        for q in quotes { post(q, rawCalls: PersQuoteBroadcaster.overlayFrames) }
    }

    /// The raw-call display length of a line the bridge posted with a non-default duration, popped
    /// (0 = the default 0xf0, ie `hud_message_seconds(0)`).
    @Callable(autoSnakeCase: true) func statusLineRawCalls(text: String) -> Int {
        statusLine.pop(text)
    }

    /// The frontend's message line is showing something: the HailQuote broadcast waits for it.
    @Callable(autoSnakeCase: true) func setStatusLineBusy(busy: Bool) { statusLine.busy = busy }

    /// Sound volume below 2 of 7: Red Alert then shows its cicn blink (`RedAlertCue`).
    @Callable(autoSnakeCase: true) func setAlertLowVolume(low: Bool) { statusLine.lowVolume = low }

    /// The Red Alert blink frame (cicn 18000 + this) while the indicator runs, else -1 (B6).
    @Callable(autoSnakeCase: true) func redAlertBlinkFrame() -> Int { sound.redAlert.blinkFrame ?? -1 }

    /// Per stellar body, SAME order as `body_transforms()`: `[r, g, b]` (0...1) of the radar ring
    /// when an IFF is fitted (`RadarIFF.stellarColor`, 0x00466030); empty without one (B7).
    @Callable(autoSnakeCase: true) func radarStellarColors() -> PackedFloat32Array {
        guard let world, let game, hudHasIff() else { return PackedFloat32Array() }
        var flat: [Float] = []
        let system = currentSystemID ?? -1
        for b in world.systemContext.bodies {
            guard let spob = game.spob(b.id) else { flat += [0.5, 0.5, 0.5]; continue }
            let c = RadarIFF.stellarColor(spob, state: pilot, game: game, system: system)
            flat += [Float(c.r) / 65535, Float(c.g) / 65535, Float(c.b) / 65535]
        }
        return PackedFloat32Array(flat)
    }

    /// How long a status-line message stays up, seconds: `rawCalls` of the
    /// original's raw sim calls (`GameHUDModel.post`; 0xf0 = the default, about 5 s).
    @Callable(autoSnakeCase: true) func hudMessageSeconds(rawCalls: Int) -> Double {
        Double(rawCalls <= 0 ? 0xf0 : rawCalls) * OriginalClock.rawCallSeconds
    }

    /// Classic star-map marker ring colour per drawable system: rows of `[id, r, g, b]`
    /// (0...1). The class rule (`OriginalMapMarker`) is shared with `GalaxyMapView`.
    @Callable(autoSnakeCase: true) func navMarkerColors() -> PackedFloat32Array {
        guard let game, let nv = navigator() else { return PackedFloat32Array() }
        let known = knownSets()
        let adjacent = nv.adjacentToKnown(explored: known.explored, charted: known.charted)
        var flat: [Float] = []
        for s in game.systems() where !nav.hidden.contains(s.id) {
            let vis = StarMapNavigator.visibility(of: s.id, explored: known.explored, adjacent: adjacent, charted: known.charted)
            if vis == .unknown { continue }
            let kind = OriginalMapMarker.kind(system: s, state: pilot, game: game, visited: vis == .explored || vis == .chartered)
            let c = OriginalMapMarker.rgb(kind)
            flat += [Float(s.id), Float(c.r), Float(c.g), Float(c.b)]
        }
        return PackedFloat32Array(flat)
    }

    /// The About Nova text exactly as `AboutNovaText.text(game:)` builds it: the
    /// NovaSwift header (version, unofficial-port notice, repo) over `dësc` 32767
    /// with `<REG>` as "EV Nova Community". Carriage returns become newlines.
    @Callable(autoSnakeCase: true) func aboutNovaText(version: String) -> String {
        UIPolishBackend.aboutText(descText: game?.descText(32767) ?? "", version: version)
    }

    /// `dësc` text for the generic reader (`DescTextDialog`): `\r` -> `\n`, `<REG>` filled.
    @Callable(autoSnakeCase: true) func descDialogText(text: String) -> String {
        UIPolishBackend.descText(text)
    }

    /// The generic `dësc` dialog's ids and shrink rule as JSON:
    /// `{textDialog, pictDialog, top, body, bottom, backdrop, minText}`.
    @Callable(autoSnakeCase: true) func descDialogInfo() -> String {
        UIPolishBackend.descInfo()
    }

    /// `DescDialogLayout.shrink`: how far a text-only dialog shrinks (may be negative).
    @Callable(autoSnakeCase: true) func descDialogShrink(textHeight: Int, textItemHeight: Int) -> Int {
        DescDialogLayout.shrink(textHeight: textHeight, textItemHeight: textItemHeight)
    }
}

// MARK: Debug suite
//
// Internal (non-@Callable) accessors for `Debug.swift`'s `NovaDebug` class, which owns the whole
// dev-console / diagnostics / bug-report surface. They live here only because `world`, `game`,
// `pilot`, `travel` are `private` to this file; nothing here is game logic.

extension NovaWorld {
    var dbgWorld: World? { world }
    var dbgGame: NovaGame? { game }
    var dbgGalaxy: Galaxy? { galaxy }
    var dbgPilot: PlayerState {
        get { pilot }
        set { pilot = newValue }
    }
    var dbgSystemID: Int? { currentSystemID }
    var dbgDockedSpob: Int? { dockedSpobID }
    var dbgSelectedStellar: Int? { travel.selectedSpob }

    /// Select a stellar of the live system as the travel target (as clicking it would).
    func dbgSelectStellar(_ id: Int) -> Bool {
        guard stellarBody(id) != nil else { return false }
        selectStellar(id)
        return true
    }

    /// Autosave-style write of the live pilot (the Apple console's `pilot.save()`); false when
    /// no roster pilot is bound (throwaway pilot / demo).
    @discardableResult
    func dbgPersistPilot() -> Bool { writePilot(backup: false) }

    /// Rebuild the flight world around the pilot's (possibly changed) hull and outfits now.
    func dbgRebuildShip() { rebuildAfterShipSwap() }

    /// Status-line message (the one-line message log).
    func dbgPost(_ line: String) { post(line) }
}
