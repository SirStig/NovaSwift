import Foundation

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

    // Combat state.
    public var maxShield: Double = 100
    public var shield: Double = 100
    public var maxArmor: Double = 100
    public var armor: Double = 100
    public var shieldRechargePerSec: Double = 8
    public var armorRechargePerSec: Double = 0
    public var weapons: [WeaponMount] = []
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
        // Clamp to max speed (raised while the afterburner is lit).
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
    public var player: Ship
    public var intent = ControlIntent()
    public var tuning: FlightTuning
    public var combatTuning: CombatTuning

    /// Live NPC ships (does not include the player).
    public private(set) var npcs: [Ship] = []
    public private(set) var projectiles: [Projectile] = []
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

    public var rng = SplitMix64(seed: 0xE7_0A_5EED)
    private var nextEntityID = 1

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
            events.append(.shipArrived(entityID: ship.entityID, at: ship.position, fromHyperspace: true))
        case .launch:
            events.append(.shipLaunched(entityID: ship.entityID, at: ship.position))
        }
        refreshRoster()
        return ship.entityID
    }

    public func drainEvents() -> [WorldEvent] {
        let e = events
        events.removeAll(keepingCapacity: true)
        return e
    }

    // MARK: Step

    public func step(_ dt: Double) {
        events.removeAll(keepingCapacity: true)

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

        runPointDefense()
        stepProjectiles(dt)
        despawnDepartedAndDead()
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
                    p.alive && p.guided && p.vulnerableToPD
                        && canHit(owner: p.ownerID, ownerGovt: p.ownerGovt, victim: ship)
                        && (p.position - ship.position).length <= mount.spec.range
                }
                guard let target = incoming.min(by: {
                    ($0.position - ship.position).length < ($1.position - ship.position).length
                }) else { continue }
                target.alive = false
                mount.didFire()
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
        let held = intent.firePrimary || intent.fireSecondary
        updateBeamLoops(for: ship, held: held)
        guard held else { return }
        guard ship.isAlive else { return }
        let target = ship.currentTargetID.flatMap { self.ship(id: $0) }

        for (mountIndex, mount) in ship.weapons.enumerated() {
            // Reload not ready / dry on ammo: the classic invisible "why didn't
            // my weapon fire" bug. Logged once per block-reason transition —
            // see `WeaponMount.logBlockedIfNeeded` — not every held-fire frame.
            guard mount.ready else {
                mount.logBlockedIfNeeded(for: ship)
                continue
            }
            let spec = mount.spec
            // Seeker 0x0020: this guided weapon refuses to fire while its own
            // ship is fully ionized.
            if spec.cantFireWhileIonized && ship.isIonized { continue }
            // Aim: turrets/guided track the target; fixed guns fire along heading.
            var aim = ship.angle
            if let t = target, spec.isBeam || spec.isGuided || mount.spec.turnRate > 0 || target != nil {
                if spec.isBeam || spec.isGuided {
                    aim = (t.position - ship.position).angle
                }
            }
            if spec.accuracyRadians > 0 {
                aim += rng.double(in: -spec.accuracyRadians...spec.accuracyRadians)
            }

            if spec.isBeam {
                fireBeam(from: ship, mountIndex: mountIndex, spec: spec, aim: aim, target: target)
            } else {
                let dir = Vec2.heading(aim)
                let muzzle = ship.position + dir * (ship.radius + 4)
                let vel = dir * spec.projectileSpeed + ship.velocity * 0.5
                let life = spec.range / max(1, spec.projectileSpeed)
                let p = Projectile(position: muzzle, velocity: vel, life: life,
                                   shieldDamage: spec.shieldDamage, armorDamage: spec.armorDamage,
                                   blastRadius: spec.blastRadius, ownerID: ship.entityID,
                                   ownerGovt: ship.government, guided: spec.isGuided,
                                   turnRate: spec.turnRate, speed: spec.projectileSpeed,
                                   targetID: spec.isGuided ? ship.currentTargetID : nil,
                                   vulnerableToPD: spec.vulnerableToPD, ionization: spec.ionization)
                projectiles.append(p)
                events.append(.weaponFired(shooterID: ship.entityID, at: muzzle, heading: aim, soundID: spec.fireSoundID))
            }
            mount.didFire()
        }
    }

    /// Start/stop a real audio loop for each `loopSound` beam mount as its
    /// ship's trigger is held/released — independent of the reload tick, so a
    /// continuous-fire beam sounds like one sustained loop rather than a
    /// one-shot sample retriggered up to 10×/sec while held.
    private func updateBeamLoops(for ship: Ship, held: Bool) {
        for (idx, mount) in ship.weapons.enumerated() where mount.spec.isBeam && mount.spec.loopSound {
            let looping = ship.activeBeamLoopMounts.contains(idx)
            if held && ship.isAlive {
                if !looping {
                    ship.activeBeamLoopMounts.insert(idx)
                    events.append(.beamLoopStart(shooterID: ship.entityID, mountIndex: idx,
                                                 soundID: mount.spec.fireSoundID))
                }
            } else if looping {
                ship.activeBeamLoopMounts.remove(idx)
                events.append(.beamLoopStop(shooterID: ship.entityID, mountIndex: idx))
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
        }
        ship.activeBeamLoopMounts.removeAll()
    }

    /// Instant-hit beam: damage the aimed target if it's within range and roughly
    /// in the beam's path.
    private func fireBeam(from ship: Ship, mountIndex: Int, spec: WeaponSpec, aim: Double, target: Ship?) {
        let dir = Vec2.heading(aim)
        let origin = ship.position + dir * (ship.radius + 2)
        var endPoint = origin + dir * spec.range
        var hitShip: Ship?

        // Nearest valid ship along the ray within range.
        var bestT = spec.range
        for other in allShips where other.entityID != ship.entityID && other.isAlive {
            if !canHit(owner: ship.entityID, ownerGovt: ship.government, victim: other) { continue }
            let rel = other.position - origin
            let along = rel.dot(dir)
            guard along > 0, along <= spec.range else { continue }
            let perp = (rel - dir * along).length
            if perp <= other.radius + 4 && along < bestT {
                bestT = along; hitShip = other
            }
        }
        if let h = hitShip {
            endPoint = origin + dir * bestT
            applyHit(to: h, shield: spec.shieldDamage, armor: spec.armorDamage, ownerID: ship.entityID,
                     ionization: spec.ionization)
        }
        // `loopSound` weapons get their audio from the beamLoopStart/Stop
        // events above instead — carrying the one-shot id here too would
        // double up (a continuous loop plus a retriggered one-shot every tick).
        events.append(.beam(shooterID: ship.entityID, mountIndex: mountIndex, from: origin, to: endPoint,
                            hit: hitShip != nil, soundID: spec.loopSound ? nil : spec.fireSoundID))
    }

    // MARK: Projectiles

    private func stepProjectiles(_ dt: Double) {
        for p in projectiles where p.alive {
            // Guided steering toward the (still-living) target.
            if p.guided, let tid = p.targetID, let t = ship(id: tid), t.isAlive {
                let desired = (t.position - p.position).angle
                let cur = p.velocity.angle
                var d = angleDelta(from: cur, to: desired)
                let maxTurn = p.turnRate * dt
                d = max(-maxTurn, min(maxTurn, d))
                p.velocity = Vec2.heading(cur + d) * p.speed
            }
            p.position += p.velocity * dt
            p.life -= dt
            if p.life <= 0 { p.alive = false; continue }

            for other in allShips where other.isAlive {
                if !canHit(owner: p.ownerID, ownerGovt: p.ownerGovt, victim: other) { continue }
                if (other.position - p.position).length <= other.radius {
                    applyHit(to: other, shield: p.shieldDamage, armor: p.armorDamage, ownerID: p.ownerID,
                             ionization: p.ionization)
                    // Splash damage.
                    if p.blastRadius > 0 {
                        for splash in allShips where splash.entityID != other.entityID && splash.isAlive {
                            if canHit(owner: p.ownerID, ownerGovt: p.ownerGovt, victim: splash),
                               (splash.position - p.position).length <= p.blastRadius {
                                applyHit(to: splash, shield: p.shieldDamage * 0.5,
                                         armor: p.armorDamage * 0.5, ownerID: p.ownerID,
                                         ionization: p.ionization * 0.5)
                            }
                        }
                    }
                    p.alive = false
                    break
                }
            }
        }
        projectiles.removeAll { !$0.alive }
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

    /// Cycle to the next in-range ship past the current target (wrapping),
    /// ordered by distance so repeated presses sweep outward-then-around.
    /// Falls back to `selectNearestTarget` if nothing is currently locked.
    @discardableResult
    public func cycleTarget() -> Ship? {
        let inRange = npcs.filter {
            $0.isAlive && !$0.disabled && (($0.position - player.position).length <= Self.targetLockRange)
        }.sorted { ($0.position - player.position).length < ($1.position - player.position).length }
        guard !inRange.isEmpty else { return nil }
        guard let currentID = player.currentTargetID,
              let idx = inRange.firstIndex(where: { $0.entityID == currentID }) else {
            return selectNearestTarget(hostileOnly: false)
        }
        let next = inRange[(idx + 1) % inRange.count]
        player.currentTargetID = next.entityID
        events.append(.targetAcquired(entityID: next.entityID))
        return next
    }

    /// Drop the player's current target lock, if any.
    public func clearPlayerTarget() {
        player.currentTargetID = nil
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

    /// The nearest ship within hail range, regardless of relationship — hailing
    /// doesn't require a prior target lock. `range` is deliberately shorter than
    /// `targetLockRange`: hailing is a close-range action in the real game.
    public func nearestHailable(range: Double = 900) -> Ship? {
        let candidates = npcs.filter { $0.isAlive }
        return candidates
            .filter { ($0.position - player.position).length <= range }
            .min { ($0.position - player.position).length < ($1.position - player.position).length }
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
