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
    /// Gun-mount slots consumed by installed outfits flagged `oütf.Flags`
    /// `0x0001` ("this item is a fixed gun") — see OUTFITTERS.md §2/§6.
    public var usedGunSlots: Int
    /// Turret-mount slots consumed by installed outfits flagged `oütf.Flags`
    /// `0x0002` ("this item is a turret") — see OUTFITTERS.md §2/§6.
    public var usedTurretSlots: Int
    /// Gun mounts still free for a fixed-gun-flagged outfit purchase. Purchase-time
    /// code (e.g. `PilotStore.canBuyOutfit`) should check this — and
    /// `freeTurretSlots` — before allowing a `0x0001`/`0x0002`-flagged outfit to be
    /// bought, mirroring the existing `freeMass` check. Not yet enforced anywhere
    /// (OUTFITTERS.md §6/§9: "a player can currently buy more gun-type outfits
    /// than the hull has gun mounts for").
    public var freeGunSlots: Int { max(0, maxGuns - usedGunSlots) }
    /// Turret mounts still free for a turret-flagged outfit purchase. See
    /// `freeGunSlots`.
    public var freeTurretSlots: Int { max(0, maxTurrets - usedTurretSlots) }

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

extension OutfRes {
    /// `oütf.Flags 0x0001`: "This item is a fixed gun" — installs into a gun
    /// mount and competes with other `0x0001`/`0x0002`-flagged outfits for the
    /// hull's `ShipRes.maxGuns` count. See OUTFITTERS.md §2/§6.
    public var isFixedGunOutfit: Bool { flags & 0x0001 != 0 }
    /// `oütf.Flags 0x0002`: "This item is a turret" — installs into a turret
    /// mount, competing for `ShipRes.maxTurrets`. See OUTFITTERS.md §2/§6.
    public var isTurretOutfit: Bool { flags & 0x0002 != 0 }
    /// `oütf.Flags 0x0200`: "This item's total price is proportional to the
    /// player's ship's mass. (ship class Mass field is multiplied by this
    /// item's Cost field)" — Nova Bible via OUTFITTERS.md §4.
    public var priceIsShipMassProportional: Bool { flags & 0x0200 != 0 }
    /// `oütf.Flags 0x0400`: "This item's total mass (at purchase) is
    /// proportional to the player's ship's mass" — `shipClass.Mass ×
    /// outfit.Mass / 100`, positive-mass items only. Nova Bible via
    /// OUTFITTERS.md §2.
    public var massIsShipMassProportional: Bool { flags & 0x0400 != 0 }

    /// This outfit's effective installed mass aboard a hull of `shipMass`
    /// tons (`ShipRes.mass`, the hull's own mass field, @62) — applies the
    /// `0x0400` proportional-mass rule (`shipMass × mass / 100`, positive-mass
    /// items only) when the flag is set, otherwise the flat `mass`.
    public func effectiveMass(shipMass: Int) -> Int {
        guard massIsShipMassProportional, mass > 0 else { return mass }
        return shipMass * mass / 100
    }

    /// This outfit's effective purchase price aboard a hull of `shipMass` tons
    /// — applies the `0x0200` proportional-price rule (`shipMass × cost`) when
    /// the flag is set, otherwise the flat `cost`. Exposed for purchase-time
    /// code (e.g. `PilotStore.buyOutfit`/`sellOutfit`) to charge/refund
    /// correctly; not consumed anywhere in this file today since this file
    /// aggregates *stats*, not credits.
    public func effectiveCost(shipMass: Int) -> Int {
        guard priceIsShipMassProportional else { return cost }
        return shipMass * cost
    }
}

extension Galaxy {
    /// `outfit`'s effective installed mass if fitted to `shipID` — see
    /// `OutfRes.effectiveMass(shipMass:)`. Falls back to the flat `mass` if
    /// the hull can't be resolved.
    public func effectiveMass(of outfit: OutfRes, forShip shipID: Int) -> Int {
        guard let s = game.ship(shipID) else { return outfit.mass }
        return outfit.effectiveMass(shipMass: s.mass)
    }

    /// `outfit`'s effective purchase price if fitted to `shipID` — see
    /// `OutfRes.effectiveCost(shipMass:)`. Falls back to the flat `cost` if
    /// the hull can't be resolved.
    public func effectiveCost(of outfit: OutfRes, forShip shipID: Int) -> Int {
        guard let s = game.ship(shipID) else { return outfit.cost }
        return outfit.effectiveCost(shipMass: s.mass)
    }

    /// Resolve a hull + its outfits (preinstalled, plus any `extraOutfits` the
    /// player bought) into an effective `Loadout`. Outfit stat modifiers are
    /// summed into the hull's base stats, then converted to sim units using the
    /// same scales `Galaxy.shipSpec` uses for NPCs — so player and NPC ships stay
    /// on one footing.
    public func loadout(shipID: Int, extraOutfits: [Int: Int] = [:]) -> Loadout? {
        guard let s = game.ship(shipID) else {
            Log.world.error("Galaxy.loadout: ship id \(shipID) not found in game data — returning nil loadout")
            return nil
        }

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
        var usedGunSlots = 0, usedTurretSlots = 0
        var afterburnerFuel = 0
        var multiJumpBonus = 0
        var grantedWeapons: [Int: Int] = [:]   // weapon id → count
        var ammoAdds: [Int: Int] = [:]         // weapon id → extra ammo units

        for (oid, count) in outfitCounts {
            guard let o = game.outfit(oid) else {
                // The ship (or the player's purchase record) references an
                // outfit id the data doesn't have — it's silently skipped, so
                // its stat modifiers/mass just vanish from the loadout with
                // nothing else pointing at why.
                Log.world.error("Galaxy.loadout: outfit id \(oid) (x\(count)) not found in game data for ship \(shipID) — skipped, its effects are missing from this loadout")
                continue
            }
            // Flags 0x0400: proportional-mass outfits scale with the hull's
            // own mass instead of contributing their flat `mass` (OUTFITTERS.md §2/§4).
            usedMass += o.effectiveMass(shipMass: s.mass) * count
            // Flags 0x0001/0x0002: fixed-gun/turret outfits compete for the
            // hull's MaxGuns/MaxTurrets mount counts (OUTFITTERS.md §2/§6).
            // Bookkeeping only here — enforcement at purchase time belongs to
            // `PilotStore`, via `Loadout.freeGunSlots`/`.freeTurretSlots`.
            if o.isFixedGunOutfit { usedGunSlots += count }
            if o.isTurretOutfit { usedTurretSlots += count }
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
            shipID: s.id, name: s.displayName,
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
            usedGunSlots: usedGunSlots, usedTurretSlots: usedTurretSlots,
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
                               at position: Vec2 = Vec2(), angle: Double = 0,
                               skillRoll: Double? = nil) -> Ship? {
        guard let lo = loadout(shipID: shipID, extraOutfits: extraOutfits) else {
            // Falls back to an un-equipped hull (`makeShip`) — if this fires
            // for the player's own ship, they'll fly with none of their
            // fitted outfits and no other clue why.
            Log.world.error("Galaxy.makeLoadedShip: loadout(\(shipID)) failed — falling back to an unequipped makeShip(\(shipID))")
            return makeShip(shipID, government: govt, at: position, angle: angle, skillRoll: skillRoll)
        }
        // EV Nova hulls rotate through 36 headings. (shän's other counts are
        // *animation sets* — banking / lit variants — not headings, so we must NOT
        // use them here; this count must match SpriteTextures.rotationFrames.)
        let shan = game.shan(shipID)
        let frames = 36
        let radius: Double = shan.map { max(10, Double(max($0.baseWidth, $0.baseHeight)) / 2) } ?? 18
        let shipRes = game.ship(shipID)
        let baseStats = ShipStats(speed: lo.speed, acceleration: lo.acceleration,
                                  turnRate: lo.turnRate, rotationFrames: frames, tuning: flightTuning)
        let stats = jitteredStats(baseStats, skillVar: shipRes?.skillVar ?? 0, roll: skillRoll)
        let ship = Ship(name: lo.name, stats: stats, position: position, angle: angle)
        ship.shipTypeID = shipID
        ship.explosionSoundID = shipRes.flatMap { game.deathExplosionSoundID($0) }
        ship.government = govt ?? shipRes?.inherentGovt ?? independentGovt
        ship.radius = radius
        ship.combatStrength = Double(max(1, shipRes?.strength ?? 1))
        ship.disableArmorFraction = (shipRes.map { $0.flags & 0x0010 != 0 } ?? false) ? 0.10 : 0.33
        ship.fleeWhenOutOfAmmo = shipRes?.fleeWhenOutOfAmmo ?? false
        ship.ionizeMax = Double(max(0, shipRes?.ionizeMax ?? 0))
        ship.deionizePerSec = Double(max(0, shipRes?.deionize ?? 0)) * 0.3
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
