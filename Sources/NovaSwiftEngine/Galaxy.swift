import Foundation
import NovaSwiftKit

/// A stellar object the AI can navigate to (planet / station). `canLand` gates
/// whether traders will treat it as a destination.
public struct StellarBody {
    public let id: Int
    public let position: Vec2
    public let radius: Double
    public let canLand: Bool
    public init(id: Int, position: Vec2, radius: Double, canLand: Bool) {
        self.id = id; self.position = position; self.radius = radius; self.canLand = canLand
    }
}

/// The geometry of the system the player is currently in: its landable bodies,
/// its centre, and the radius at which ships enter/leave hyperspace. Drives NPC
/// navigation (travel, patrol, flee/jump-out) and where new arrivals appear.
public struct SystemContext {
    public var bodies: [StellarBody] = []
    public var center: Vec2 = Vec2()
    /// Ships past this radius from `center` are at the hyperspace edge.
    public var jumpRadius: Double = 4200
    /// Where arriving NPCs pop in (just inside the edge).
    public var spawnRadius: Double = 3600
    /// The government that controls this system (`sÿst.Govt`). Drives which
    /// ships count as "the local authority" and may run the patrol beat / scan
    /// traffic — foreign combat ships just pass through. `independentGovt`
    /// (unowned) means anyone armed may patrol.
    public var systemGovt: Int = independentGovt

    public init() {}
    public init(bodies: [StellarBody], center: Vec2 = Vec2(),
                jumpRadius: Double = 4200, spawnRadius: Double = 3600,
                systemGovt: Int = independentGovt) {
        self.bodies = bodies; self.center = center
        self.jumpRadius = jumpRadius; self.spawnRadius = spawnRadius
        self.systemGovt = systemGovt
    }
}

/// A fully-derived, simulation-ready ship type: flight stats, health, and a
/// resolved weapon loadout. Built from a decoded `ShipRes` (hull + stock weapons)
/// through `Galaxy`.
public struct ShipSpec {
    public let id: Int
    public let name: String
    public let stats: ShipStats
    public let maxShield: Double
    public let maxArmor: Double
    public let shieldRechargePerSec: Double
    public let armorRechargePerSec: Double
    public let radius: Double
    public let government: Int
    public let strength: Int
    /// Fraction of max armor at which this hull disables instead of being
    /// destroyed outright (`shïp.Flags` 0x0010 → 10%, else the default 33%).
    public let disableArmorFraction: Double
    /// `shïp.SkillVar` (0-50, percent) — per-instance pilot-skill jitter on
    /// acceleration/turn rate. See `jitteredStats(_:skillVar:roll:)`.
    public let skillVar: Int
    /// `shïp.Flags2` 0x0080 — flees/docks once every ammo-using weapon is dry.
    public let fleeWhenOutOfAmmo: Bool
    /// `shïp.IonizeMax` — charge at which this hull is "fully ionized."
    public let ionizeMax: Double
    /// `shïp.Deionize`, converted to charge points dissipated per second.
    public let deionizePerSec: Double
    /// (weapon spec, ammo, count) — one entry per weapon *type*; `count` is how
    /// many copies are fitted (EV Nova groups by type, not by barrel).
    public let mounts: [(spec: WeaponSpec, ammo: Int, count: Int)]
    /// `snd ` id for this hull's death explosion (final explosion, falling back
    /// to the breakup explosion), or nil if neither resolves to a sound.
    public let explosionSoundID: Int?
    /// Real weapon exit points from this hull's `shän`, or nil if it has none.
    public let exitPoints: ShipExitPoints?
}

extension Galaxy {
    /// Convert a hull's `shän` weapon exit points into the engine's maths
    /// convention (origin centre, +x = ship's right, +y = nose). `shän` already
    /// stores y nose-positive (verified against real hulls: guns sit at positive
    /// y, toward the front), which matches this engine's +y-up world — so unlike
    /// NovaJS (a y-down renderer that negates) no sign flip is needed. Returns
    /// nil when the hull has no `shän`, so firing falls back to a nose muzzle.
    public func exitPoints(forShip shipID: Int) -> ShipExitPoints? {
        guard let shan = game.shan(shipID) else { return nil }
        func conv(_ pts: [ShanExitPoint]) -> [Vec2] {
            pts.map { Vec2(Double($0.x), Double($0.y)) }
        }
        func zs(_ pts: [ShanExitPoint]) -> [Double] {
            pts.map { Double($0.z) }
        }
        return ShipExitPoints(
            gun: conv(shan.gunPoints), turret: conv(shan.turretPoints),
            guided: conv(shan.guidedPoints), beam: conv(shan.beamPoints),
            gunZ: zs(shan.gunPoints), turretZ: zs(shan.turretPoints),
            guidedZ: zs(shan.guidedPoints), beamZ: zs(shan.beamPoints),
            upCompress: (x: Double(shan.upCompress.x), y: Double(shan.upCompress.y)),
            downCompress: (x: Double(shan.downCompress.x), y: Double(shan.downCompress.y)))
    }
}

/// EV Nova's `shïp.SkillVar`: "the amount (in percent) to which this ship's
/// pilots' skill varies... a skill variance of 10% would make each ship of a
/// given type up to 10% slower or faster than stock" (Bible) — applied to
/// acceleration and turn rate alike (one pilot-skill roll, not two independent
/// ones), so ships of the same class aren't all identical. `roll` is a value
/// in −1...1 (typically `world.rng.double(in: -1...1)` at spawn time); nil
/// means no jitter (e.g. the player's own ship, or deterministic test fixtures).
func jitteredStats(_ stats: ShipStats, skillVar: Int, roll: Double?) -> ShipStats {
    guard let roll, skillVar > 0 else { return stats }
    let variance = Double(min(50, max(0, skillVar))) / 100.0
    let factor = 1 + max(-1, min(1, roll)) * variance
    return ShipStats(maxSpeed: stats.maxSpeed, acceleration: stats.acceleration * factor,
                     turnRate: stats.turnRate * factor, rotationFrames: stats.rotationFrames)
}

/// The catalog that turns decoded EV Nova resources into simulation objects:
/// ship specs, weapon specs, the diplomacy table, and factory methods that build
/// live `Ship`s. The app constructs one from a loaded `NovaGame`; engine tests
/// can build specs by hand and skip it.
public final class Galaxy {
    public let game: NovaGame
    public let flightTuning: FlightTuning
    public let combatTuning: CombatTuning

    private var weaponCache: [Int: WeaponSpec] = [:]
    private var shipCache: [Int: ShipSpec] = [:]
    private var diplomacyCache: Diplomacy?

    public init(game: NovaGame, flightTuning: FlightTuning = .default,
                combatTuning: CombatTuning = .default) {
        self.game = game
        self.flightTuning = flightTuning
        self.combatTuning = combatTuning
    }

    /// The diplomacy table for every government the data defines. Built once
    /// and cached — every AI decision this session reads it repeatedly.
    public func makeDiplomacy() -> Diplomacy {
        if let cached = diplomacyCache { return cached }
        let d = Diplomacy(govts: game.govts())
        diplomacyCache = d
        return d
    }

    // MARK: Specs

    public func weaponSpec(_ id: Int) -> WeaponSpec? {
        if let cached = weaponCache[id] { return cached }
        guard let w = game.weapon(id) else {
            // Callers (e.g. `shipSpec`'s mount loop) silently drop the mount
            // when this comes back nil — a ship ends up with fewer guns than
            // its data says it should have, with no other symptom.
            Log.world.error("Galaxy: weapon id \(id) not found in game data — any mount referencing it will be silently dropped")
            return nil
        }
        let spec = WeaponSpec(w, tuning: combatTuning)
        weaponCache[id] = spec
        return spec
    }

    public func shipSpec(_ id: Int) -> ShipSpec? {
        if let cached = shipCache[id] { return cached }
        guard let s = game.ship(id) else {
            // Callers (`makeShip`, `Spawner`, etc.) silently fail to spawn
            // when this is nil — presents as "that NPC/ship type never shows up".
            Log.world.error("Galaxy: ship id \(id) not found in game data — makeShip(\(id)) will silently return nil")
            return nil
        }

        // EV Nova hulls rotate through 36 headings (shän's counts are animation
        // sets, not headings) — must match SpriteTextures.rotationFrames.
        let frames = 36
        let stats = ShipStats(speed: s.speed, acceleration: s.acceleration,
                              turnRate: s.turnRate, rotationFrames: frames, tuning: flightTuning)
        let radius: Double = game.shan(id).map { max(10, Double(max($0.baseWidth, $0.baseHeight)) / 2) } ?? 18

        var mounts: [(WeaponSpec, Int, Int)] = []
        for w in s.weapons {
            guard let spec = weaponSpec(w.id) else { continue }
            // One mount per weapon *type* (EV Nova groups by type); `count` copies
            // stagger their fire and cycle exit points. Ammo pools across the group.
            let n = max(1, min(w.count, 12))
            mounts.append((spec, w.ammo > 0 ? w.ammo : -1, n))
        }

        let spec = ShipSpec(
            id: s.id, name: s.displayName, stats: stats,
            maxShield: Double(s.shield) * combatTuning.hpScale,
            maxArmor: Double(max(1, s.armor)) * combatTuning.hpScale,
            shieldRechargePerSec: max(2, Double(s.shieldRecharge) * 0.05),
            armorRechargePerSec: Double(s.armorRecharge) * 0.03,
            radius: radius, government: s.inherentGovt, strength: s.strength,
            disableArmorFraction: (s.flags & 0x0010 != 0) ? 0.10 : 0.33, skillVar: s.skillVar,
            fleeWhenOutOfAmmo: s.fleeWhenOutOfAmmo,
            ionizeMax: Double(max(0, s.ionizeMax)), deionizePerSec: Double(max(0, s.deionize)) * 0.3,
            mounts: mounts, explosionSoundID: game.deathExplosionSoundID(s),
            exitPoints: exitPoints(forShip: id))
        shipCache[id] = spec
        return spec
    }

    // MARK: Factories

    /// Build a live, combat-ready ship of type `shipID`. Health starts full and a
    /// weapon loadout is installed. Government defaults to the hull's inherent one
    /// unless overridden. No brain is attached (that's the spawner's / player's job).
    public func makeShip(_ shipID: Int, government govt: Int? = nil,
                         at position: Vec2 = Vec2(), angle: Double = 0,
                         skillRoll: Double? = nil) -> Ship? {
        guard let spec = shipSpec(shipID) else { return nil }
        let stats = jitteredStats(spec.stats, skillVar: spec.skillVar, roll: skillRoll)
        let ship = Ship(name: spec.name, stats: stats, position: position, angle: angle)
        ship.shipTypeID = shipID
        ship.explosionSoundID = spec.explosionSoundID
        ship.government = govt ?? spec.government
        ship.radius = spec.radius
        ship.exitPoints = spec.exitPoints
        ship.maxShield = spec.maxShield; ship.shield = spec.maxShield
        ship.maxArmor = spec.maxArmor; ship.armor = spec.maxArmor
        ship.shieldRechargePerSec = spec.shieldRechargePerSec
        ship.armorRechargePerSec = spec.armorRechargePerSec
        ship.weapons = spec.mounts.map { WeaponMount(spec: $0.spec, ammo: $0.ammo, count: $0.count) }
        ship.combatStrength = Double(max(1, spec.strength))
        ship.disableArmorFraction = spec.disableArmorFraction
        ship.fleeWhenOutOfAmmo = spec.fleeWhenOutOfAmmo
        ship.ionizeMax = spec.ionizeMax
        ship.deionizePerSec = spec.deionizePerSec
        return ship
    }

    /// Build the system geometry for a given system id from real `spöb` positions.
    public func systemContext(for systemID: Int) -> SystemContext {
        guard let sys = game.system(systemID) else {
            // Silent fallback to an empty system: no bodies to land on/patrol,
            // default jump radius — reads as "system is a featureless void" or
            // "NPCs immediately try to depart" with nothing pointing at why.
            Log.world.error("Galaxy: system id \(systemID) not found in game data — falling back to an empty SystemContext (no stellar bodies)")
            return SystemContext()
        }
        var bodies: [StellarBody] = []
        for spobID in sys.spobs {
            guard let s = game.spob(spobID) else { continue }
            let pos = Vec2(Double(s.x), Double(s.y))
            // Match the same sprite-derived size the renderer uses (GameContainerView's
            // PlanetVisual), so landing/collision geometry agrees with what's on screen
            // instead of every body sharing one hardcoded radius.
            let radius = Double(game.spobSprite(spobID)?.frameWidth ?? 48) / 2
            bodies.append(StellarBody(id: spobID, position: pos, radius: radius, canLand: s.isLandable))
        }
        // The system's actual centre of mass — not the world origin, which a
        // system's stellar objects don't necessarily cluster around. Everything
        // below (jump radius, spawn ring, patrol loiter, player start) is expressed
        // relative to this centre.
        let center: Vec2
        if bodies.isEmpty {
            center = Vec2()
        } else {
            let sum = bodies.reduce(Vec2()) { $0 + $1.position }
            center = sum * (1.0 / Double(bodies.count))
        }
        // Hyperspace edge: base it on the *bulk* of the system (80th-percentile
        // stellar distance from centre), not the single farthest object — some
        // systems park a lone stellar tens of thousands of units out, which
        // otherwise stretched the jump radius so far the system felt empty and
        // traffic took forever to cross. Clamp to a sane band so density stays
        // believable everywhere.
        let dists = bodies.map { ($0.position - center).length }.sorted()
        let ref: Double = dists.isEmpty ? 1200
            : dists[min(dists.count - 1, Int((Double(dists.count - 1) * 0.8).rounded()))]
        let jumpRadius = min(6000, max(2600, ref * 1.5 + 700))
        return SystemContext(bodies: bodies, center: center,
                             jumpRadius: jumpRadius, spawnRadius: jumpRadius * 0.85,
                             systemGovt: sys.government)
    }
}
