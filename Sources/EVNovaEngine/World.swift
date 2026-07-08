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
        return r
    }
}

/// Tuning that maps EV Nova's integer stat units into simulation units. Kept in
/// one place so flight feel can be adjusted without touching data decoding.
public struct FlightTuning {
    public var speedScale: Double      // stat → max px/sec
    public var accelScale: Double      // stat → px/sec²
    public var turnScale: Double       // stat → deg/sec
    public var dragPerSecond: Double   // gentle space drag so ships settle (0 = pure Newtonian)

    public static let `default` = FlightTuning(speedScale: 3.2, accelScale: 3.2,
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
    }

    func step(_ dt: Double, intent: ControlIntent, tuning: FlightTuning) {
        let maxTurn = stats.turnRate * dt
        if intent.turnLeft || intent.turnRight {
            if intent.turnLeft { angle -= maxTurn }
            if intent.turnRight { angle += maxTurn }
        } else if let target = intent.desiredHeading {
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
        if intent.afterburner, let ab = afterburner, fuel > 0 {
            afterburnerActive = true
            accel *= ab.accelMultiplier
            topSpeed *= ab.speedMultiplier
            fuel = max(0, fuel - ab.fuelPerSecond * dt)
        }

        let heading = Vec2.heading(angle)
        if intent.thrust { velocity += heading * (accel * dt) }
        if intent.reverse { velocity += heading * (-stats.acceleration * 0.5 * dt) }

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
    }

    // MARK: Roster

    /// Every live ship, player first. Handy for AI perception.
    public var allShips: [Ship] { [player] + npcs }

    public func ship(id: Int) -> Ship? {
        if id == 0 { return player }
        return npcs.first { $0.entityID == id }
    }

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
            let npcIntent = npc.brain?.think(ship: npc, world: self, dt: dt) ?? ControlIntent()
            fireWeapons(from: npc, intent: npcIntent)
            npc.step(dt, intent: npcIntent, tuning: tuning)
        }

        // Cooldowns & regen (hulks recover nothing).
        for s in allShips {
            for w in s.weapons { w.tick(dt) }
            if !s.disabled { s.regen(dt) }
        }

        stepProjectiles(dt)
        despawnDepartedAndDead()
    }

    // MARK: Weapons

    private func fireWeapons(from ship: Ship, intent: ControlIntent) {
        guard intent.firePrimary || intent.fireSecondary else { return }
        guard ship.isAlive else { return }
        let target = ship.currentTargetID.flatMap { self.ship(id: $0) }

        for mount in ship.weapons where mount.ready {
            let spec = mount.spec
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
                fireBeam(from: ship, spec: spec, aim: aim, target: target)
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
                                   targetID: spec.isGuided ? ship.currentTargetID : nil)
                projectiles.append(p)
                events.append(.weaponFired(shooterID: ship.entityID, at: muzzle, heading: aim))
            }
            mount.didFire()
        }
    }

    /// Instant-hit beam: damage the aimed target if it's within range and roughly
    /// in the beam's path.
    private func fireBeam(from ship: Ship, spec: WeaponSpec, aim: Double, target: Ship?) {
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
            applyHit(to: h, shield: spec.shieldDamage, armor: spec.armorDamage, ownerID: ship.entityID)
        }
        events.append(.beam(from: origin, to: endPoint, hit: hitShip != nil))
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
                    applyHit(to: other, shield: p.shieldDamage, armor: p.armorDamage, ownerID: p.ownerID)
                    // Splash damage.
                    if p.blastRadius > 0 {
                        for splash in allShips where splash.entityID != other.entityID && splash.isAlive {
                            if canHit(owner: p.ownerID, ownerGovt: p.ownerGovt, victim: splash),
                               (splash.position - p.position).length <= p.blastRadius {
                                applyHit(to: splash, shield: p.shieldDamage * 0.5,
                                         armor: p.armorDamage * 0.5, ownerID: p.ownerID)
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

    private func applyHit(to ship: Ship, shield: Double, armor: Double, ownerID: Int) {
        let hadShield = ship.shield > 0
        let killed = ship.applyDamage(shield: shield, armor: armor)
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

        if killed {
            // A mortal blow disables rather than destroys some ships (freighters
            // and lighter craft especially) — EV Nova leaves boardable hulks in
            // space instead of vaporising everything. The player is never disabled
            // here (the app owns player death). Already-disabled ships die for real.
            if !ship.isPlayer, !ship.disabled, rng.double(in: 0...1) < disableChance(for: ship) {
                ship.disabled = true
                ship.armor = max(1, ship.maxArmor * 0.02)   // a sliver — still "alive"
                ship.shield = 0
                ship.disableSpin = rng.double(in: -0.5...0.5)
                ship.wantsToDepart = false
                ship.currentTargetID = nil
                ship.brain?.targetID = nil
                clearTarget(ship.entityID)               // everyone stops shooting it
                events.append(.shipDisabled(entityID: ship.entityID, at: ship.position))
            } else {
                ship.armor = 0
            }
        }
    }

    /// Probability that a killing hit merely disables `ship` instead of destroying
    /// it. Traders/civilians cripple easily; warships tend to blow up fighting.
    private func disableChance(for ship: Ship) -> Double {
        switch ship.brain?.aiType {
        case .wimpyTrader, .braveTrader: return 0.6
        case .warship, .interceptor:     return 0.18
        default:                         return 0.35
        }
    }

    // MARK: Despawn

    private func despawnDepartedAndDead() {
        var survivors: [Ship] = []
        for npc in npcs {
            if !npc.isAlive {
                events.append(.explosion(at: npc.position, radius: max(24, npc.radius * 1.5)))
                events.append(.shipDestroyed(entityID: npc.entityID, shipTypeID: npc.shipTypeID,
                                             at: npc.position))
                // Clear any targeting of the dead ship.
                clearTarget(npc.entityID)
                continue
            }
            // Landed on a stellar object → vanished into the spaceport (no wreck).
            if npc.wantsToLand, let sid = npc.landingSpob {
                events.append(.shipLanded(entityID: npc.entityID, spobID: sid, at: npc.position))
                clearTarget(npc.entityID)
                continue
            }
            // Departed past the system edge → gone to hyperspace.
            if npc.wantsToDepart {
                let d = (npc.position - systemContext.center).length
                if d >= systemContext.jumpRadius {
                    events.append(.shipDeparted(entityID: npc.entityID, at: npc.position,
                                                heading: npc.angle))
                    clearTarget(npc.entityID)
                    continue
                }
            }
            // A cold hulk that's drifted long enough is quietly retired.
            if npc.disabled && npc.disabledClock > 25 {
                clearTarget(npc.entityID)
                continue
            }
            survivors.append(npc)
        }
        npcs = survivors
        // Player death is left to the app (respawn / game-over UI).
    }

    private func clearTarget(_ id: Int) {
        if player.currentTargetID == id { player.currentTargetID = nil }
        for s in npcs where s.currentTargetID == id {
            s.currentTargetID = nil
            s.brain?.targetID = nil
        }
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
