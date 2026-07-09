import Foundation
import EVNovaKit

// The "ship system" aggregation layer: it takes a decoded hull (`shïp`) plus its
// installed outfits (`oütf`) and resolves them into the *effective* ship — the
// numbers the simulation actually flies and fights with. EV Nova ships are the
// sum of their hull and their equipment; this is where that sum is computed.
//
// Combat (shields/armor/weapons/projectiles) lives in `Combat.swift` + `World`;
// this file adds fuel, the afterburner, cargo/mass, and the outfit math that
// feeds all of them.

/// Fuel constants. EV Nova measures fuel in units where **100 = one hyperjump**.
public enum ShipFuel {
    public static let perJump: Double = 100
}

/// An installed afterburner's behaviour: it drains fuel while held and, in return,
/// raises the ship's acceleration and speed cap. EV Nova's afterburner outfit only
/// stores a fuel-cost figure; the boost factors are engine tuning.
public struct Afterburner: Equatable {
    /// Fuel units consumed per second while burning.
    public var fuelPerSecond: Double
    /// Multiplier applied to the ship's top speed while burning.
    public var speedMultiplier: Double
    /// Multiplier applied to the ship's acceleration while burning.
    public var accelMultiplier: Double

    public init(fuelPerSecond: Double, speedMultiplier: Double = 1.5,
                accelMultiplier: Double = 1.4) {
        self.fuelPerSecond = fuelPerSecond
        self.speedMultiplier = speedMultiplier
        self.accelMultiplier = accelMultiplier
    }
}

/// A fully-aggregated ship configuration: the hull's base stats with every
/// installed outfit's modifiers folded in, plus a resolved weapon list. This is
/// what a ship *actually is* once its equipment is accounted for. Build one with
/// `Galaxy.loadout(shipID:extraOutfits:)`.
public struct Loadout {
    public var shipID: Int
    public var name: String

    // Flight (post-outfit stat units, fed to `ShipStats`).
    public var speed: Int
    public var acceleration: Int
    public var turnRate: Int

    // Defenses (max HP + per-second regen, already in sim units).
    public var maxShield: Double
    public var maxArmor: Double
    public var shieldRechargePerSec: Double
    public var armorRechargePerSec: Double

    // Fuel & afterburner.
    public var maxFuel: Double
    public var fuelRegenPerSec: Double
    public var afterburner: Afterburner?

    // Storage & mass.
    public var cargoCapacity: Int   // tons
    public var massCapacity: Int    // total free mass for outfits (tons)
    public var usedMass: Int        // mass consumed by installed outfits (tons)
    public var freeMass: Int { max(0, massCapacity - usedMass) }

    // Weapon mounts available on the hull.
    public var maxGuns: Int
    public var maxTurrets: Int

    // Installed content.
    public var outfits: [Int: Int]  // outfit id → count
    /// Resolved weapons: (weapon id, number of mounts, total ammo; ammo 0 = unlimited).
    public var weapons: [(id: Int, count: Int, ammo: Int)]

    /// Jumps of hyperspace fuel this loadout can hold.
    public var jumpRange: Int { Int((maxFuel / ShipFuel.perJump).rounded(.down)) }
    /// Hyperlane hops a single hyperspace jump command can cross (1 = standard
    /// single-jump; higher only with a multi-jump outfit installed).
    public var maxJumpHops: Int
}

extension Galaxy {
    /// Resolve a hull + its outfits (preinstalled, plus any `extraOutfits` the
    /// player bought) into an effective `Loadout`. Outfit stat modifiers are
    /// summed into the hull's base stats, then converted to sim units using the
    /// same scales `Galaxy.shipSpec` uses for NPCs — so player and NPC ships stay
    /// on one footing.
    public func loadout(shipID: Int, extraOutfits: [Int: Int] = [:]) -> Loadout? {
        guard let s = game.ship(shipID) else { return nil }

        // Merge preinstalled outfits with anything else installed.
        var outfitCounts: [Int: Int] = [:]
        for (oid, c) in s.outfits { outfitCounts[oid, default: 0] += c }
        for (oid, c) in extraOutfits where c > 0 { outfitCounts[oid, default: 0] += c }

        // Aggregate in stat-space (the same units the hull stores).
        var shieldStat = s.shield, armorStat = s.armor
        var shieldRechStat = s.shieldRecharge, armorRechStat = s.armorRecharge
        var speedStat = s.speed, accelStat = s.acceleration, turnStat = s.turnRate
        var fuelCap = s.fuelCapacity, fuelRegenStat = s.fuelRegen
        var cargo = s.cargoSpace
        var maxGuns = s.maxGuns, maxTurrets = s.maxTurrets
        var usedMass = 0
        var afterburnerFuel = 0
        var multiJumpBonus = 0
        var grantedWeapons: [Int: Int] = [:]   // weapon id → count
        var ammoAdds: [Int: Int] = [:]         // weapon id → extra ammo units

        for (oid, count) in outfitCounts {
            guard let o = game.outfit(oid) else { continue }
            usedMass += o.mass * count
            for (type, value) in o.modifiers {
                let v = value * count
                switch type {
                case .shield:          shieldStat += v
                case .shieldRecharge:  shieldRechStat += v
                case .armor:           armorStat += v
                case .armorRecharge:   armorRechStat += v
                case .speed:           speedStat += v
                case .acceleration:    accelStat += v
                case .turnRate:        turnStat += v
                case .fuelCapacity:    fuelCap += v
                case .fuelRegen:       fuelRegenStat += v
                case .freeCargo:       cargo += v
                case .maxGuns:         maxGuns += v
                case .maxTurrets:      maxTurrets += v
                case .afterburner:     afterburnerFuel += value   // fuel cost per unit
                case .multiJump:       multiJumpBonus += v        // extra hops per hyperjump
                case .weapon:          grantedWeapons[value, default: 0] += count
                case .ammunition:      ammoAdds[value, default: 0] += count
                default: break
                }
            }
        }

        // Resolve weapons: stock hull weapons + outfit-granted, merged by id.
        var byID: [Int: (count: Int, ammo: Int)] = [:]
        for w in s.weapons {
            let e = byID[w.id] ?? (0, 0)
            byID[w.id] = (e.count + max(1, w.count), e.ammo + max(0, w.ammo))
        }
        for (wid, c) in grantedWeapons {
            let e = byID[wid] ?? (0, 0); byID[wid] = (e.count + c, e.ammo)
        }
        for (wid, a) in ammoAdds {
            let e = byID[wid] ?? (0, 0); byID[wid] = (e.count, e.ammo + a)
        }
        let weapons = byID.map { (id: $0.key, count: $0.value.count, ammo: $0.value.ammo) }
            .sorted { $0.id < $1.id }

        let afterburner = afterburnerFuel > 0
            ? Afterburner(fuelPerSecond: Double(afterburnerFuel)) : nil

        return Loadout(
            shipID: s.id, name: s.name,
            speed: max(0, speedStat), acceleration: max(0, accelStat), turnRate: max(0, turnStat),
            maxShield: Double(max(0, shieldStat)) * combatTuning.hpScale,
            maxArmor: Double(max(1, armorStat)) * combatTuning.hpScale,
            shieldRechargePerSec: max(2, Double(shieldRechStat) * 0.05),
            armorRechargePerSec: max(0, Double(armorRechStat) * 0.03),
            maxFuel: Double(max(0, fuelCap)),
            fuelRegenPerSec: Double(max(0, fuelRegenStat)) * 0.03,
            afterburner: afterburner,
            cargoCapacity: max(0, cargo),
            massCapacity: s.freeMass + usedMass, usedMass: usedMass,
            maxGuns: maxGuns, maxTurrets: maxTurrets,
            outfits: outfitCounts, weapons: weapons,
            maxJumpHops: max(1, 1 + multiJumpBonus))
    }

    /// Build a live ship with its **full loadout** applied: outfit-modified flight
    /// and defense stats, a full fuel tank, an afterburner if fitted, cargo
    /// capacity, and a resolved weapon set. Use this for the player (and any NPC
    /// you want equipped from real outfit data). Falls back to `makeShip` if the
    /// hull can't be found.
    public func makeLoadedShip(_ shipID: Int, government govt: Int? = nil,
                               extraOutfits: [Int: Int] = [:],
                               at position: Vec2 = Vec2(), angle: Double = 0) -> Ship? {
        guard let lo = loadout(shipID: shipID, extraOutfits: extraOutfits) else {
            return makeShip(shipID, government: govt, at: position, angle: angle)
        }
        // EV Nova hulls rotate through 36 headings. (shän's other counts are
        // *animation sets* — banking / lit variants — not headings, so we must NOT
        // use them here; this count must match SpriteTextures.rotationFrames.)
        let shan = game.shan(shipID)
        let frames = 36
        let radius: Double = shan.map { max(10, Double(max($0.baseWidth, $0.baseHeight)) / 2) } ?? 18
        let stats = ShipStats(speed: lo.speed, acceleration: lo.acceleration,
                              turnRate: lo.turnRate, rotationFrames: frames, tuning: flightTuning)

        let shipRes = game.ship(shipID)
        let ship = Ship(name: lo.name, stats: stats, position: position, angle: angle)
        ship.shipTypeID = shipID
        ship.government = govt ?? shipRes?.inherentGovt ?? independentGovt
        ship.radius = radius
        ship.combatStrength = Double(max(1, shipRes?.strength ?? 1))
        ship.disableArmorFraction = (shipRes.map { $0.flags & 0x0010 != 0 } ?? false) ? 0.10 : 0.33
        ship.maxShield = lo.maxShield; ship.shield = lo.maxShield
        ship.maxArmor = lo.maxArmor; ship.armor = lo.maxArmor
        ship.shieldRechargePerSec = lo.shieldRechargePerSec
        ship.armorRechargePerSec = lo.armorRechargePerSec
        ship.maxFuel = lo.maxFuel; ship.fuel = lo.maxFuel
        ship.fuelRegenPerSec = lo.fuelRegenPerSec
        ship.afterburner = lo.afterburner
        ship.cargoCapacity = lo.cargoCapacity

        var mounts: [WeaponMount] = []
        for w in lo.weapons {
            guard let spec = weaponSpec(w.id) else { continue }
            let n = max(1, min(w.count, 12))
            for _ in 0..<n {
                mounts.append(WeaponMount(spec: spec, ammo: w.ammo > 0 ? max(1, w.ammo / n) : -1))
            }
        }
        ship.weapons = mounts
        return ship
    }
}
