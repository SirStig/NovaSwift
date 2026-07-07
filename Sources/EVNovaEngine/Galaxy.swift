import Foundation
import EVNovaKit

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

    public init() {}
    public init(bodies: [StellarBody], center: Vec2 = Vec2(),
                jumpRadius: Double = 4200, spawnRadius: Double = 3600) {
        self.bodies = bodies; self.center = center
        self.jumpRadius = jumpRadius; self.spawnRadius = spawnRadius
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
    /// (weapon spec, ammo) mounts. A stock weapon with count N becomes N mounts.
    public let mounts: [(spec: WeaponSpec, ammo: Int)]
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

    public init(game: NovaGame, flightTuning: FlightTuning = .default,
                combatTuning: CombatTuning = .default) {
        self.game = game
        self.flightTuning = flightTuning
        self.combatTuning = combatTuning
    }

    /// The diplomacy table for every government the data defines.
    public func makeDiplomacy() -> Diplomacy { Diplomacy(govts: game.govts()) }

    // MARK: Specs

    public func weaponSpec(_ id: Int) -> WeaponSpec? {
        if let cached = weaponCache[id] { return cached }
        guard let w = game.weapon(id) else { return nil }
        let spec = WeaponSpec(w, tuning: combatTuning)
        weaponCache[id] = spec
        return spec
    }

    public func shipSpec(_ id: Int) -> ShipSpec? {
        if let cached = shipCache[id] { return cached }
        guard let s = game.ship(id) else { return nil }

        let frames = game.shan(id).map { $0.baseSetCount > 0 ? $0.baseSetCount : 36 } ?? 36
        let stats = ShipStats(speed: s.speed, acceleration: s.acceleration,
                              turnRate: s.turnRate, rotationFrames: frames, tuning: flightTuning)
        let radius: Double = game.shan(id).map { max(10, Double(max($0.baseWidth, $0.baseHeight)) / 2) } ?? 18

        var mounts: [(WeaponSpec, Int)] = []
        for w in s.weapons {
            guard let spec = weaponSpec(w.id) else { continue }
            // A hull lists a weapon once with a count; make that many mounts.
            let n = max(1, min(w.count, 8))
            for _ in 0..<n { mounts.append((spec, w.ammo > 0 ? max(1, w.ammo / n) : -1)) }
        }

        let spec = ShipSpec(
            id: s.id, name: s.name, stats: stats,
            maxShield: Double(s.shield) * combatTuning.hpScale,
            maxArmor: Double(max(1, s.armor)) * combatTuning.hpScale,
            shieldRechargePerSec: max(2, Double(s.shieldRecharge) * 0.05),
            armorRechargePerSec: Double(s.armorRecharge) * 0.03,
            radius: radius, government: s.inherentGovt, strength: s.strength, mounts: mounts)
        shipCache[id] = spec
        return spec
    }

    // MARK: Factories

    /// Build a live, combat-ready ship of type `shipID`. Health starts full and a
    /// weapon loadout is installed. Government defaults to the hull's inherent one
    /// unless overridden. No brain is attached (that's the spawner's / player's job).
    public func makeShip(_ shipID: Int, government govt: Int? = nil,
                         at position: Vec2 = Vec2(), angle: Double = 0) -> Ship? {
        guard let spec = shipSpec(shipID) else { return nil }
        let ship = Ship(name: spec.name, stats: spec.stats, position: position, angle: angle)
        ship.shipTypeID = shipID
        ship.government = govt ?? spec.government
        ship.radius = spec.radius
        ship.maxShield = spec.maxShield; ship.shield = spec.maxShield
        ship.maxArmor = spec.maxArmor; ship.armor = spec.maxArmor
        ship.shieldRechargePerSec = spec.shieldRechargePerSec
        ship.armorRechargePerSec = spec.armorRechargePerSec
        ship.weapons = spec.mounts.map { WeaponMount(spec: $0.spec, ammo: $0.ammo) }
        return ship
    }

    /// Build the system geometry for a given system id from real `spöb` positions.
    public func systemContext(for systemID: Int) -> SystemContext {
        guard let sys = game.system(systemID) else { return SystemContext() }
        var bodies: [StellarBody] = []
        var maxExtent: Double = 1000
        for spobID in sys.spobs {
            guard let s = game.spob(spobID) else { continue }
            let pos = Vec2(Double(s.x), Double(s.y))
            maxExtent = max(maxExtent, pos.length + 400)
            // Landability: a spob you can dock/land on (has a landing picture) is a
            // trader destination. Fall back to "any body" if flags are unclear.
            let canLand = s.landingPictID > 0 || (s.flags & 0x0001) != 0
            bodies.append(StellarBody(id: spobID, position: pos, radius: 90, canLand: canLand))
        }
        let jumpRadius = max(2600, maxExtent * 1.6)
        return SystemContext(bodies: bodies, center: Vec2(),
                             jumpRadius: jumpRadius, spawnRadius: jumpRadius * 0.85)
    }
}
