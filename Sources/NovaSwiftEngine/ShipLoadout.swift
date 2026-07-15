import Foundation
import NovaSwiftKit

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
    /// Bible `shïp.Holds` negative-sign convention: this hull refuses to sell
    /// its own cargo-hold tons for equipment mass — an outfit that trades
    /// cargo capacity for free mass (negative `.freeCargo`, e.g. "Mass
    /// Expansion") can't be bought here even with room for both.
    public var blocksMassExpansion: Bool

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
    /// `oütf` ModType 37 (`fastJump`): a "jump control"/inertialess-jump outfit
    /// that removes the slow spin-up — the ship jumps almost instantly without
    /// the deliberate turn-and-align maneuver. False = the standard slow jump.
    public var instantJump: Bool = false
    /// `oütf` ModType 22 (`hyperspaceSpeed`): summed bonus that shortens the
    /// jump's entry/exit sequence. Interpreted by the app as a percentage speed-up
    /// of the jump animation (0 = stock timing). See `PilotStore.jumpSpeedFactor`.
    public var hyperspaceSpeedBonus: Int = 0

    /// Fighter bays fitted (`wëap` Guidance 99). Each launches carried fighters
    /// rather than firing. See `FighterBaySpec` and `Ship.fighterBays`.
    public var fighterBays: [FighterBaySpec] = []

    /// Combined cloaking-device flag bits (`oütf` ModType 17, OR'd across fitted
    /// cloaks). 0 = the ship has no cloak. Bit meanings (Bible): 0x0002 visible
    /// on radar, 0x0004 drops shields on activation, 0x0008 decloaks when hit,
    /// 0x0010/20/40/80 use 1/2/4/8 fuel per sec, 0x0100/200/400/800 use
    /// 1/2/4/8 shield per sec, 0x1000 area cloak. See `Ship` cloak state.
    public var cloakFlags: Int = 0
    /// Combined cloak-scanner flag bits (`oütf` ModType 30). Bible: 0x0001 reveal
    /// cloaked ships on radar, 0x0002 on screen, 0x0004 target untargetable
    /// ships, 0x0008 target cloaked ships.
    public var cloakScannerFlags: Int = 0
    /// Anti-interference: total `oütf` ModType 24, subtracted from the system's
    /// `Interference` when computing effective sensor range.
    public var interferenceReduction: Int = 0
    /// Net `oütf` ModType 28 murk change applied to the current system's murk.
    public var murkModifier: Int = 0
    /// Whether the ship carries an escape pod (`shïp.EscapePod` count or an
    /// `oütf` ModType 11 escape-pod item) — the pilot survives destruction.
    public var hasEscapePod: Bool = false
    /// `oütf` ModType 20 (auto-eject): automatically ejects the pilot on death
    /// (requires an escape pod to work, per the Bible).
    public var hasAutoEject: Bool = false
    /// Inertialess flight — the hull's `shïp` Flags2 0x0040 or any fitted
    /// inertial-dampener (`oütf` ModType 38). Drives the no-drift flight model.
    public var inertialess: Bool = false

    /// The hull's `shïp.Crew` complement — the number the boarding/capture-odds
    /// math uses on both sides (attacker's own crew, defender's crew). See
    /// `World.captureChance`.
    public var crew: Int = 0
    /// Extra "effective crew" from installed marines outfits (`oütf` ModType 25
    /// with a **positive** ModVal): "Adds the value in ModVal to your ship's
    /// effective crew complement when calculating capture odds" (Bible).
    public var marineCrew: Int = 0
    /// Flat percentage points added to capture odds from marines outfits with a
    /// **negative** ModVal (Bible: "-1 to -100 Increase the player's capture
    /// odds by this amount"). Stored as a positive number of percentage points.
    public var captureOddsBonus: Int = 0
    /// Extra max-ionization capacity from fitted `oütf` ModType 40 (`ionCapacity`)
    /// items — added onto the hull's `IonizeMax` so the ship can soak more ion
    /// charge before being immobilized.
    public var ionCapacityBonus: Int = 0
    /// Extra ion-dissipation rate from fitted `oütf` ModType 39 (`deionize`)
    /// items — added onto the hull's `Deionize` so ion charge bleeds off faster.
    public var deionizeBonus: Int = 0
    /// Combined jamming strength from fitted `oütf` ModTypes 33-36 (`jam1-4`).
    /// A ship-level defense that stacks with the pilot's government's inherent
    /// `InhJam1-4`, giving incoming "turns away if jammed" guided shots a per-second
    /// chance to lose their lock on this ship. See `World`'s guided-steering loop.
    public var jamming: Int = 0
    /// Whether a fitted `oütf` ModType 31 (`miningScoop`) — or the hull's own
    /// `shïp.Flags3` 0x0002 ("scoops asteroid debris") — lets this ship auto-collect
    /// an asteroid's `röid.YieldType`/`YieldQty` yield when it destroys the rock.
    public var hasMiningScoop: Bool = false
    /// `oütf` ModType 23 (`hyperspaceDist`): summed adjustment to the no-jump
    /// zone's radius (Bible: "standard radius is 1000"; negative narrows it,
    /// letting the ship jump from closer to a system's populated core).
    public var hyperspaceDistBonus: Int = 0
    /// `oütf` ModType 19 (`autoRefuel`): the fuel tank tops off for free on
    /// landing/departure instead of needing to be bought at the Trade Center.
    public var hasAutoRefuel: Bool = false
    /// `oütf` ModType 13 (`densityScanner`): reveals a targeted ship's cargo
    /// hold contents in the targeting readout (Bible ModVal is "ignored" —
    /// ownership alone is what matters).
    public var hasDensityScanner: Bool = false
    /// `oütf` ModType 49 (`repairSystem`): "will occasionally repair the ship
    /// when it's disabled." Not player-restricted in the Bible, so an NPC hull
    /// stocked with one benefits too.
    public var hasRepairSystem: Bool = false
    /// `oütf` ModType 44 (`reinforcementInhibitor`), player-only per the Bible.
    /// Each fitted item's ModVal is a `gövt.Class1-4` value that can no longer
    /// call in reinforcements while the player is in-system; `-1` inhibits
    /// every government. Empty = no inhibitor fitted.
    public var reinforcementInhibitorClasses: Set<Int> = []
    /// `oütf` ModType 48 (`iffScrambler`), player-only per the Bible. Each
    /// fitted item's ModVal is a `gövt.Class1-4` value that's fooled into
    /// treating the player as friendly (won't attack without provocation);
    /// `-1` scrambles every government. Empty = no scrambler fitted.
    public var iffScramblerClasses: Set<Int> = []
    /// `oütf` ModType 43 (`paint`), player-only per the Bible: "the color to
    /// paint the player's ship," a 15-bit `0RRRRRGGGGGBBBBB` value (5 bits per
    /// channel, 0...1 here). Nil = no paint fitted (fly the hull's stock/
    /// government tint instead). The last fitted paint outfit wins if more
    /// than one is somehow installed — the Bible doesn't say what happens
    /// with two, and there's no sane way to blend "the" ship color.
    public var paintColor: (r: Double, g: Double, b: Double)? = nil
    /// `oütf` ModType 41 (`gravityResist`): fitted, this ship also ignores a
    /// stellar's `Gravity` pull/push even without the hull's own `Flags3`
    /// 0x0010. Folded with the hull flag at `Ship.ignoresGravity`.
    public var hasGravityResist: Bool = false
    /// `oütf` ModType 42 (`stellarResist`): fitted, this ship also survives
    /// touching a deadly stellar (`SpobRes.isDeadly`) even without the hull's
    /// own `Flags3` 0x0020. Folded with the hull flag at
    /// `Ship.ignoresDeadlyStellars`.
    public var hasStellarResist: Bool = false
}

/// A fighter bay fitted to a ship (`wëap` Guidance 99). Immutable spec resolved
/// from the bay weapon; the live docked/deployed counts live on `Ship.FighterBay`.
public struct FighterBaySpec: Equatable, Sendable {
    /// The `wëap` id of the bay itself.
    public var bayWeaponID: Int
    /// The `shïp` class id of the fighter this bay launches (`wëap.AmmoType`).
    public var fighterShipID: Int
    /// How many fighters the bay holds when full (`wëap.MaxAmmo` × bays fitted).
    public var capacity: Int
    /// Minimum frames between launches (`wëap.Reload`, at 30 fps).
    public var launchIntervalFrames: Int

    public init(bayWeaponID: Int, fighterShipID: Int, capacity: Int, launchIntervalFrames: Int) {
        self.bayWeaponID = bayWeaponID
        self.fighterShipID = fighterShipID
        self.capacity = capacity
        self.launchIntervalFrames = launchIntervalFrames
    }
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
        var fastJump = false
        var hyperspaceSpeed = 0
        var marineCrew = 0
        var captureOddsBonus = 0
        var cloakFlags = 0, cloakScannerFlags = 0
        var interferenceReduction = 0, murkModifier = 0
        var ionCapBonus = 0, deionizeBonus = 0, jammingBonus = 0
        var hasMiningScoop = s.flags3 & 0x0002 != 0   // hull "scoops asteroid debris"
        var hasEscapePod = s.podCount > 0, hasAutoEject = false
        var inertialess = s.inertialess        // hull flag; an inertial-dampener outfit ORs in below
        var grantedWeapons: [Int: Int] = [:]   // weapon id → count
        var ammoAdds: [Int: Int] = [:]         // weapon id → extra ammo units
        var hyperspaceDistBonus = 0
        var hasAutoRefuel = false, hasDensityScanner = false, hasRepairSystem = false
        var reinforcementInhibitorClasses: Set<Int> = []
        var iffScramblerClasses: Set<Int> = []
        var paintColor: (r: Double, g: Double, b: Double)?
        var hasGravityResist = false, hasStellarResist = false

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
                case .fastJump:        fastJump = true            // inertialess/instant jump (no spin-up)
                case .hyperspaceSpeed: hyperspaceSpeed += v        // faster jump entry/exit sequence
                case .weapon:          grantedWeapons[value, default: 0] += count
                case .ammunition:      ammoAdds[value, default: 0] += count
                case .marines:
                    // ModType 25 (marines) feeds capture-odds, not ship stats.
                    // Positive ModVal → +effective crew; negative (-1..-100) →
                    // +that many percentage points of capture odds (Bible).
                    if value >= 0 { marineCrew += v } else { captureOddsBonus += (-value) * count }
                case .cloak:           cloakFlags |= value          // ModVal = cloak flag bits
                case .cloakScanner:    cloakScannerFlags |= value   // ModVal = scanner flag bits
                case .interference:    interferenceReduction += v    // subtracts from system Interference
                case .murk:            murkModifier += v             // adjusts system Murk
                case .escapePod:       hasEscapePod = true           // ModType 11
                case .autoEject:       hasAutoEject = true           // ModType 20 (needs a pod)
                case .inertialDamper:  inertialess = true            // ModType 38 → no-inertia flight
                case .ionCapacity:     ionCapBonus += v              // ModType 40 → +max ion charge
                case .deionize:        deionizeBonus += v            // ModType 39 → +ion dissipation
                case .jam1, .jam2, .jam3, .jam4:
                    jammingBonus += v                                // ModTypes 33-36 → jamming defense
                case .miningScoop:     hasMiningScoop = true         // ModType 31 → collect asteroid yield
                case .hyperspaceDist:  hyperspaceDistBonus += v      // ModType 23 → no-jump zone radius delta
                case .autoRefuel:      hasAutoRefuel = true          // ModType 19 → free refuel at spaceport
                case .densityScanner:  hasDensityScanner = true      // ModType 13 → reveal target cargo
                case .repairSystem:    hasRepairSystem = true        // ModType 49 → self-repair while disabled
                case .reinforcementInhibitor:
                    reinforcementInhibitorClasses.insert(value)      // ModType 44 → govt class (-1 = all)
                case .iffScrambler:
                    iffScramblerClasses.insert(value)                // ModType 48 → govt class (-1 = all)
                case .paint:
                    // ModType 43 → 15-bit 0RRRRRGGGGGBBBBB (5 bits/channel).
                    let u = UInt16(truncatingIfNeeded: value)
                    let r = Double((u >> 10) & 0x1F) / 31.0
                    let g = Double((u >> 5) & 0x1F) / 31.0
                    let b = Double(u & 0x1F) / 31.0
                    paintColor = (r, g, b)
                case .gravityResist: hasGravityResist = true   // ModType 41
                case .stellarResist: hasStellarResist = true   // ModType 42
                // ModType 27 (increaseMax) is not a ship-stat modifier: its only
                // effect is raising another outfit's purchase cap, enforced at buy
                // time by `NovaGame.effectiveMaxInstallable` / `PilotStore`. Nothing
                // to fold into the flown ship here. ModTypes 43/41/42 (paint,
                // gravity/stellar resist) are handled by the app layer directly off
                // owned outfits (sprite tint, hazard damage), not folded into a ship
                // stat here. ModTypes 47/50 (bomb, nonlethal bomb) likewise stay in
                // the app layer — they consume/remove the specific owned outfit unit
                // on trigger, which this aggregation (a pure, non-mutating function)
                // has no business doing.
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
            // `wid` is the real wëap id an ammo outfit's `.ammunition` modifier
            // names (e.g. buying "Raven Rocket" ammo names wëap #138, the
            // fixed-mount "Raven Rocket" weapon). But the weapon that actually
            // *draws* from that pool when it fires is identified by its own
            // `AmmoType` field, which the Bible documents as "draws ammo from
            // this type of weapon" — a 0-based index needing +128 to become a
            // real wëap id (this codebase's usual resource-id-base offset).
            // Multiple mount variants of the same round deliberately share one
            // AmmoType so they pool ammo — e.g. "Raven Rocket" (wëap #138,
            // AmmoType 10 → 128+10 = 138, itself) and "Raven Turret" (wëap
            // #139, ALSO AmmoType 10 → 138) both draw from the pool named by
            // #138, even though only #138 matches the ammo outfit's id
            // directly. Matching only `byID[wid]` (as if every weapon's pool
            // were always its own raw id) missed every such turret/pod pair —
            // the turret showed "- 0" and could never fire despite the pod's
            // ammo genuinely being owned. So: route this ammo to every
            // currently-mounted weapon whose own AmmoType resolves to `wid`,
            // not just to a mount that happens to share its literal id.
            for (mountID, entry) in byID {
                guard let mountSpec = game.weapon(mountID), mountSpec.ammoType >= 0,
                      128 + mountSpec.ammoType == wid else { continue }
                var e = entry
                e.ammo += a
                byID[mountID] = e
            }
        }
        // Fighter bays (`wëap` Guidance 99) don't fire projectiles — they launch
        // carried fighters. Build the dedicated bay list (capacity × number of
        // bays fitted) for the live docked/deployed state, but keep the bay's
        // own mount in `weapons` too (ammo seeded to that same capacity, not
        // whatever stock ammo-pool value it inherited) so it's selectable as a
        // secondary weapon like any other — real EV Nova bays act exactly like a
        // missile launcher: select it, pull the trigger, one fighter launches.
        var fighterBays: [FighterBaySpec] = []
        for (wid, entry) in byID where game.weapon(wid)?.isFighterBay == true {
            guard let w = game.weapon(wid) else { continue }
            let capacity = w.fighterCapacity * max(1, entry.count)
            fighterBays.append(FighterBaySpec(bayWeaponID: wid, fighterShipID: w.fighterShipID,
                                              capacity: capacity,
                                              launchIntervalFrames: max(1, w.reload)))
            byID[wid] = (entry.count, capacity)
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
            shieldRechargePerSec: max(0, Double(shieldRechStat) * 0.03),
            armorRechargePerSec: max(0, Double(armorRechStat) * 0.03),
            maxFuel: Double(max(0, fuelCap)),
            fuelRegenPerSec: Double(max(0, fuelRegenStat)) * 0.03,
            afterburner: afterburner,
            cargoCapacity: max(0, cargo),
            // `s.freeMass` is the Bible-documented ceiling as-is — "in addition
            // to the space taken up by the ship's stock weapons" means the
            // decoded field is already net of stock weapon mass, so it's the
            // budget directly; `usedMass` (installed *outfits*, stock + bought)
            // is what actually eats into it. Previously this was
            // `s.freeMass + usedMass`, which made `freeMass` (== massCapacity −
            // usedMass) collapse back to the constant `s.freeMass` no matter
            // what was installed — the "Free Mass" readout never moved and no
            // mass-consuming outfit purchase was ever actually gated by it.
            massCapacity: s.freeMass, usedMass: usedMass,
            blocksMassExpansion: s.blocksMassExpansion,
            maxGuns: maxGuns, maxTurrets: maxTurrets,
            usedGunSlots: usedGunSlots, usedTurretSlots: usedTurretSlots,
            outfits: outfitCounts, weapons: weapons,
            maxJumpHops: max(1, 1 + multiJumpBonus),
            instantJump: fastJump,
            hyperspaceSpeedBonus: hyperspaceSpeed,
            fighterBays: fighterBays,
            cloakFlags: cloakFlags, cloakScannerFlags: cloakScannerFlags,
            interferenceReduction: interferenceReduction, murkModifier: murkModifier,
            hasEscapePod: hasEscapePod, hasAutoEject: hasAutoEject, inertialess: inertialess,
            crew: max(0, s.crew), marineCrew: marineCrew, captureOddsBonus: captureOddsBonus,
            ionCapacityBonus: max(0, ionCapBonus), deionizeBonus: max(0, deionizeBonus),
            jamming: max(0, jammingBonus), hasMiningScoop: hasMiningScoop,
            hyperspaceDistBonus: hyperspaceDistBonus,
            hasAutoRefuel: hasAutoRefuel, hasDensityScanner: hasDensityScanner,
            hasRepairSystem: hasRepairSystem,
            reinforcementInhibitorClasses: reinforcementInhibitorClasses,
            iffScramblerClasses: iffScramblerClasses,
            paintColor: paintColor,
            hasGravityResist: hasGravityResist, hasStellarResist: hasStellarResist)
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
        ship.explosionBoomID = shipRes.flatMap { $0.finalExplosionBoomID ?? $0.breakupExplosionBoomID }
        ship.government = govt ?? shipRes?.inherentGovt ?? independentGovt
        ship.radius = radius
        ship.exitPoints = exitPoints(forShip: shipID)
        ship.combatStrength = Double(max(1, shipRes?.strength ?? 1))
        ship.disableArmorFraction = (shipRes.map { $0.flags & 0x0010 != 0 } ?? false) ? 0.10 : 0.33
        ship.fleeWhenOutOfAmmo = shipRes?.fleeWhenOutOfAmmo ?? false
        ship.ionizeMax = Double(max(0, shipRes?.ionizeMax ?? 0) + lo.ionCapacityBonus)
        ship.deionizePerSec = Double(max(0, shipRes?.deionize ?? 0) + lo.deionizeBonus) * 0.3
        ship.jamming = lo.jamming
        ship.hasMiningScoop = lo.hasMiningScoop
        ship.maxShield = lo.maxShield; ship.shield = lo.maxShield
        ship.maxArmor = lo.maxArmor; ship.armor = lo.maxArmor
        ship.shieldRechargePerSec = lo.shieldRechargePerSec
        ship.armorRechargePerSec = lo.armorRechargePerSec
        ship.maxFuel = lo.maxFuel; ship.fuel = lo.maxFuel
        ship.fuelRegenPerSec = lo.fuelRegenPerSec
        ship.afterburner = lo.afterburner
        ship.cargoCapacity = lo.cargoCapacity
        ship.crew = lo.crew
        ship.marineCrew = lo.marineCrew
        ship.captureOddsBonus = lo.captureOddsBonus
        ship.fighterBays = lo.fighterBays.map { Ship.FighterBay(spec: $0) }
        ship.inertialess = lo.inertialess
        ship.cloakFlags = lo.cloakFlags
        ship.cloakScannerFlags = lo.cloakScannerFlags
        ship.interferenceReduction = lo.interferenceReduction
        ship.murkModifier = lo.murkModifier
        ship.hasEscapePod = lo.hasEscapePod
        ship.hasAutoEject = lo.hasAutoEject
        ship.hasRepairSystem = lo.hasRepairSystem
        ship.hasDensityScanner = lo.hasDensityScanner
        ship.reinforcementInhibitorClasses = lo.reinforcementInhibitorClasses
        ship.iffScramblerClasses = lo.iffScramblerClasses
        ship.paintColor = lo.paintColor
        ship.ignoresGravity = (shipRes?.ignoresGravity ?? false) || lo.hasGravityResist
        ship.ignoresDeadlyStellars = (shipRes?.ignoresDeadlyStellars ?? false) || lo.hasStellarResist

        var mounts: [WeaponMount] = []
        for w in lo.weapons {
            guard let spec = weaponSpec(w.id) else { continue }
            // One grouped mount per weapon type; `count` copies stagger their fire.
            let n = max(1, min(w.count, 12))
            // -1 means "unlimited" (`WeaponMount.ready`/`didFire` both special-case
            // it to never run dry or decrement) — that must depend on whether the
            // *weapon* tracks ammo at all (`ammoPerShot > 0`, i.e. `wëap.MaxAmmo`
            // is set), not on whether the currently-computed `w.ammo` happens to be
            // positive. A missile launcher that's been fully fired dry, or one
            // that's freshly installed with no ammo bought yet, legitimately has
            // `w.ammo == 0` — coercing that to -1 silently made it unlimited
            // instead of correctly unable to fire.
            let ammo = spec.ammoPerShot > 0 ? max(0, w.ammo) : -1
            mounts.append(WeaponMount(spec: spec, ammo: ammo, count: n))
        }
        ship.weapons = mounts
        return ship
    }
}
