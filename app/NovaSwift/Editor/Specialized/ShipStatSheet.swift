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
        /// Extra damage per shot from submunitions (assuming they all land), already counted in the
        /// DPS figures. See `SubmunitionDamage`.
        var subShieldDamage = 0.0
        var subArmorDamage = 0.0
        /// The submunition walk hit its depth cap (an unbounded self-splitting weapon).
        var subTruncated = false
        /// Shots per second the cadence works out to (see `WeaponCadence`).
        var shotsPerSecond = 0.0
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

    /// One weapon's numbers as the engine's `WeaponSpec` sees them. DPS = (own damage + the damage
    /// of its submunitions, all assumed to land) x steady-state shots per second for `count` mounts.
    /// Cadence follows the original's fire loop (`WeaponCadence`, Weapon_GetWeaponFireIntervalTicks
    /// 0x0046f270 and the burst tail of Weapon_FirePlayerWeaponBank 0x00455150): staggered mounts
    /// fire at `reload / count`, simultaneous ones together every `reload`, and a burst weapon
    /// spends its BurstReload instead of the normal cooldown after `BurstCount` volleys
    /// (x `count` when staggered). Submunitions: `SubmunitionDamage` (0x00420d30 rules).
    static func weaponLine(galaxy: Galaxy, game: NovaGame, id: Int, count: Int) -> WeaponLine? {
        guard let spec = galaxy.weaponSpec(id), let raw = game.weapon(id) else { return nil }
        let cadence = WeaponCadence.compute(reloadTicks: raw.reload, burstCount: raw.burstCount,
                                            burstReloadTicks: raw.burstReload, mounts: max(1, count),
                                            simultaneous: raw.fireSimultaneously,
                                            framesPerSecond: galaxy.combatTuning.framesPerSecond)
        let rate = cadence.shotsPerSecond
        let sub = SubmunitionDamage.total(of: id) { wid -> SubmunitionNode? in
            guard let s = galaxy.weaponSpec(wid), let r = game.weapon(wid) else { return nil }
            return SubmunitionNode(shieldDamage: s.shieldDamage, armorDamage: s.armorDamage,
                                   subID: r.hasSubmunition ? r.subID : -1, subCount: r.hasSubmunition ? r.subCount : 0,
                                   subLimit: r.subLimit, cannotBeSubmunition: s.isBeam || r.isFighterBay)
        }
        return WeaponLine(id: id, name: spec.name, count: count, ammo: 0,
                          shieldDamage: spec.shieldDamage, armorDamage: spec.armorDamage,
                          reloadSeconds: spec.reloadSeconds, range: spec.range,
                          guidance: guidanceName(raw.guidance),
                          dpsShield: (spec.shieldDamage + sub.shield) * rate,
                          dpsArmor: (spec.armorDamage + sub.armor) * rate,
                          isBeam: spec.isBeam,
                          subShieldDamage: sub.shield, subArmorDamage: sub.armor, subTruncated: sub.truncated,
                          shotsPerSecond: rate)
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
