#if os(macOS)
import Foundation
import NovaSwiftKit
import NovaSwiftEngine

/// Ship stats computed by the engine itself (`Galaxy.loadout` + `ShipStats`), so the
/// editor shows exactly what the game flies with — never a re-derivation. Optional
/// `extraOutfits` lets the outfit inspector show before/after for a candidate fit.
struct ShipStatSheet {
    struct WeaponLine: Identifiable {
        var id: Int
        var name: String
        var count: Int
        var ammo: Int                  // 0 = unlimited
        var shieldDamage: Double
        var armorDamage: Double
        var reloadSeconds: Double
        var range: Double              // px
        var guidance: String
        var dpsShield: Double
        var dpsArmor: Double
        var isBeam: Bool
    }

    var shipID: Int
    var name: String

    // Flight, in the game's stat units and in engine units.
    var speedStat = 0, accelStat = 0, turnStat = 0, turnBonus = 0
    var maxSpeed = 0.0            // px/s
    var acceleration = 0.0        // px/s²
    var turnDegPerSec = 0.0       // hull turn rate (what NPCs fly)
    var playerTurnDegPerSec = 0.0 // the player's whole-degree-per-tick step × 30

    // Defense.
    var shield = 0.0, armor = 0.0
    var shieldRecharge = 0.0, armorRecharge = 0.0   // per second

    // Capacity.
    var massCapacity = 0, usedMass = 0, freeMass = 0
    var cargo = 0
    var maxFuel = 0.0, jumps = 0, fuelRegenPerSec = 0.0
    var afterburnerFuelPerSec: Double?
    var maxGuns = 0, maxTurrets = 0, usedGuns = 0, usedTurrets = 0

    // Hull data.
    var crew = 0, cost = 0, techLevel = 0

    var weapons: [WeaponLine] = []
    var dpsShield: Double { weapons.reduce(0) { $0 + $1.dpsShield } }
    var dpsArmor: Double { weapons.reduce(0) { $0 + $1.dpsArmor } }
    var outfits: [(id: Int, count: Int)] = []

    static func compute(_ data: SpecData, shipID: Int, extraOutfits: [Int: Int] = [:]) -> ShipStatSheet? {
        let galaxy = data.galaxy, game = data.game
        guard let hull = game.ship(shipID),
              let lo = galaxy.loadout(shipID: shipID, extraOutfits: extraOutfits) else { return nil }
        var s = ShipStatSheet(shipID: shipID, name: lo.name)
        s.speedStat = lo.speed; s.accelStat = lo.acceleration; s.turnStat = lo.turnRate; s.turnBonus = lo.turnBonus
        let stats = ShipStats(speed: lo.speed, acceleration: lo.acceleration, turnRate: lo.turnRate,
                              turnBonus: lo.turnBonus, rotationFrames: 36, tuning: galaxy.flightTuning)
        s.maxSpeed = stats.maxSpeed
        s.acceleration = stats.acceleration
        s.turnDegPerSec = stats.turnRate * 180 / .pi
        s.playerTurnDegPerSec = Double(stats.playerTurnDegPerTick) * OriginalClock.ticksPerSecond
        s.shield = lo.maxShield; s.armor = lo.maxArmor
        s.shieldRecharge = lo.shieldRechargePerSec; s.armorRecharge = lo.armorRechargePerSec
        s.massCapacity = lo.massCapacity; s.usedMass = lo.usedMass; s.freeMass = lo.freeMass
        s.cargo = lo.cargoCapacity
        s.maxFuel = lo.maxFuel; s.jumps = lo.jumpRange; s.fuelRegenPerSec = lo.playerFuelRegenPerSec
        s.afterburnerFuelPerSec = lo.afterburner?.fuelPerSecond
        s.maxGuns = lo.maxGuns; s.maxTurrets = lo.maxTurrets
        s.usedGuns = lo.usedGunSlots; s.usedTurrets = lo.usedTurretSlots
        s.crew = lo.crew; s.cost = hull.cost; s.techLevel = hull.techLevel
        s.outfits = lo.outfits.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        s.weapons = lo.weapons.compactMap { w in
            guard let line = weaponLine(galaxy: galaxy, game: game, id: w.id, count: w.count) else { return nil }
            var l = line; l.ammo = w.ammo; return l
        }
        return s
    }

    /// One weapon's numbers as the engine's `WeaponSpec` sees them. DPS multiplies by the
    /// mount count; burst weapons use the full burst cycle. Sub-munitions are not folded
    /// into DPS (they're listed on the weapon's own page).
    static func weaponLine(galaxy: Galaxy, game: NovaGame, id: Int, count: Int) -> WeaponLine? {
        guard let spec = galaxy.weaponSpec(id), let raw = game.weapon(id) else { return nil }
        var cycle = spec.reloadSeconds
        var shots = 1.0
        if raw.burstCount > 1, raw.burstReload > 0 {
            let fps = galaxy.combatTuning.framesPerSecond
            shots = Double(raw.burstCount)
            cycle = (Double(raw.burstCount - 1) * Double(max(0, raw.reload)) + Double(raw.burstReload)) / fps
        }
        let rate = cycle > 0 ? shots / cycle : 0
        let n = Double(max(1, count))
        return WeaponLine(id: id, name: spec.name, count: count, ammo: 0,
                          shieldDamage: spec.shieldDamage, armorDamage: spec.armorDamage,
                          reloadSeconds: spec.reloadSeconds, range: spec.range,
                          guidance: guidanceName(raw.guidance),
                          dpsShield: spec.shieldDamage * rate * n, dpsArmor: spec.armorDamage * rate * n,
                          isBeam: spec.isBeam)
    }

    static func guidanceName(_ g: WeaponGuidance) -> String {
        switch g {
        case .unguided: return "Unguided"
        case .beam: return "Beam"
        case .guided: return "Guided"
        case .beamTurret: return "Beam turret"
        case .turret: return "Turret"
        case .freefallBomb: return "Freefall bomb"
        case .rocket: return "Rocket"
        case .frontQuadrant: return "Front quadrant"
        case .rearQuadrant: return "Rear quadrant"
        case .pointDefense: return "Point defense"
        case .pointDefenseBeam: return "Point-defense beam"
        case .bay: return "Fighter bay"
        case .other: return "Other"
        }
    }
}
#endif
