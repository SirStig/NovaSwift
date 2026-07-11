import Foundation
import NovaSwiftKit

/// Abstract control input. Touch, keyboard, game controllers **and the NPC AI**
/// all translate into this; the simulation only ever reads `ControlIntent`, never
/// raw input. An NPC's `AIBrain` produces exactly the same struct a player's
/// fingers do — that symmetry is what lets one flight model drive every ship.
public struct ControlIntent: Equatable {
    public var turnLeft = false
    public var turnRight = false
    public var thrust = false
    public var reverse = false      // reverse thrust / brake-to-stop assist
    public var afterburner = false  // burn fuel for a speed / accel boost
    public var firePrimary = false
    public var fireSecondary = false
    /// Absolute heading (radians, compass) to rotate toward — used by mouse,
    /// analog-stick aiming, and the AI. When set, it drives turning unless a
    /// discrete turnLeft/turnRight is also active (discrete input wins).
    public var desiredHeading: Double?
    public init() {}

    /// OR-merge several input sources into one intent (keyboard + touch +
    /// controller + mouse). Discrete turns win; otherwise the first supplied
    /// `desiredHeading` is used.
    public static func combined(_ sources: ControlIntent...) -> ControlIntent {
        var r = ControlIntent()
        for s in sources {
            r.turnLeft = r.turnLeft || s.turnLeft
            r.turnRight = r.turnRight || s.turnRight
            r.thrust = r.thrust || s.thrust
            r.reverse = r.reverse || s.reverse
            r.afterburner = r.afterburner || s.afterburner
            r.firePrimary = r.firePrimary || s.firePrimary
            r.fireSecondary = r.fireSecondary || s.fireSecondary
            if r.desiredHeading == nil { r.desiredHeading = s.desiredHeading }
        }
        // Two input sources disagreeing on turn direction cancel out in
        // `Ship.step` (net-zero turn) — this reads to a player as "turning is
        // broken" with nothing else to go on, so flag it. Log on change only:
        // this is a per-frame computed property (`InputController.intent`) and
        // would otherwise flood the log while the conflict persists.
        if r.turnLeft && r.turnRight {
            if !loggedTurnConflict {
                loggedTurnConflict = true
                Log.physics.debug("ControlIntent.combined: turnLeft and turnRight both set across combined sources — they cancel out to a net-zero turn")
            }
        } else {
            loggedTurnConflict = false
        }
        return r
    }
    /// One-shot flag backing the conflicting-turn-input log above.
    private static var loggedTurnConflict = false
}

/// Tuning that maps EV Nova's integer stat units into simulation units. Kept in
/// one place so flight feel can be adjusted without touching data decoding.
public struct FlightTuning {
    public var speedScale: Double      // stat → max px/sec
    public var accelScale: Double      // stat → px/sec²
    public var turnScale: Double       // stat → deg/sec
    public var dragPerSecond: Double   // gentle space drag so ships settle (0 = pure Newtonian)

    public static let `default` = FlightTuning(speedScale: 1.0, accelScale: 1.0,
                                               turnScale: 3.0, dragPerSecond: 0.0)
}

/// Derived, simulation-ready flight parameters for a ship.
public struct ShipStats {
    public let maxSpeed: Double        // px/sec
    public let acceleration: Double    // px/sec²
    public let turnRate: Double        // rad/sec
    public let rotationFrames: Int     // sprite frames for a full 360°

    public init(maxSpeed: Double, acceleration: Double, turnRate: Double, rotationFrames: Int = 36) {
        self.maxSpeed = maxSpeed
        self.acceleration = acceleration
        self.turnRate = turnRate
        self.rotationFrames = rotationFrames
    }

    /// Build from decoded ship stat integers (speed / accel / turnRate).
    public init(speed: Int, acceleration: Int, turnRate: Int,
                rotationFrames: Int = 36, tuning: FlightTuning = .default) {
        self.maxSpeed = Double(speed) * tuning.speedScale
        self.acceleration = Double(acceleration) * tuning.accelScale
        self.turnRate = Double(turnRate) * tuning.turnScale * .pi / 180.0
        self.rotationFrames = rotationFrames
    }
}

/// A moving ship in world space. `angle` is a compass heading in radians
/// (0 = up/north, increasing clockwise), matching EV Nova sprite frame 0.
///
/// Every ship — player or NPC — is a `Ship`. Combat state (shields/armor), a
/// faction (`government`), a weapon loadout, and an optional `brain` turn the
/// same body into an AI-controlled combatant. A `nil` brain means "driven from
/// the outside" (the player).
public final class Ship {
    public var position: Vec2
    public var velocity: Vec2
    public var angle: Double
    public let stats: ShipStats
    public let name: String

    /// Unique per-instance id assigned by the world (player == 0). Distinct from
    /// `shipTypeID`, which is the `shïp` resource id used for the sprite.
    public var entityID: Int = 0
    public var shipTypeID: Int = -1
    /// This hull's death-explosion `snd` id (from `shïp`'s breakup/final
    /// explosion → `bööm`), or nil if it has none.
    public var explosionSoundID: Int?
    /// Faction/government. Drives who this ship will fight (see `Diplomacy`).
    public var government: Int = independentGovt
    /// Collision radius (px). Set from the sprite size where known.
    public var radius: Double = 16
    /// This hull's real weapon exit points (from its `shän`), or nil when the
    /// data has none — firing then falls back to a point just ahead of centre.
    public var exitPoints: ShipExitPoints?

    // Combat state.
    public var maxShield: Double = 100
    public var shield: Double = 100
    public var maxArmor: Double = 100
    public var armor: Double = 100
    public var shieldRechargePerSec: Double = 8
    public var armorRechargePerSec: Double = 0
    public var weapons: [WeaponMount] = []

    /// The `wëap` id of the secondary weapon the player has selected to fire on
    /// the secondary trigger (EV Nova fires only the *chosen* secondary, not all
    /// of them at once). nil = not yet chosen; `effectiveSecondaryID` then falls
    /// back to the first secondary fitted. Ignored for AI ships, which fire every
    /// group their brain triggers.
    public var selectedSecondaryID: Int?

    /// Distinct secondary weapons fitted, in mount order — the cycle the player's
    /// weapon-switch control steps through. Point-defense mounts fire themselves,
    /// so they aren't selectable.
    public var secondaryWeaponIDs: [Int] {
        weapons.filter { $0.spec.isSecondary && !$0.spec.isPointDefense }.map { $0.spec.id }
    }

    /// The secondary id actually used when the secondary trigger is held: the
    /// player's selection, or the first secondary fitted if none chosen yet.
    public var effectiveSecondaryID: Int? {
        selectedSecondaryID ?? secondaryWeaponIDs.first
    }

    /// The mount for the effective secondary (drives the HUD weapon readout).
    public var effectiveSecondaryMount: WeaponMount? {
        guard let id = effectiveSecondaryID else { return nil }
        return weapons.first { $0.spec.id == id && $0.spec.isSecondary }
    }

    /// Step the selected secondary to the next/previous fitted secondary,
    /// wrapping. No-op when the ship carries fewer than two secondaries.
    public func cycleSecondary(forward: Bool) {
        let ids = secondaryWeaponIDs
        guard !ids.isEmpty else { selectedSecondaryID = nil; return }
        let current = effectiveSecondaryID ?? ids[0]
        let idx = ids.firstIndex(of: current) ?? 0
        let n = ids.count
        selectedSecondaryID = ids[forward ? (idx + 1) % n : (idx - 1 + n) % n]
    }

    /// World-space muzzle for exit point `index` of `exitType`, given the ship's
    /// live position/heading — the real hardpoint the shot leaves from.
    public func muzzle(exitType: WeaponExitType, index: Int) -> Vec2 {
        let nose = radius + 4
        guard let ep = exitPoints, exitType != .center else {
            return position + Vec2.heading(angle) * nose
        }
        return position + ep.muzzleOffset(type: exitType, index: index, angle: angle, nose: nose)
    }

    /// Convenience: the muzzle for `mount`'s current exit cursor.
    public func muzzle(for mount: WeaponMount) -> Vec2 {
        muzzle(exitType: mount.spec.exitType, index: mount.exitCursor)
    }

    /// EV Nova's `shïp.Strength` — relative combat power, used for the
    /// combat-odds check (`gövt.MaxOdds`) before an AI picks a fight.
    public var combatStrength: Double = 1
    /// Fraction of max armor at which a lethal hit disables this ship instead of
    /// destroying it outright. EV Nova: 33% by default, 10% if `shïp.Flags`
    /// bit 0x0010 is set. A one-time state transition, not a random roll —
    /// only ships not already disabled can cross it.
    public var disableArmorFraction: Double = 0.33
    /// `shïp.Flags2` 0x0080: "AI ships of this type will run away/dock if out
    /// of ammo for all ammo-using weapons."
    public var fleeWhenOutOfAmmo: Bool = false

    // Ionization: weapons can add `wëap.Ionization` charge on hit; once it
    // reaches `ionizeMax` the ship is "fully ionized" and "nearly immobilized"
    // (Bible) until the charge dissipates at `deionizePerSec`.
    public var ionCharge: Double = 0
    /// `shïp.IonizeMax` — 0 means this hull doesn't define the field (never
    /// considered ionized, rather than trivially "always ionized").
    public var ionizeMax: Double = 0
    public var deionizePerSec: Double = 0
    public var isIonized: Bool { ionizeMax > 0 && ionCharge >= ionizeMax }

    // Fuel — EV Nova's blue gauge. Spent by hyperspace jumps (100 per jump) and
    // by the afterburner; regenerates only if the hull/outfits grant it.
    public var maxFuel: Double = 0
    public var fuel: Double = 0
    public var fuelRegenPerSec: Double = 0
    /// Installed afterburner (nil = none).
    public var afterburner: Afterburner?
    /// True on frames the afterburner is actually burning (input + fuel present).
    public private(set) var afterburnerActive = false

    // Cargo hold: `cargoCapacity` tons total; `cargo` maps commodity id → tons.
    public var cargoCapacity: Int = 0
    public var cargo: [Int: Int] = [:]
    public var cargoUsed: Int { cargo.values.reduce(0, +) }
    public var cargoFree: Int { max(0, cargoCapacity - cargoUsed) }

    /// Credits aboard for plunder once disabled. -1 = not yet rolled; set to 0
    /// once the player has taken them, so re-boarding can't duplicate the haul.
    public var plunderCredits: Int = -1

    /// Whether the ship has enough fuel for one hyperspace jump.
    public var canJump: Bool { fuel >= ShipFuel.perJump }
    /// Spend one jump's fuel; returns false and spends nothing if too low.
    @discardableResult
    public func consumeJumpFuel() -> Bool {
        guard fuel >= ShipFuel.perJump else { return false }
        fuel -= ShipFuel.perJump
        return true
    }
    /// Load up to `tons` of commodity `id` into the hold; returns tons added.
    @discardableResult
    public func loadCargo(_ id: Int, tons: Int) -> Int {
        let n = min(max(0, tons), cargoFree)
        if n > 0 { cargo[id, default: 0] += n }
        return n
    }
    /// Remove up to `tons` of commodity `id`; returns tons removed.
    @discardableResult
    public func unloadCargo(_ id: Int, tons: Int) -> Int {
        let have = cargo[id] ?? 0
        let n = min(max(0, tons), have)
        if n > 0 { let left = have - n; cargo[id] = left > 0 ? left : nil }
        return n
    }

    // AI state.
    public var brain: AIBrain?
    /// The entity this ship is currently aiming at (for turrets / guided shots
    /// and HUD). Set by the brain each think().
    public var currentTargetID: Int?
    /// Indices into `weapons` of `loopSound` beam mounts currently held down —
    /// drives `.beamLoopStart`/`.beamLoopStop` so the renderer plays one real
    /// continuous loop per mount instead of retriggering a one-shot every
    /// reload tick (up to 10×/sec) while the trigger is held.
    var activeBeamLoopMounts: Set<Int> = []
    /// The brain requests hyperspace departure; the world despawns it past the
    /// system edge.
    public var wantsToDepart = false
    /// The brain has flown this ship into a stellar object to land; the world
    /// removes it (into the planet) and fires a `shipLanded` event.
    public var wantsToLand = false
    /// The stellar object being landed on (paired with `wantsToLand`).
    public var landingSpob: Int?

    // Hyperspace entry over-speed: a ship tearing in from hyperspace briefly
    // travels above its cruise cap, then bleeds down to normal speed — that
    // decelerating inrush is what "warping in" looks like. `entryOverspeed` is
    // the extra px/sec allowed on top of the normal cap right now; it decays by
    // `entryOverspeedDecayPerSec` each second back to zero (set on a hyperspace
    // arrival, otherwise 0 and inert). Applied in `step` before the speed clamp.
    public var entryOverspeed: Double = 0
    public var entryOverspeedDecayPerSec: Double = 0

    /// A drifting hulk: armor was knocked out but the ship wasn't destroyed. It
    /// carries no thrust or weapons and other ships leave it be; further damage
    /// finishes it off. Set by the world's damage handler.
    public var disabled = false
    /// Idle tumble (rad/sec) applied to a disabled hulk so it drifts believably.
    public var disableSpin: Double = 0
    /// Seconds a hulk has been drifting; the world eventually clears cold wrecks.
    public var disabledClock: Double = 0

    // Diagnostics: last known-good motion state (NaN/Infinity guard) and
    // one-shot flags so we log state *transitions*, never every frame.
    private var lastFinitePosition = Vec2()
    private var loggedFuelEmpty = false
    private var loggedCanJump: Bool?
    private var loggedNoBrain = false

    public var isPlayer: Bool { entityID == 0 }
    public var isAlive: Bool { armor > 0 }
    /// 0…1 overall health, shields included, for morale/retreat decisions.
    public var healthFraction: Double {
        let maxTotal = maxShield + maxArmor
        return maxTotal > 0 ? (shield + armor) / maxTotal : 0
    }
    public var armorFraction: Double { maxArmor > 0 ? armor / maxArmor : 0 }
    public var shieldFraction: Double { maxShield > 0 ? shield / maxShield : 0 }

    public init(name: String, stats: ShipStats, position: Vec2 = Vec2(), angle: Double = 0) {
        self.name = name
        self.stats = stats
        self.position = position
        self.velocity = Vec2()
        self.angle = angle
        self.lastFinitePosition = position
    }

    /// The sprite frame index (0..<rotationFrames) for the current heading.
    public var spriteFrame: Int {
        let n = stats.rotationFrames
        guard n > 0 else { return 0 }
        let twoPi = 2 * Double.pi
        var a = angle.truncatingRemainder(dividingBy: twoPi)
        if a < 0 { a += twoPi }
        return Int((a / twoPi * Double(n)).rounded()) % n
    }

    // MARK: Combat helpers

    /// Apply damage: shields first, then armor bleed-through. Returns true if the
    /// hit destroyed the ship.
    @discardableResult
    public func applyDamage(shield dmgShield: Double, armor dmgArmor: Double) -> Bool {
        // A shot's shield and armor damage are separate figures in EV Nova; when
        // shields are up they soak the shield-damage, and leftover proportion
        // carries into armor.
        if shield > 0 {
            let before = shield
            shield = max(0, shield - dmgShield)
            let soakedFraction = dmgShield > 0 ? (before - shield) / dmgShield : 1
            let leftover = dmgArmor * (1 - soakedFraction)
            if leftover > 0 { armor = max(0, armor - leftover) }
        } else {
            armor = max(0, armor - dmgArmor)
        }
        return armor <= 0
    }

    func regen(_ dt: Double) {
        if shield < maxShield { shield = min(maxShield, shield + shieldRechargePerSec * dt) }
        if armor < maxArmor && armorRechargePerSec > 0 {
            armor = min(maxArmor, armor + armorRechargePerSec * dt)
        }
        if fuel < maxFuel && fuelRegenPerSec > 0 {
            fuel = min(maxFuel, fuel + fuelRegenPerSec * dt)
        }
        if ionCharge > 0 { ionCharge = max(0, ionCharge - deionizePerSec * dt) }
        logFuelTransitions()
    }

    /// Log-on-change fuel/jump-capability transitions — called after anything
    /// that can move `fuel` (afterburner drain in `step`, regen here). Cheap
    /// per-call comparison against stored previous state, not per-frame spam.
    private func logFuelTransitions() {
        let shipName = name, shipID = entityID
        if fuel <= 0 {
            if !loggedFuelEmpty {
                loggedFuelEmpty = true
                Log.physics.debug("Ship \(shipName) [\(shipID)] fuel depleted (0)")
            }
        } else {
            loggedFuelEmpty = false
        }
        let nowCanJump = canJump
        if loggedCanJump != nowCanJump {
            loggedCanJump = nowCanJump
            let curFuel = fuel
            Log.physics.debug("Ship \(shipName) [\(shipID)] canJump -> \(nowCanJump) (fuel=\(curFuel))")
        }
    }

    /// NaN/Infinity guard. A silent non-finite position or velocity presents
    /// with no other symptom than "ship won't move" or "ship flies off
    /// forever" — this is the single most valuable physics log there is. Logs
    /// loudly and recovers to the last known-good position rather than let a
    /// NaN silently propagate through the whole simulation.
    private func guardFiniteMotion() {
        if position.x.isFinite, position.y.isFinite,
           velocity.x.isFinite, velocity.y.isFinite {
            lastFinitePosition = position
            return
        }
        let shipName = name, shipID = entityID
        let badPos = position, badVel = velocity
        Log.physics.error("Ship \(shipName) [\(shipID)] non-finite motion detected — position=(\(badPos.x), \(badPos.y)) velocity=(\(badVel.x), \(badVel.y)); resetting to last known-good position and zeroing velocity")
        position = lastFinitePosition
        velocity = Vec2()
    }

    /// One-shot: an NPC with no `AIBrain` drifts under zero control input
    /// forever — exactly the "NPC just sits there" symptom. Called by
    /// `World.step` the first time it finds a brainless, living NPC.
    func logNoBrainOnce() {
        guard !loggedNoBrain else { return }
        loggedNoBrain = true
        let shipName = name, shipID = entityID
        Log.ai.debug("NPC \(shipName) [\(shipID)] has no AIBrain attached — will drift with zero control input")
    }

    func step(_ dt: Double, intent: ControlIntent, tuning: FlightTuning) {
        // Fully ionized: "nearly immobilized" (Bible) — no active turning or
        // thrust until the charge dissipates below `ionizeMax`. Existing
        // momentum still coasts (drag/speed-clamp/position below still run).
        let controllable = !isIonized
        let maxTurn = stats.turnRate * dt
        if controllable, intent.turnLeft || intent.turnRight {
            if intent.turnLeft { angle -= maxTurn }
            if intent.turnRight { angle += maxTurn }
        } else if controllable, let target = intent.desiredHeading {
            // Rotate toward the target heading, clamped to this frame's turn budget.
            let twoPi = 2 * Double.pi
            var delta = (target - angle).truncatingRemainder(dividingBy: twoPi)
            if delta > .pi { delta -= twoPi }
            if delta < -.pi { delta += twoPi }
            angle += max(-maxTurn, min(maxTurn, delta))
        }

        // Afterburner: while lit and fuelled, boost acceleration and raise the
        // speed cap, draining fuel. EV Nova's afterburner is a held control.
        var accel = stats.acceleration
        var topSpeed = stats.maxSpeed
        afterburnerActive = false
        if controllable, intent.afterburner, let ab = afterburner, fuel > 0 {
            afterburnerActive = true
            accel *= ab.accelMultiplier
            topSpeed *= ab.speedMultiplier
            fuel = max(0, fuel - ab.fuelPerSecond * dt)
            logFuelTransitions()
        }

        let heading = Vec2.heading(angle)
        if controllable, intent.thrust { velocity += heading * (accel * dt) }
        if controllable, intent.reverse { velocity += heading * (-stats.acceleration * 0.5 * dt) }

        if tuning.dragPerSecond > 0 {
            let k = max(0, 1 - tuning.dragPerSecond * dt)
            velocity = velocity * k
        }
        // Hyperspace-entry over-speed: allow briefly exceeding cruise, decaying
        // to zero, so a jump-in decelerates in rather than snapping to cruise.
        if entryOverspeed > 0 {
            topSpeed += entryOverspeed
            entryOverspeed = max(0, entryOverspeed - entryOverspeedDecayPerSec * dt)
        }
        // Clamp to max speed (raised while the afterburner is lit / entering).
        let speed = velocity.length
        if speed > topSpeed, speed > 0 {
            velocity = velocity.normalized * topSpeed
        }
        position += velocity * dt
        guardFiniteMotion()
    }
}

/// The live game simulation. Owns the player ship, the NPC ships, and their
/// projectiles, and advances everything deterministically from the current
/// `intent` (player) and each NPC's `brain`. Rendering reads state and drains
/// `events`; it never mutates the simulation.
public final class World {
    /// The player ship's fixed entity id. Escorts carry this as their `leaderID`.
    public static let playerEntityID = 0

    public var player: Ship
    public var intent = ControlIntent()
    public var tuning: FlightTuning
    public var combatTuning: CombatTuning

    /// Live NPC ships (does not include the player).
    public private(set) var npcs: [Ship] = []
    public private(set) var projectiles: [Projectile] = []
    /// Live beam segments the renderer mirrors each frame. Continuous beams are
    /// welded to their shooter (geometry recomputed every step); pulse beams are
    /// brief flashes. See `refreshActiveBeams`.
    public private(set) var activeBeams: [ActiveBeam] = []
    /// Transient render/audio events produced this step; drain after `step`.
    public private(set) var events: [WorldEvent] = []

    /// Diplomacy table (governments & player standing). Optional so a bare
    /// physics world still works; when nil, nobody is hostile.
    public var diplomacy: Diplomacy?
    /// The system's stellar geometry (planets, jump radius) for AI navigation.
    public var systemContext = SystemContext()
    /// Catalog used to instantiate NPC ships & weapons. Optional for physics-only.
    public var galaxy: Galaxy?
    /// Populates and refreshes the NPC population.
    public var spawner: Spawner?

    /// Live asteroids (real `röid` rocks, from the system's `sÿst.Asteroids`/
    /// `AstTypes` fields). Stationary — see `Asteroid`'s doc comment.
    public private(set) var asteroids: [Asteroid] = []

    public var rng = SplitMix64(seed: 0xE7_0A_5EED)
    private var nextEntityID = 1
    private var nextAsteroidID = 1

    /// Time before any authority ship will pick the player as a scan mark
    /// again. Each `AIBrain`'s own `scanCooldown` only throttles that one
    /// ship, so a busy system with several patrols could otherwise chain-scan
    /// the player back-to-back as each ship's individual cooldown expired.
    /// Set on every player scan; checked by `AIBrain.pickScanTarget`.
    public var playerScanCooldown: Double = 0

    public init(player: Ship, tuning: FlightTuning = .default,
                combatTuning: CombatTuning = .default) {
        self.player = player
        self.tuning = tuning
        self.combatTuning = combatTuning
        player.entityID = 0
        refreshRoster()
    }

    // MARK: Roster

    /// Every live ship, player first. Handy for AI perception. Refreshed once
    /// per `step()` by `refreshRoster()` rather than recomputed on each access —
    /// this is read many times per frame (every NPC's perception, every
    /// projectile/beam hit-scan), and rebuilding `[player] + npcs` on every one
    /// of those reads was a real per-frame allocation cost with several ships
    /// in a fight.
    public private(set) var allShips: [Ship] = []
    private var shipByID: [Int: Ship] = [:]

    /// Rebuild the cached roster + id index. Call after anything that can add
    /// or remove ships this frame (spawner, despawn) and before any code reads
    /// `allShips`/`ship(id:)`.
    private func refreshRoster() {
        allShips = [player] + npcs
        shipByID = Dictionary(uniqueKeysWithValues: allShips.map { ($0.entityID, $0) })
    }

    /// O(1) id → ship lookup (was a linear scan over `npcs`, called from
    /// several hot per-frame sites: AI target validation, fire-weapons target
    /// lookup, guided-projectile steering).
    public func ship(id: Int) -> Ship? { shipByID[id] }

    /// How a new NPC came into being, so the renderer can play the right effect:
    /// a mid-system populate (no effect), a hyperspace jump-in (warp streak at the
    /// edge), or a lift-off from a planet (grows out of the stellar).
    public enum ArrivalMode { case populate, hyperspace, launch }

    /// Add an NPC, assigning it a fresh entity id. Returns the id.
    @discardableResult
    public func addNPC(_ ship: Ship, arrival: ArrivalMode = .populate) -> Int {
        ship.entityID = nextEntityID
        nextEntityID += 1
        npcs.append(ship)
        switch arrival {
        case .populate:
            events.append(.shipArrived(entityID: ship.entityID, at: ship.position, fromHyperspace: false))
        case .hyperspace:
            // A hyperspace jump-in isn't a standing start: the ship tears in along
            // its inbound heading well above cruise, then its AI brakes down to
            // normal speed. That physical inrush — not just a fade/scale pop — is
            // what reads as "warping in." Capped so a very fast hull doesn't shoot
            // clear across the system before it can slow.
            let inbound = Vec2(sin(ship.angle), cos(ship.angle))
            let entrySpeed = min(ship.stats.maxSpeed * 2.4, 3200)
            ship.velocity = inbound * entrySpeed
            // Let the speed cap start at the entry speed and bleed back to cruise
            // over ~1.3s, so the ship visibly rushes in and slows down.
            ship.entryOverspeed = max(0, entrySpeed - ship.stats.maxSpeed)
            ship.entryOverspeedDecayPerSec = ship.entryOverspeed / 1.3
            events.append(.shipArrived(entityID: ship.entityID, at: ship.position, fromHyperspace: true))
        case .launch:
            events.append(.shipLaunched(entityID: ship.entityID, at: ship.position))
        }
        refreshRoster()
        return ship.entityID
    }

    /// A government patrol/interceptor completed a scan pass on another ship.
    /// Called from `AIBrain.scan` when it closes to scan range; the renderer
    /// turns it into a visible scan sweep. Purely cosmetic in this engine —
    /// there's no contraband/ScanMask system yet to key consequences off.
    public func reportScan(scannerID: Int, targetID: Int, at: Vec2) {
        if targetID == 0 { playerScanCooldown = 60 }
        events.append(.shipScanned(scannerID: scannerID, targetID: targetID, at: at))
    }

    public func drainEvents() -> [WorldEvent] {
        let e = events
        events.removeAll(keepingCapacity: true)
        return e
    }

    /// Remove every NPC from the simulation at once, cleanly: stop any beam
    /// loops they were sounding, drop any target locks pointed at them, and
    /// refresh the roster. Unlike the per-frame despawn path this emits no
    /// wreck/depart effects — it's a hard reset of the population, used by the
    /// in-game debug suite's performance stress test to clear the field before
    /// (and after) flooding it with a controlled fleet. Live projectiles are
    /// left to expire on their own.
    public func removeAllNPCs() {
        for npc in npcs {
            stopAllBeamLoops(for: npc)
            clearTarget(npc.entityID)
        }
        npcs.removeAll()
        refreshRoster()
    }

    // MARK: Asteroids

    /// Scatter `count` real asteroids of the enabled `typeIDs` (a system's
    /// `sÿst.Asteroids`/`AstTypes`) around `systemContext.center`, in the same
    /// interior scatter band `Spawner` uses for ship placement
    /// (`300...(jumpRadius*0.6)`, `Spawner.swift`). Call once after
    /// `systemContext`/`galaxy` are set. Each rock picks a uniformly-random
    /// enabled type — the Bible's `AstTypes` only says which types are
    /// enabled, not a weighting — and looks up its real stats/sprite geometry.
    public func populateAsteroids(typeIDs: [Int], count: Int) {
        guard count > 0, !typeIDs.isEmpty, let game = galaxy?.game else { return }
        let minRadius = 300.0
        let maxRadius = max(minRadius + 1, systemContext.jumpRadius * 0.6)
        for _ in 0..<count {
            let typeID = typeIDs[rng.int(in: 0...(typeIDs.count - 1))]
            let bearing = rng.double(in: 0...(2 * Double.pi))
            let dist = rng.double(in: minRadius...maxRadius)
            let position = systemContext.center + Vec2.heading(bearing) * dist
            if let a = spawnAsteroid(typeID: typeID, at: position, game: game) {
                asteroids.append(a)
            }
        }
    }

    /// Build one asteroid of `typeID` at `position` with a random initial spin
    /// phase, looking up its real `röid` stats and `spïn` sprite geometry (for
    /// the physical radius). Returns nil if the type's data can't be resolved.
    private func spawnAsteroid(typeID: Int, at position: Vec2, game: NovaGame) -> Asteroid? {
        guard let roid = game.roid(typeID) else { return nil }
        let radius = game.spin(typeID + 672).map { Double($0.tileWidth) / 2 } ?? 24
        let angle = rng.double(in: 0...(2 * Double.pi))
        let a = Asteroid(id: nextAsteroidID, roidTypeID: typeID, position: position, angle: angle,
                         roid: roid, radius: radius, hpScale: combatTuning.hpScale)
        nextAsteroidID += 1
        return a
    }

    /// Destroy an asteroid: explosion effect, and — per its real `FragType1/2`/
    /// `FragCount` — spawn smaller sub-asteroids at the same position (±50%
    /// count, per the Bible). A "Huge" type naturally shrinks into whatever its
    /// own `FragType` points at (e.g. "Big"/"Medium"); no invented scale factor.
    private func destroyAsteroid(_ rock: Asteroid) {
        rock.isAlive = false
        events.append(.explosion(at: rock.position, radius: max(20, rock.radius * 1.2), soundID: nil))
        let fragTypes = [rock.fragType1, rock.fragType2].filter { $0 >= 128 }
        guard !fragTypes.isEmpty, rock.fragCount > 0, let game = galaxy?.game else { return }
        let n = rng.int(in: max(0, rock.fragCount - rock.fragCount / 2)...(rock.fragCount + rock.fragCount / 2))
        for _ in 0..<n {
            let typeID = fragTypes[rng.int(in: 0...(fragTypes.count - 1))]
            if let frag = spawnAsteroid(typeID: typeID, at: rock.position, game: game) {
                asteroids.append(frag)
            }
        }
    }

    // MARK: Step

    public func step(_ dt: Double) {
        events.removeAll(keepingCapacity: true)
        playerScanCooldown = max(0, playerScanCooldown - dt)

        spawner?.update(dt, world: self)
        refreshRoster()

        // Player: outside intent.
        fireWeapons(from: player, intent: intent)
        player.step(dt, intent: intent, tuning: tuning)

        // NPCs: each brain decides an intent. Disabled hulks don't think — they
        // just tumble and bleed off speed until they cool and drift away.
        for npc in npcs where npc.isAlive {
            if npc.disabled {
                npc.disabledClock += dt
                npc.velocity = npc.velocity * max(0, 1 - 0.35 * dt)
                npc.angle += npc.disableSpin * dt
                npc.position += npc.velocity * dt
                continue
            }
            let npcIntent: ControlIntent
            if let brain = npc.brain {
                npcIntent = brain.think(ship: npc, world: self, dt: dt)
            } else {
                npc.logNoBrainOnce()
                npcIntent = ControlIntent()
            }
            fireWeapons(from: npc, intent: npcIntent)
            npc.step(dt, intent: npcIntent, tuning: tuning)
        }

        // Cooldowns & regen (hulks recover nothing).
        for s in allShips {
            for w in s.weapons { w.tick(dt) }
            if !s.disabled { s.regen(dt) }
        }

        // Asteroids don't move (see `Asteroid`'s doc comment) — they only spin.
        for rock in asteroids where rock.isAlive {
            rock.angle += rock.angularVelocityDegPerSec * .pi / 180.0 * dt
        }

        runPointDefense()
        stepProjectiles(dt)
        despawnDepartedAndDead()
        // Ships have moved this step; weld continuous beams to their new
        // positions/headings and expire pulse-beam flashes.
        refreshActiveBeams(dt)
    }

    /// Guidance 9/10 mounts (`WeapRes.isPointDefense`): "fires automatically at
    /// incoming guided weapons and nearby ships" (Bible) — a targeting loop
    /// independent of the ship's own `currentTargetID`. Simplified to an
    /// instant intercept (destroys the incoming shot outright) rather than
    /// simulating a PD sub-projectile chasing it down; a shot's `Durability`
    /// (hits-to-kill) isn't modeled.
    private func runPointDefense() {
        for ship in allShips where ship.isAlive && !ship.disabled {
            for mount in ship.weapons where mount.spec.isPointDefense {
                guard mount.ready else { mount.logBlockedIfNeeded(for: ship); continue }
                let incoming = projectiles.filter { p in
                    p.alive && p.homing && p.vulnerableToPD
                        && canHit(owner: p.ownerID, ownerGovt: p.ownerGovt, victim: ship)
                        && (p.position - ship.position).length <= mount.spec.range
                }
                guard let target = incoming.min(by: {
                    ($0.position - ship.position).length < ($1.position - ship.position).length
                }) else { continue }
                target.alive = false
                mount.didFire(shots: 1)
                events.append(.weaponFired(shooterID: ship.entityID, at: ship.position,
                                           heading: (target.position - ship.position).angle,
                                           soundID: mount.spec.fireSoundID))
                events.append(.explosion(at: target.position, radius: 10, soundID: nil))
                Log.combat.debug("\(ship.name) [\(ship.entityID)] point defense shot down an incoming projectile")
            }
        }
    }

    // MARK: Weapons

    private func fireWeapons(from ship: Ship, intent: ControlIntent) {
        let primary = intent.firePrimary
        let secondary = intent.fireSecondary
        let anyTrigger = primary || secondary
        // NPCs only ever set `firePrimary`; let them fire every weapon group they
        // carry (guns AND missiles) whenever their brain wants to shoot.
        let isAI = ship.brain != nil
        updateBeamLoops(for: ship, primary: primary, secondary: secondary, isAI: isAI)
        guard anyTrigger, ship.isAlive else { return }
        let target = ship.currentTargetID.flatMap { self.ship(id: $0) }

        for (mountIndex, mount) in ship.weapons.enumerated() {
            let spec = mount.spec
            // Point-defense mounts fire themselves via `runPointDefense`.
            if spec.isPointDefense { continue }
            // Fire-group gating: guns on the primary trigger, missiles/rockets on
            // the secondary. NPCs fire everything on whichever trigger their AI
            // held. The player fires only the *selected* secondary, not every
            // secondary at once (EV Nova's secondary-weapon selection).
            let triggered: Bool
            if isAI {
                triggered = anyTrigger
            } else if spec.isSecondary {
                triggered = secondary && spec.id == ship.effectiveSecondaryID
            } else {
                triggered = primary
            }
            guard triggered else { continue }
            // Reload not ready / dry on ammo: the classic invisible "why didn't
            // my weapon fire" bug. Logged once per block-reason transition.
            guard mount.ready else {
                mount.logBlockedIfNeeded(for: ship)
                continue
            }
            // Seeker 0x0020: this guided weapon refuses to fire while its own
            // ship is fully ionized.
            if spec.cantFireWhileIonized && ship.isIonized { continue }

            // A group fires ONE barrel per event (cycling exit points) — unless
            // it has the "fire simultaneously" flag, which volleys all `count`.
            let barrels = max(1, mount.count)
            let shots = spec.fireSimultaneously ? barrels : 1
            var fired = 0
            for k in 0..<shots {
                let exitIndex = spec.fireSimultaneously ? k : mount.exitCursor
                let muzzle = ship.muzzle(exitType: spec.exitType, index: exitIndex)
                // Nil = can't fire (turret/quadrant with no target in arc): hold fire.
                guard var aim = fireAngle(for: spec, ship: ship, muzzle: muzzle, target: target) else { continue }
                if spec.accuracyRadians > 0 && !spec.firesAtFixedAngle {
                    aim += rng.double(in: -spec.accuracyRadians...spec.accuracyRadians)
                }
                if spec.isBeam {
                    fireBeam(from: ship, mount: mount, mountIndex: mountIndex, spec: spec, aim: aim, target: target)
                } else {
                    spawnProjectile(spec: spec, muzzle: muzzle, aim: aim,
                                    ownerID: ship.entityID, ownerGovt: ship.government,
                                    ownerVelocity: ship.velocity,
                                    targetID: spec.homes ? ship.currentTargetID : nil,
                                    subDepth: 0)
                    events.append(.weaponFired(shooterID: ship.entityID, at: muzzle, heading: aim, soundID: spec.fireSoundID))
                }
                fired += 1
                if !spec.fireSimultaneously { mount.exitCursor = (mount.exitCursor + 1) % barrels }
            }
            // Only spend the reload/ammo if a shot actually left (a turret with no
            // target produces `fired == 0` and stays ready).
            if fired > 0 { mount.didFire(shots: fired) }
        }
    }

    /// The world angle a weapon fires at this frame given its guidance, or nil if
    /// it can't fire (turret/quadrant with no target in arc). Mirrors EV Nova /
    /// NovaJS: turrets and in-arc quadrant guns lead the moving target; guided,
    /// rockets, and plain guns fire along the hull heading (the projectile does
    /// any homing itself).
    private func fireAngle(for spec: WeaponSpec, ship: Ship, muzzle: Vec2, target: Ship?) -> Double? {
        switch spec.guidance {
        case .turret, .beamTurret:
            guard let t = target else { return nil }
            return leadAngle(from: muzzle, shooterVel: ship.velocity, target: t,
                             shotSpeed: spec.projectileSpeed, instantHit: spec.isBeam)
        case .frontQuadrant, .rearQuadrant:
            let base = spec.guidance == .rearQuadrant ? ship.angle + .pi : ship.angle
            guard let t = target else { return base }
            let q = quadrant(source: ship.position, facing: ship.angle, target: t.position)
            let inArc = (spec.guidance == .frontQuadrant && q == .front)
                     || (spec.guidance == .rearQuadrant && q == .rear)
            return inArc ? leadAngle(from: muzzle, shooterVel: ship.velocity, target: t,
                                     shotSpeed: spec.projectileSpeed, instantHit: false) : base
        default:
            // guided / rocket / plain gun / plain beam: along the hull heading.
            return ship.angle
        }
    }

    enum FireQuadrant { case front, sides, rear }
    private func quadrant(source: Vec2, facing: Double, target: Vec2) -> FireQuadrant {
        let rel = abs(angleDelta(from: facing, to: (target - source).angle))
        if rel < .pi / 4 { return .front }
        if rel > 3 * .pi / 4 { return .rear }
        return .sides
    }

    /// First-order intercept ("lead"): the world angle to fire a shot of
    /// `shotSpeed` so it meets a moving target. Falls back to aiming straight at
    /// the target when there's no real solution (or the shot is an instant-hit
    /// beam). Ported from NovaJS `guidance.ts` `firstOrderWithFallback`.
    private func leadAngle(from origin: Vec2, shooterVel: Vec2, target: Ship,
                           shotSpeed: Double, instantHit: Bool) -> Double {
        let straight = (target.position - origin).angle
        guard !instantHit, shotSpeed > 0 else { return straight }
        let pos = (target.position - origin) * (1.0 / shotSpeed)
        let vel = (target.velocity - shooterVel) * (1.0 / shotSpeed)
        let a = vel.dot(vel) - 1
        let b = 2 * pos.dot(vel)
        let c = pos.dot(pos)
        var time: Double?
        if abs(a) < 1e-9 {
            if abs(b) > 1e-9 { let t = -c / b; if t >= 0 { time = t } }
        } else {
            let det = b * b - 4 * a * c
            if det >= 0 {
                let s = det.squareRoot()
                time = [(-s - b) / (2 * a), (s - b) / (2 * a)].filter { $0 >= 0 }.sorted().first
            }
        }
        guard let t = time else { return straight }
        return (pos + vel * t).angle
    }

    /// Build and register a projectile (primary shot or submunition). Movement
    /// follows guidance: guided homes inertialessly, rockets accelerate from the
    /// owner's velocity, everything else inherits the owner's velocity plus the
    /// muzzle vector.
    @discardableResult
    private func spawnProjectile(spec: WeaponSpec, muzzle: Vec2, aim: Double,
                                 ownerID: Int, ownerGovt: Int, ownerVelocity: Vec2,
                                 targetID: Int?, subDepth: Int) -> Projectile {
        let dir = Vec2.heading(aim)
        let homing = spec.homes
        let accelerating = spec.accelerates
        let vel: Vec2
        if homing { vel = dir * spec.projectileSpeed }
        else if accelerating { vel = ownerVelocity }
        else { vel = ownerVelocity + dir * spec.projectileSpeed }
        let life = spec.range / max(1, spec.projectileSpeed)
        let p = Projectile(position: muzzle, velocity: vel, life: life,
                           shieldDamage: spec.shieldDamage, armorDamage: spec.armorDamage,
                           blastRadius: spec.blastRadius, ownerID: ownerID, ownerGovt: ownerGovt,
                           homing: homing, turnRate: spec.turnRate, speed: spec.projectileSpeed,
                           targetID: homing ? targetID : nil,
                           vulnerableToPD: spec.vulnerableToPD, ionization: spec.ionization,
                           accelerating: accelerating, facing: aim,
                           decayPerSec: spec.decayPerSec, proxRadius: spec.proxRadius,
                           proxSafetyRemaining: spec.proxSafetySeconds, proxHitAll: spec.proxHitAll,
                           detonateOnExpire: spec.detonateOnExpire, impact: spec.impact,
                           submunition: spec.submunition, subDepth: subDepth,
                           explosionBoomID: spec.explosionBoomID,
                           graphicSpinID: spec.graphicSpinID, spinShots: spec.spinShots)
        projectiles.append(p)
        return p
    }

    /// Nearest hittable ship to `pos` (for submunitions that seek the nearest
    /// valid target). Skips the owner and its own faction.
    private func nearestHostile(to pos: Vec2, ownerID: Int, ownerGovt: Int) -> Ship? {
        var best: Ship?
        var bestD = Double.greatestFiniteMagnitude
        for other in allShips where other.isAlive {
            guard canHit(owner: ownerID, ownerGovt: ownerGovt, victim: other) else { continue }
            let d = (other.position - pos).length
            if d < bestD { bestD = d; best = other }
        }
        return best
    }

    /// Start/stop a real audio loop for each `loopSound` beam mount as its
    /// ship's trigger is held/released — independent of the reload tick, so a
    /// continuous-fire beam sounds like one sustained loop rather than a
    /// one-shot sample retriggered up to 10×/sec while held. Also creates/removes
    /// the persistent `ActiveBeam` whose geometry `refreshActiveBeams` welds to
    /// the ship every frame.
    private func updateBeamLoops(for ship: Ship, primary: Bool, secondary: Bool, isAI: Bool) {
        for (idx, mount) in ship.weapons.enumerated() where mount.spec.isBeam && mount.spec.loopSound {
            // A continuous beam loops while its own fire group's trigger is held.
            let held = isAI ? (primary || secondary) : (mount.spec.isSecondary ? secondary : primary)
            let looping = ship.activeBeamLoopMounts.contains(idx)
            if held && ship.isAlive {
                if !looping {
                    ship.activeBeamLoopMounts.insert(idx)
                    events.append(.beamLoopStart(shooterID: ship.entityID, mountIndex: idx,
                                                 soundID: mount.spec.fireSoundID))
                    spawnActiveBeam(for: ship, mount: mount, mountIndex: idx, continuous: true)
                }
            } else if looping {
                ship.activeBeamLoopMounts.remove(idx)
                events.append(.beamLoopStop(shooterID: ship.entityID, mountIndex: idx))
                removeActiveBeam(shooterID: ship.entityID, mountIndex: idx)
            }
        }
    }

    /// Stop any beam loops still active on `ship` — called wherever a ship
    /// stops being simulated (disabled, destroyed, landed, departed) since
    /// `fireWeapons` (the only other place loops stop) won't run for it again.
    private func stopAllBeamLoops(for ship: Ship) {
        guard !ship.activeBeamLoopMounts.isEmpty else { return }
        for idx in ship.activeBeamLoopMounts {
            events.append(.beamLoopStop(shooterID: ship.entityID, mountIndex: idx))
            removeActiveBeam(shooterID: ship.entityID, mountIndex: idx)
        }
        ship.activeBeamLoopMounts.removeAll()
    }

    /// Instant-hit beam fired this reload tick: apply damage along the ray from
    /// the mount's real exit point. Continuous beams keep their persistent
    /// `ActiveBeam` (refreshed each frame); pulse beams get a brief flash beam
    /// and their own fire sound.
    private func fireBeam(from ship: Ship, mount: WeaponMount, mountIndex: Int,
                          spec: WeaponSpec, aim: Double, target: Ship?) {
        let origin = ship.muzzle(for: mount)
        let dir = Vec2.heading(aim)
        let cast = beamCast(from: origin, dir: dir, range: spec.range, owner: ship)
        if let h = cast.hitShip {
            applyHit(to: h, shield: spec.shieldDamage, armor: spec.armorDamage, ownerID: ship.entityID,
                     ionization: spec.ionization)
        } else if let rock = cast.hitAsteroid {
            applyAsteroidHit(rock, shield: spec.shieldDamage, armor: spec.armorDamage)
        }
        let hit = cast.hitShip != nil || cast.hitAsteroid != nil
        if !spec.loopSound {
            // Pulse beam: a short-lived flash welded to the exit point. Continuous
            // beams instead keep the persistent ActiveBeam from updateBeamLoops.
            if let existing = activeBeams.first(where: { $0.shooterID == ship.entityID && $0.mountIndex == mountIndex && !$0.continuous }) {
                existing.from = origin; existing.to = cast.end; existing.hit = hit
                existing.life = 0.08
            } else {
                activeBeams.append(ActiveBeam(shooterID: ship.entityID, mountIndex: mountIndex,
                                              from: origin, to: cast.end, hit: hit,
                                              continuous: false, life: 0.08,
                                              width: spec.beamWidth, color: spec.beamColor))
            }
        }
        // Telemetry/audio event (renderer draws geometry from `activeBeams`, not
        // this). `loopSound` beams get their audio from beamLoopStart/Stop, so
        // they carry no one-shot id here.
        events.append(.beam(shooterID: ship.entityID, mountIndex: mountIndex, from: origin, to: cast.end,
                            hit: hit, soundID: spec.loopSound ? nil : spec.fireSoundID))
    }

    /// Raycast a beam of `range` px from `origin` along unit `dir`: the nearest
    /// hittable ship or asteroid, and the clipped endpoint.
    private func beamCast(from origin: Vec2, dir: Vec2, range: Double, owner: Ship)
        -> (end: Vec2, hitShip: Ship?, hitAsteroid: Asteroid?) {
        var bestT = range
        var hitShip: Ship?
        var hitAsteroid: Asteroid?
        for other in allShips where other.entityID != owner.entityID && other.isAlive {
            if !canHit(owner: owner.entityID, ownerGovt: owner.government, victim: other) { continue }
            let rel = other.position - origin
            let along = rel.dot(dir)
            guard along > 0, along <= range else { continue }
            let perp = (rel - dir * along).length
            if perp <= other.radius + 4 && along < bestT {
                bestT = along; hitShip = other; hitAsteroid = nil
            }
        }
        for rock in asteroids where rock.isAlive {
            let rel = rock.position - origin
            let along = rel.dot(dir)
            guard along > 0, along <= range else { continue }
            let perp = (rel - dir * along).length
            if perp <= rock.radius + 4 && along < bestT {
                bestT = along; hitAsteroid = rock; hitShip = nil
            }
        }
        let end = (hitShip != nil || hitAsteroid != nil) ? origin + dir * bestT : origin + dir * range
        return (end, hitShip, hitAsteroid)
    }

    /// Create the persistent beam segment for a continuous mount (geometry is
    /// filled in immediately and refreshed every frame by `refreshActiveBeams`).
    private func spawnActiveBeam(for ship: Ship, mount: WeaponMount, mountIndex: Int, continuous: Bool) {
        guard !activeBeams.contains(where: { $0.shooterID == ship.entityID && $0.mountIndex == mountIndex }) else { return }
        let beam = ActiveBeam(shooterID: ship.entityID, mountIndex: mountIndex,
                              from: ship.position, to: ship.position, hit: false,
                              continuous: continuous, life: .infinity,
                              width: mount.spec.beamWidth, color: mount.spec.beamColor)
        activeBeams.append(beam)
        refreshBeam(beam)
    }

    private func removeActiveBeam(shooterID: Int, mountIndex: Int) {
        activeBeams.removeAll { $0.shooterID == shooterID && $0.mountIndex == mountIndex }
    }

    /// Recompute a continuous beam's geometry from its live shooter, so the beam
    /// stays welded to the moving, turning ship and re-clips to whatever it's
    /// now pointing at.
    private func refreshBeam(_ beam: ActiveBeam) {
        guard let ship = ship(id: beam.shooterID), ship.isAlive,
              beam.mountIndex < ship.weapons.count else { return }
        let mount = ship.weapons[beam.mountIndex]
        let spec = mount.spec
        let origin = ship.muzzle(for: mount)
        // Beams track the current target; otherwise they fire straight ahead.
        var aim = ship.angle
        if let tID = ship.currentTargetID, let t = self.ship(id: tID), t.isAlive {
            aim = (t.position - origin).angle
        }
        let cast = beamCast(from: origin, dir: Vec2.heading(aim), range: spec.range, owner: ship)
        beam.from = origin
        beam.to = cast.end
        beam.hit = cast.hitShip != nil || cast.hitAsteroid != nil
    }

    /// Advance all live beams once per step: weld continuous beams to their
    /// shooters (dropping any whose loop ended or shooter vanished) and count
    /// pulse beams down.
    private func refreshActiveBeams(_ dt: Double) {
        guard !activeBeams.isEmpty else { return }
        activeBeams.removeAll { beam in
            if beam.continuous {
                guard let ship = ship(id: beam.shooterID), ship.isAlive,
                      ship.activeBeamLoopMounts.contains(beam.mountIndex) else { return true }
                refreshBeam(beam)
                return false
            } else {
                beam.life -= dt
                return beam.life <= 0
            }
        }
    }

    /// Weapon → asteroid damage. Asteroids have no shields, so shield+armor
    /// damage both come off `hp` (scaled the same way ship armor is via
    /// `combatTuning`). Not modeling the wëap "x10 mass damage to asteroids"
    /// flag — that bit isn't decoded on `WeaponSpec` anywhere in this engine
    /// yet, so every weapon currently does its normal damage to rock.
    private func applyAsteroidHit(_ rock: Asteroid, shield: Double, armor: Double) {
        rock.hp -= (shield + armor) * combatTuning.damageScale
        if rock.hp <= 0 { destroyAsteroid(rock) }
    }

    // MARK: Projectiles

    private func stepProjectiles(_ dt: Double) {
        // Submunitions spawned this frame are collected and appended after the
        // loop so we don't mutate `projectiles` while iterating it.
        var spawned: [Projectile] = []
        for p in projectiles where p.alive {
            p.proxSafetyRemaining = max(0, p.proxSafetyRemaining - dt)

            // Movement by guidance.
            if p.homing {
                // Steer the heading toward the first-order intercept, then fly
                // inertialessly at cruise speed along it (EV Nova guided shots
                // don't drift — they point where they're going).
                if let tid = p.targetID, let t = ship(id: tid), t.isAlive {
                    let lead = leadAngle(from: p.position, shooterVel: p.velocity, target: t,
                                         shotSpeed: p.speed, instantHit: false)
                    var d = angleDelta(from: p.facing, to: lead)
                    let maxTurn = p.turnRate * dt
                    d = max(-maxTurn, min(maxTurn, d))
                    p.facing += d
                }
                p.velocity = Vec2.heading(p.facing) * p.speed
            } else if p.accelerating {
                // Rocket: accelerate forward up to cruise speed (reach it in ~0.5s).
                let along = Vec2.heading(p.facing)
                p.velocity += along * (p.speed / 0.5 * dt)
                if p.velocity.length > p.speed { p.velocity = p.velocity.normalized * p.speed }
            } else {
                p.facing = p.velocity.angle
            }
            p.position += p.velocity * dt

            // Power decay: the shot loses damage the longer it flies.
            if p.decayPerSec > 0 {
                p.shieldDamage = max(0, p.shieldDamage - p.decayPerSec * dt)
                p.armorDamage = max(0, p.armorDamage - p.decayPerSec * dt)
            }

            p.life -= dt
            if p.life <= 0 {
                p.alive = false
                detonate(p, at: p.position, directHit: nil, expired: true, spawned: &spawned)
                continue
            }

            // Collision — direct hit, or within the proximity radius once armed.
            guard p.proxSafetyRemaining <= 0 else { continue }
            let reach = p.proxRadius
            var struck: Ship?
            for other in allShips where other.isAlive {
                guard canHit(owner: p.ownerID, ownerGovt: p.ownerGovt, victim: other) else { continue }
                let dist = (other.position - p.position).length
                if dist <= other.radius {
                    struck = other; break
                }
                // Proximity fuse: detonate near a valid ship. When the shot only
                // arms on its own target, ignore proximity to anyone else.
                if reach > 0 && dist <= other.radius + reach {
                    if p.proxHitAll || p.targetID == nil || p.targetID == other.entityID {
                        struck = other; break
                    }
                }
            }
            if let h = struck {
                p.alive = false
                detonate(p, at: p.position, directHit: h, expired: false, spawned: &spawned)
                continue
            }

            for rock in asteroids where rock.isAlive {
                if (rock.position - p.position).length <= rock.radius + reach {
                    applyAsteroidHit(rock, shield: p.shieldDamage, armor: p.armorDamage)
                    p.alive = false
                    detonate(p, at: p.position, directHit: nil, expired: false, spawned: &spawned)
                    break
                }
            }
        }
        projectiles.append(contentsOf: spawned)
        projectiles.removeAll { !$0.alive }
        asteroids.removeAll { !$0.isAlive }
    }

    /// Resolve a shot ending: apply its direct/blast damage and knockback, emit
    /// the explosion effect, and launch any submunitions. `expired` distinguishes
    /// end-of-life (which only detonates flak / expiry-submunition shots) from a
    /// real hit.
    private func detonate(_ p: Projectile, at pos: Vec2, directHit: Ship?, expired: Bool,
                          spawned: inout [Projectile]) {
        if let h = directHit {
            applyHit(to: h, shield: p.shieldDamage, armor: p.armorDamage, ownerID: p.ownerID,
                     ionization: p.ionization)
            if p.impact > 0 {
                // Knockback along the shot's travel, inversely ∝ target size
                // (a proxy for mass — heavier hulls barely budge).
                h.velocity += p.velocity.normalized * (p.impact * 6.0 / max(4, h.radius))
            }
        }
        // Blast splash to everyone else in radius.
        if p.blastRadius > 0 {
            for splash in allShips where splash.isAlive && splash.entityID != directHit?.entityID {
                guard canHit(owner: p.ownerID, ownerGovt: p.ownerGovt, victim: splash) else { continue }
                if (splash.position - pos).length <= p.blastRadius {
                    applyHit(to: splash, shield: p.shieldDamage * 0.5, armor: p.armorDamage * 0.5,
                             ownerID: p.ownerID, ionization: p.ionization * 0.5)
                }
            }
        }
        // Explosion effect (skip a silent end-of-life fizzle for a plain shot
        // that isn't flak and has no blast).
        let shouldExplode = directHit != nil || p.blastRadius > 0 || p.detonateOnExpire || p.explosionBoomID != nil
        if shouldExplode {
            let boomSound = p.explosionBoomID.flatMap { galaxy?.game.boom($0)?.soundID }
            let radius = p.blastRadius > 0 ? p.blastRadius : 12
            events.append(.explosion(at: pos, radius: max(8, radius), soundID: boomSound))
        }
        // Submunitions: split into child weapons on detonation (and on expiry
        // when `subIfExpire`), capped by the recursion limit.
        if let sub = p.submunition, sub.count > 0, p.subDepth <= sub.limit,
           !(expired && !sub.ifExpire), let subSpec = galaxy?.weaponSpec(sub.weaponID) {
            for _ in 0..<sub.count {
                var aim = p.facing
                var subTarget = p.targetID
                if sub.fireAtNearest, let near = nearestHostile(to: pos, ownerID: p.ownerID, ownerGovt: p.ownerGovt) {
                    aim = subSpec.guidance == .guided ? aim : (near.position - pos).angle
                    subTarget = near.entityID
                }
                if sub.thetaRadians > 0 {
                    aim += rng.double(in: -sub.thetaRadians...sub.thetaRadians)
                }
                let child = spawnProjectile(spec: subSpec, muzzle: pos, aim: aim,
                                            ownerID: p.ownerID, ownerGovt: p.ownerGovt,
                                            ownerVelocity: Vec2(), targetID: subTarget,
                                            subDepth: p.subDepth + 1)
                // `spawnProjectile` appended to `projectiles`; move it to the
                // deferred list so we don't process it again this same frame.
                if projectiles.last === child { projectiles.removeLast(); spawned.append(child) }
            }
        }
    }

    /// Whether a shot from `owner` (faction `ownerGovt`) may damage `victim`.
    /// No self-hits and no friendly fire between the same government.
    private func canHit(owner: Int, ownerGovt: Int, victim: Ship) -> Bool {
        if victim.entityID == owner { return false }
        // Same government doesn't shoot itself (independents are fair game).
        if ownerGovt != independentGovt && victim.government == ownerGovt { return false }
        return true
    }

    private func applyHit(to ship: Ship, shield: Double, armor: Double, ownerID: Int,
                          ionization: Double = 0) {
        let hadShield = ship.shield > 0
        // Per-hit logging isn't gated like everything else in this file (no
        // "log on change/transition" here — every hit is its own event), and
        // splash damage can call this several times in the same instant for a
        // clustered group. Destroy/disable transitions already get their own
        // log lines below/at despawn, so a routine chip-damage hit doesn't
        // need one too — this was real, uncapped log volume that scaled
        // directly with how many ships were fighting.
        _ = ship.applyDamage(shield: shield, armor: armor)
        if ionization > 0, ship.ionizeMax > 0 {
            ship.ionCharge = min(ship.ionizeMax, ship.ionCharge + ionization)
        }
        events.append(hadShield ? .shieldHit(at: ship.position) : .armorHit(at: ship.position))

        // Player fire provokes the victim and dents the player's record.
        if ownerID == 0 && !ship.isPlayer {
            ship.brain?.provokedByPlayer = true
            if let dip = diplomacy, let gov = dip.govt(ship.government) {
                dip.recordCrime(against: ship.government, penalty: max(1, gov.shootPenalty))
            }
        }
        // NPC fire on player: let the player's would-be attacker be remembered.
        if !ship.isPlayer, ship.brain?.targetID == nil, ownerID != 0 {
            // (no-op hook for future player-side AI/escorts)
        }

        // EV Nova disables a ship the moment its armor crosses a fixed threshold
        // (`shïp.Flags` 0x0010 → 10%, otherwise 33% of max armor) — a one-time
        // deterministic state transition, not a random roll. Once already
        // disabled, further damage that zeroes armor is a real kill (handled by
        // `isAlive`/`despawnDepartedAndDead`, not here). The player is never
        // disabled this way (the app owns player death).
        if !ship.isPlayer, !ship.disabled, ship.armor <= ship.maxArmor * ship.disableArmorFraction {
            ship.disabled = true
            ship.armor = max(1, ship.maxArmor * 0.02)   // a sliver — still "alive"
            ship.shield = 0
            ship.disableSpin = rng.double(in: -0.5...0.5)
            ship.wantsToDepart = false
            ship.currentTargetID = nil
            ship.brain?.targetID = nil
            clearTarget(ship.entityID)               // everyone stops shooting it
            stopAllBeamLoops(for: ship)               // a hulk doesn't fire — stop its beam loop
            events.append(.shipDisabled(entityID: ship.entityID, at: ship.position))
            Log.combat.debug("\(ship.name) [\(ship.entityID)] disabled (armor at/below \(Int(ship.disableArmorFraction * 100))% threshold) — now a drifting hulk")
        }
    }

    // MARK: Despawn

    private func despawnDepartedAndDead() {
        var survivors: [Ship] = []
        for npc in npcs {
            if !npc.isAlive {
                events.append(.explosion(at: npc.position, radius: max(24, npc.radius * 1.5),
                                         soundID: npc.explosionSoundID))
                events.append(.shipDestroyed(entityID: npc.entityID, shipTypeID: npc.shipTypeID,
                                             at: npc.position))
                Log.combat.debug("\(npc.name) [\(npc.entityID)] destroyed (shipTypeID=\(npc.shipTypeID))")
                // Clear any targeting of the dead ship.
                clearTarget(npc.entityID)
                stopAllBeamLoops(for: npc)
                continue
            }
            // Landed on a stellar object → vanished into the spaceport (no wreck).
            if npc.wantsToLand, let sid = npc.landingSpob {
                events.append(.shipLanded(entityID: npc.entityID, spobID: sid, at: npc.position))
                clearTarget(npc.entityID)
                stopAllBeamLoops(for: npc)
                continue
            }
            // Departed past the system edge → gone to hyperspace.
            if npc.wantsToDepart {
                let d = (npc.position - systemContext.center).length
                if d >= systemContext.jumpRadius {
                    events.append(.shipDeparted(entityID: npc.entityID, at: npc.position,
                                                heading: npc.angle))
                    clearTarget(npc.entityID)
                    stopAllBeamLoops(for: npc)
                    continue
                }
            }
            // A cold hulk that's drifted long enough is quietly retired.
            if npc.disabled && npc.disabledClock > 25 {
                clearTarget(npc.entityID)
                stopAllBeamLoops(for: npc)
                continue
            }
            survivors.append(npc)
        }
        npcs = survivors
        refreshRoster()
        // Player death is left to the app (respawn / game-over UI).
    }

    private func clearTarget(_ id: Int) {
        if player.currentTargetID == id { player.currentTargetID = nil }
        for s in npcs where s.currentTargetID == id {
            s.currentTargetID = nil
            s.brain?.targetID = nil
        }
    }

    // MARK: Player target-lock

    /// Range (px) within which the player can lock a target — matches the
    /// default positional-audio falloff range, a reasonable "nearby" radius.
    public static let targetLockRange: Double = 3000

    /// Lock the nearest eligible ship within range (`hostileOnly` narrows to
    /// ships `diplomacy` considers hostile to the player). Reuses
    /// `player.currentTargetID`, so locking a target also makes the player's
    /// guided weapons track it. Returns the newly-locked ship, if any.
    @discardableResult
    public func selectNearestTarget(hostileOnly: Bool) -> Ship? {
        let candidates = npcs.filter { npc in
            npc.isAlive && !npc.disabled
                && (!hostileOnly || diplomacy?.isHostileToPlayer(npc.government) == true)
        }
        guard let nearest = candidates.min(by: {
            ($0.position - player.position).length < ($1.position - player.position).length
        }), (nearest.position - player.position).length <= Self.targetLockRange else {
            return nil
        }
        player.currentTargetID = nearest.entityID
        events.append(.targetAcquired(entityID: nearest.entityID))
        return nearest
    }

    /// Drop the player's current target lock, if any.
    public func clearPlayerTarget() {
        player.currentTargetID = nil
    }

    // MARK: Player escorts

    /// Ships currently under the player's command (captured or hired), i.e. AI
    /// ships whose fleet leader is the player.
    public var playerEscorts: [Ship] {
        npcs.filter { $0.isAlive && $0.brain?.leaderID == Self.playerEntityID }
    }

    /// Issue a standing order to the whole escort wing.
    public func setPlayerEscortOrder(_ order: EscortOrder) {
        for e in playerEscorts { e.brain?.escortOrder = order }
    }

    /// The current wing order (the most common one among escorts), or nil when
    /// the player has none — for the command window's selected state.
    public var playerEscortOrder: EscortOrder? {
        let orders = playerEscorts.compactMap { $0.brain?.escortOrder }
        guard let first = orders.first else { return nil }
        return orders.allSatisfy { $0 == first } ? first : nil
    }

    // MARK: Boarding / plunder

    /// What a disabled ship yields when boarded — its name, credits aboard, the
    /// cargo in its hold, and the odds of capturing it (nil = uncapturable).
    public struct BoardingManifest {
        public let shipID: Int
        public let name: String
        public let credits: Int
        public let cargo: [(commodity: Int, tons: Int)]
        public let captureChance: Int?   // percent, nil = can't be captured
    }

    /// The plunder a disabled ship offers, or nil if `shipID` isn't a boardable
    /// (alive + disabled) hulk. Deterministic per ship so re-opening the dialog
    /// shows the same haul.
    public func boardingManifest(for shipID: Int) -> BoardingManifest? {
        guard let s = ship(id: shipID), s !== player, s.isAlive, s.disabled else { return nil }
        let cargo = s.cargo.filter { $0.value > 0 }
            .map { (commodity: $0.key, tons: $0.value) }
            .sorted { $0.commodity < $1.commodity }
        // Tougher hulls are harder to take; the largest are uncapturable.
        let toughness = s.maxArmor + s.maxShield
        let chance: Int? = toughness > 2200 ? nil : max(5, min(85, 78 - Int(toughness / 40)))
        return BoardingManifest(shipID: shipID, name: s.name,
                                credits: rolledPlunderCredits(s), cargo: cargo, captureChance: chance)
    }

    /// Credits aboard a hulk, rolled once (deterministically from its identity +
    /// toughness) and cached on the ship.
    private func rolledPlunderCredits(_ s: Ship) -> Int {
        if s.plunderCredits < 0 {
            var h = UInt64(bitPattern: Int64(s.entityID &+ 1)) &* 0x9E3779B97F4A7C15
            h ^= UInt64(bitPattern: Int64(s.shipTypeID &+ 7)) &* 0xD1B54A32D192ED03
            let value = max(40, Int((s.maxArmor + s.maxShield) / 2))
            s.plunderCredits = value / 2 + Int(h % UInt64(max(1, value)))
        }
        return s.plunderCredits
    }

    /// Take the credits aboard a hulk (zeroing them so they can't be re-taken).
    public func takePlunderCredits(from shipID: Int) -> Int {
        guard let s = ship(id: shipID) else { return 0 }
        let c = rolledPlunderCredits(s)
        s.plunderCredits = 0
        return c
    }

    /// Move a hulk's cargo into the player's hold, limited by free space, and
    /// return what was actually taken (commodity id → tons).
    @discardableResult
    public func takePlunderCargo(from shipID: Int) -> [(commodity: Int, tons: Int)] {
        guard let s = ship(id: shipID) else { return [] }
        var taken: [(commodity: Int, tons: Int)] = []
        for (commodity, tons) in s.cargo.sorted(by: { $0.key < $1.key }) where tons > 0 {
            let room = player.cargoFree
            guard room > 0 else { break }
            let move = min(tons, room)
            player.cargo[commodity, default: 0] += move
            s.cargo[commodity]! -= move
            if s.cargo[commodity]! <= 0 { s.cargo[commodity] = nil }
            taken.append((commodity, move))
        }
        return taken
    }

    /// Attempt to capture a hulk given a 0–99 `roll` (supplied by the caller so
    /// the engine stays deterministic). On success the ship joins the player's
    /// escort wing. Returns whether it succeeded.
    public func attemptCapture(shipID: Int, roll: Int) -> Bool {
        guard let manifest = boardingManifest(for: shipID), let chance = manifest.captureChance,
              let s = ship(id: shipID) else { return false }
        guard roll < chance else { return false }
        recruitEscort(s)
        return true
    }

    /// Recruit `ship` as a player escort — ally it to the player, clear any
    /// hostility, and place it in the formation under a defensive order. Assigns
    /// the next free formation slot and gives it a brain if it somehow lacked one.
    public func recruitEscort(_ ship: Ship) {
        let brain = ship.brain ?? AIBrain(aiType: .warship, govt: player.government)
        ship.brain = brain
        ship.government = player.government
        brain.leaderID = Self.playerEntityID
        brain.escortOrder = .defensive
        brain.provokedByPlayer = false
        brain.formationSlot = playerEscorts.filter { $0.entityID != ship.entityID }.count
        ship.disabled = false
        ship.currentTargetID = nil
    }

    /// Lock a specific ship by id (click-to-select). Unlike
    /// `selectNearestTarget`, this allows disabled hulks (still valid targets
    /// for boarding) and has no range gate — if it's on screen, it's
    /// selectable.
    @discardableResult
    public func selectTarget(id: Int) -> Ship? {
        guard let ship = npcs.first(where: { $0.entityID == id }), ship.isAlive else { return nil }
        player.currentTargetID = id
        events.append(.targetAcquired(entityID: id))
        return ship
    }

    /// Apply a paid "Request Assistance" ally's delivery once it docks with
    /// the player: one jump's worth of fuel, and armor topped up to a safe
    /// floor if it's currently lower (never reduced if already healthier).
    public func deliverAssistance(from shipID: Int) {
        player.fuel = min(player.maxFuel, player.fuel + ShipFuel.perJump)
        let safeArmor = player.maxArmor * 0.4
        if player.armor < safeArmor { player.armor = safeArmor }
        events.append(.assistanceDelivered(entityID: shipID))
    }
}

// MARK: - Small vector angle helpers used across the AI/combat code

extension Vec2 {
    /// Compass heading (0 = north/up, clockwise) of this vector.
    public var angle: Double { atan2(x, y) }
    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
}

/// Shortest signed turn (radians) from heading `a` to heading `b`, in −π…π.
public func angleDelta(from a: Double, to b: Double) -> Double {
    let twoPi = 2 * Double.pi
    var d = (b - a).truncatingRemainder(dividingBy: twoPi)
    if d > .pi { d -= twoPi }
    if d < -.pi { d += twoPi }
    return d
}
