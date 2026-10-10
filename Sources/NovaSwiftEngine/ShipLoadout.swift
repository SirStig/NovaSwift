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

/// An installed afterburner (ModType 15). The outfit stores only its fuel cost;
/// the original's boost is a separate thruster in the player's flight tick
/// (`Ship.step`).
public struct Afterburner: Equatable {
    /// Fuel units consumed per second while burning: ModVal × 0.0333 per tick
    /// (`Ship_GetShipFuelBurnRate` 0x0046e060).
    public var fuelPerSecond: Double

    public init(fuelPerSecond: Double) {
        self.fuelPerSecond = fuelPerSecond
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
    /// Summed ModType-9 `count × ModVal`, in hundredths of a degree per tick
    /// (`Maneuver × 10` scale), added on top of `turnRate`.
    public var turnBonus: Int = 0

    // Defenses (max HP + per-second regen, already in sim units).
    public var maxShield: Double
    public var maxArmor: Double
    public var shieldRechargePerSec: Double
    public var armorRechargePerSec: Double

    // Fuel & afterburner.
    public var maxFuel: Double
    /// Fuel regeneration as an NPC flies the hull (`Ship_ComputeShipFuelRechargeRate`
    /// 0x00463b30): `1/FuelRegen` per tick from the hull plus `count/ModVal` per
    /// tick for each ModType-18 outfit. Negative ModVal drains ("fuel sucking").
    public var fuelRegenPerSec: Double
    /// The same rate as the player flies it: the hull's `1/FuelRegen` term needs
    /// shïp Flags 0x0008; the outfit terms don't (FL-07).
    public var playerFuelRegenPerSec: Double = 0
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
    /// Route systems one jump crosses: `Σ ModVal` of the owned ModType-32
    /// outfits (once per def), at least 1. Fuel and travel days are charged
    /// once per jump however many systems it crosses (FL-06).
    public var maxJumpHops: Int
    /// The original's multi-jump depth, `max(1, 1 + Σ ModVal)` (`FUN_0046cdd0`).
    public var multiJumpDepth: Int = 1
    /// Fast jump: class Flags2 0x0020 or a ModType-37 outfit. It skips the
    /// jump's brake and the spin-up damping; the cue-timed spin-up still runs.
    public var instantJump: Bool = false
    /// `oütf` ModType 22: summed `count × ModVal`. In the original these are
    /// extra travel *days* per jump (`Galaxy.hyperspaceTravelDays`); the
    /// `quickHyperjump` enhancement reads them as a jump speed-up instead.
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
    /// Whether the ship carries an `oütf` ModType 11 escape pod — the pilot can
    /// eject (OS-02). The hull's own PodCount doesn't count.
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
    /// Per-type jamming strength from fitted `oütf` ModTypes 33-36 (`jam1-4`) —
    /// **four independent values**, one per jammer type, not a single total.
    /// Stacks with the pilot's government's inherent `InhJam1-4` and is matched
    /// against each incoming seeker's `wëap.JamVuln1-4` (see
    /// `WeaponBehaviorFlags.jamChance(against:)`), so an IR jammer only ever
    /// troubles IR-guided ordnance. Always four entries.
    public var jamming: [Int] = [0, 0, 0, 0]
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
    /// Never below the outfit's own mass (`Outfit_ComputeOutfitPurchaseMass`
    /// 0x0046e950, EC-14), so a hull under 100 t pays the base mass.
    public func effectiveMass(shipMass: Int) -> Int {
        guard massIsShipMassProportional, mass > 0 else { return mass }
        return max(mass, shipMass * mass / 100)
    }

    /// This outfit's effective purchase price aboard a hull of `shipMass` tons
    /// — applies the `0x0200` proportional-price rule (`shipMass × cost`) when
    /// the flag is set, otherwise the flat `cost`. Exposed for purchase-time
    /// code (e.g. `PilotStore.buyOutfit`/`sellOutfit`) to charge/refund
    /// correctly; not consumed anywhere in this file today since this file
    /// aggregates *stats*, not credits.
    /// A non-positive cost is free; a scaled price never falls below the base
    /// cost (`Outfit_ComputeOutfitPurchasePrice` 0x0046e910, EC-14).
    public func effectiveCost(shipMass: Int) -> Int {
        guard cost > 0 else { return 0 }
        guard priceIsShipMassProportional else { return cost }
        return max(cost, shipMass * cost)
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
    /// - Parameter includeDefaultItems: whether to fold in the hull's own
    ///   `shïp.DefaultItems`. The Bible is explicit that these are for the
    ///   *player*: "Up to eight default items with which to equip this ship when
    ///   the player buys or captures one. Note that **AI-controlled ships will
    ///   ignore these fields**." Pass `false` for anything the spawner puts in
    ///   the world under AI control — an ambient trader, a fleet escort, a
    ///   mission ship, a planet's defenders — so NPCs fly the hull as authored
    ///   (stock weapons from `shïp`'s own WeapType list, plus any `përs`
    ///   customisation) rather than with the afterburners, shield boosters and
    ///   extra fuel the player would buy one with. Leaving this on for NPCs made
    ///   every spawned ship measurably tougher than the original's, which then
    ///   skewed every combat-odds decision downstream.
    /// - Parameter includeHullWeapons: whether the hull's own `shïp.WeapType`
    ///   stock weapons are added on top of `extraOutfits`. `true` for NPCs, which
    ///   is how an AI ship is armed at all. `false` for the **player**, whose
    ///   stock weapons have been materialised into `PlayerState.outfits` as the
    ///   `oütf` ids that install them (the Bible: those fields are "which stock
    ///   weapons to put on your ship when you first buy it" — the buyer's, like
    ///   `DefaultItems`) so they can be seen, counted against gun mounts and sold.
    ///   Adding them here as well would arm the player twice over. Only weapons
    ///   an outfit actually installs are skipped: a plug-in hull carrying a weapon
    ///   no `oütf` sells keeps it inherent rather than losing it.
    /// - Parameter defaultItemCapabilities: with `includeDefaultItems` off, still
    ///   read the hull's DefaultItems for *capabilities* (cloak, scanners, fuel
    ///   and mining scoops, jump outfits, repair, jamming) but not stats. That is
    ///   the original's NPC split (OS-01); every AI spawn passes `true`. The
    ///   player passes `false`, since `PlayerState.outfits` already owns them.
    public func loadout(shipID: Int, extraOutfits: [Int: Int] = [:],
                        includeDefaultItems: Bool = true,
                        includeHullWeapons: Bool = true,
                        defaultItemCapabilities: Bool = false) -> Loadout? {
        guard let s = game.ship(shipID) else {
            Log.world.error("Galaxy.loadout: ship id \(shipID) not found in game data — returning nil loadout")
            return nil
        }

        // Merge preinstalled outfits with anything else installed.
        var outfitCounts: [Int: Int] = [:]
        if includeDefaultItems {
            for (oid, c) in s.outfits { outfitCounts[oid, default: 0] += c }
        }
        for (oid, c) in extraOutfits where c > 0 { outfitCounts[oid, default: 0] += c }

        // Aggregate in stat-space (the same units the hull stores).
        var shieldStat = s.shield, armorStat = s.armor
        var shieldRechStat = s.shieldRecharge, armorRechStat = s.armorRecharge
        var speedStat = s.speed, accelStat = s.acceleration, turnStat = s.turnRate, turnBonus = 0
        var fuelCap = s.fuelCapacity
        // Per-tick fuel from ModType-18 outfits: each adds `count × (1/ModVal)`
        // (0x00463b30). A zero ModVal would divide by zero in the original;
        // it's skipped here.
        var fuelScoopPerTick = 0.0
        var cargo = s.cargoSpace
        var maxGuns = s.maxGuns, maxTurrets = s.maxTurrets
        var usedMass = 0
        var usedGunSlots = 0, usedTurretSlots = 0
        var afterburnerFuel = 0, afterburnerOutfitID = Int.min
        var multiJumpBonus = 0
        // Fast jump: class Flags2 0x0020 or a ModType-37 outfit (0x0046d080).
        var fastJump = s.flags2 & 0x0020 != 0
        var hyperspaceSpeed = 0
        var marineCrew = 0
        var captureOddsBonus = 0
        var cloakFlags = 0, cloakScannerFlags = 0
        var interferenceReduction = 0, murkModifier = 0
        var ionCapBonus = 0, deionizeBonus = 0
        // Four independent jammer types (ModTypes 33-36), kept separate so each
        // only counters the seekers whose `JamVuln` names it.
        var jammingBonus = [0, 0, 0, 0]
        // Only ModType 31 scoops for the player; hull Flags3 0x0002 drives the
        // AI miner, not the player's scoop (OS-11).
        var hasMiningScoop = false
        // Only a ModType-11 outfit ejects; the hull's PodCount is cosmetic (OS-02).
        var hasEscapePod = false, hasAutoEject = false
        var inertialess = s.inertialess        // hull flag; an inertial-dampener outfit ORs in below
        var grantedWeapons: [Int: Int] = [:]   // weapon id → count
        var ammoAdds: [Int: Int] = [:]         // weapon id → extra ammo units
        var hyperspaceDistBonus = 0
        var hasAutoRefuel = false, hasDensityScanner = false, hasRepairSystem = false
        var reinforcementInhibitorClasses: Set<Int> = []
        var iffScramblerClasses: Set<Int> = []
        var paintColor: (r: Double, g: Double, b: Double)?
        var hasGravityResist = false, hasStellarResist = false

        // Sorted: dictionary order is per-process random, and the last paint
        // outfit wins / Double sums depend on order (determinism).
        for (oid, count) in outfitCounts.sorted(by: { $0.key < $1.key }) {
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
            if o.techLevel < 0x7fff {
                if o.firstSlot.type == OutfitModType.weapon.rawValue {
                    grantedWeapons[o.firstSlot.value, default: 0] += count
                } else if o.firstSlot.type == OutfitModType.ammunition.rawValue {
                    ammoAdds[o.firstSlot.value, default: 0] += count
                }
            }
            for (type, value) in o.modifiers {
                let v = value * count
                switch type {
                case .shield:          shieldStat += v
                case .shieldRecharge:  shieldRechStat += v
                case .armor:           armorStat += v
                case .armorRecharge:   armorRechStat += v
                case .speed:           speedStat += v
                case .acceleration:    accelStat += v
                case .turnRate:        turnBonus += v               // ModVal × 0.01 deg/tick
                case .fuelCapacity:    fuelCap += v
                case .fuelRegen:       if value != 0 { fuelScoopPerTick += Double(count) / Double(value) }
                case .freeCargo:       cargo += v
                case .maxGuns:         maxGuns += value               // once per def (0x004656a0)
                case .maxTurrets:      maxTurrets += value
                case .afterburner:
                    // The last owned afterburner's burn wins; counts don't stack.
                    if oid > afterburnerOutfitID { afterburnerFuel = value; afterburnerOutfitID = oid }
                case .multiJump:       multiJumpBonus += value    // once per def (0x0046cdd0)
                case .fastJump:        fastJump = true            // skips the jump's brake (FL-06)
                case .hyperspaceSpeed: hyperspaceSpeed += v        // faster jump entry/exit sequence
                // Weapons and ammunition come from the first slot only, and
                // not from a TechLevel-32767 outfit (0x00463260); see below.
                case .weapon, .ammunition: break
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
                case .jam1: jammingBonus[0] += value                 // ModType 33, once per def (0x00464810)
                case .jam2: jammingBonus[1] += value                 // ModType 34
                case .jam3: jammingBonus[2] += value                 // ModType 35
                case .jam4: jammingBonus[3] += value                 // ModType 36
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

        // An AI ship's stats ignore its hull's DefaultItems, but every capability
        // probe in the original has an NPC arm that walks them (OS-01): cloak,
        // scanners, fuel scoop, mining scoop, jump outfits, repair and jamming.
        if !includeDefaultItems && defaultItemCapabilities {
            for (oid, count) in s.outfits {
                guard let o = game.outfit(oid) else { continue }
                for (type, value) in o.modifiers {
                    switch type {
                    case .cloak:          cloakFlags |= value
                    case .cloakScanner:   cloakScannerFlags |= value
                    case .fuelRegen:      if value != 0 { fuelScoopPerTick += Double(count) / Double(value) }
                    case .miningScoop:    hasMiningScoop = true
                    case .fastJump:       fastJump = true
                    case .multiJump:      multiJumpBonus += value
                    case .repairSystem:   hasRepairSystem = true
                    case .jam1:           jammingBonus[0] += value
                    case .jam2:           jammingBonus[1] += value
                    case .jam3:           jammingBonus[2] += value
                    case .jam4:           jammingBonus[3] += value
                    default: break
                    }
                }
            }
        }

        // Resolve weapons: stock hull weapons + outfit-granted, merged by id.
        var byID: [Int: (count: Int, ammo: Int)] = [:]
        for w in s.weapons {
            // See `includeHullWeapons`: for the player these already arrived as
            // owned outfits, so re-adding them here would double the armament.
            if !includeHullWeapons, game.outfitInstalling(weapon: w.id) != nil { continue }
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
        for (wid, entry) in byID.sorted(by: { $0.key < $1.key }) where game.weapon(wid)?.isFighterBay == true {
            guard let w = game.weapon(wid) else { continue }
            let capacity = w.fighterCapacity * max(1, entry.count)
            fighterBays.append(FighterBaySpec(bayWeaponID: wid, fighterShipID: w.fighterShipID,
                                              capacity: capacity,
                                              launchIntervalFrames: max(1, w.reload)))
            byID[wid] = (entry.count, capacity)
        }
        let weapons = byID.map { (id: $0.key, count: $0.value.count, ammo: $0.value.ammo) }
            .sorted { $0.id < $1.id }

        // FuelRegen is frames per unit of fuel; NPCs always qualify, the player
        // only with hull Flags 0x0008.
        let hullFuelPerTick = s.fuelRegen > 0 ? 1.0 / Double(s.fuelRegen) : 0
        let ticks = OriginalClock.ticksPerSecond

        let afterburner = afterburnerOutfitID != Int.min
            ? Afterburner(fuelPerSecond: Double(afterburnerFuel) * 0.0333 * OriginalClock.ticksPerSecond) : nil

        return Loadout(
            shipID: s.id, name: s.displayName,
            speed: max(0, speedStat), acceleration: max(0, accelStat), turnRate: max(0, turnStat),
            turnBonus: turnBonus,
            maxShield: Double(max(0, shieldStat)) * combatTuning.hpScale,
            maxArmor: Double(max(1, armorStat)) * combatTuning.hpScale,
            shieldRechargePerSec: max(0, Double(shieldRechStat) * 0.03),
            armorRechargePerSec: max(0, Double(armorRechStat) * 0.03),
            // ModType 12 capacity is clamped to 0...32000 (0x00463a20).
            maxFuel: Double(min(32000, max(0, fuelCap))),
            fuelRegenPerSec: (hullFuelPerTick + fuelScoopPerTick) * ticks,
            playerFuelRegenPerSec: ((s.flags & 0x0008 != 0 ? hullFuelPerTick : 0) + fuelScoopPerTick) * ticks,
            afterburner: afterburner,
            cargoCapacity: max(0, cargo),
            // The loader raises the class FreeMass by the purchase mass of the
            // hull's stock weapons, their ammunition and its DefaultItems
            // (0x004bd3c0, EC-08), and `usedMass` counts every owned outfit —
            // stock fittings included — so a stock hull shows exactly its
            // resource FreeMass.
            massCapacity: s.freeMass + game.stockFittingMass(s), usedMass: usedMass,
            blocksMassExpansion: s.blocksMassExpansion,
            maxGuns: maxGuns, maxTurrets: maxTurrets,
            usedGunSlots: usedGunSlots, usedTurretSlots: usedTurretSlots,
            outfits: outfitCounts, weapons: weapons,
            // Multi-jump depth is 1 + Σ ModVal; the fire block then advances
            // depth − 1 route systems, at least one (OQ A3).
            maxJumpHops: max(1, multiJumpBonus),
            multiJumpDepth: max(1, 1 + multiJumpBonus),
            instantJump: fastJump,
            hyperspaceSpeedBonus: hyperspaceSpeed,
            fighterBays: fighterBays,
            cloakFlags: cloakFlags, cloakScannerFlags: cloakScannerFlags,
            interferenceReduction: interferenceReduction, murkModifier: murkModifier,
            hasEscapePod: hasEscapePod, hasAutoEject: hasAutoEject, inertialess: inertialess,
            crew: max(0, s.crew), marineCrew: marineCrew, captureOddsBonus: captureOddsBonus,
            ionCapacityBonus: max(0, ionCapBonus), deionizeBonus: max(0, deionizeBonus),
            jamming: jammingBonus.map { max(0, min(100, $0)) }, hasMiningScoop: hasMiningScoop,
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
    /// - Parameter includeDefaultItems: see `loadout(shipID:extraOutfits:includeDefaultItems:)`.
    ///   Pass `false` for AI-controlled spawns, with `defaultItemCapabilities: true`.
    public func makeLoadedShip(_ shipID: Int, government govt: Int? = nil,
                               extraOutfits: [Int: Int] = [:],
                               at position: Vec2 = Vec2(), angle: Double = 0,
                               skillScale: Double? = nil,
                               includeDefaultItems: Bool = true,
                               includeHullWeapons: Bool = true,
                               defaultItemCapabilities: Bool = false) -> Ship? {
        guard let lo = loadout(shipID: shipID, extraOutfits: extraOutfits,
                               includeDefaultItems: includeDefaultItems,
                               includeHullWeapons: includeHullWeapons,
                               defaultItemCapabilities: defaultItemCapabilities) else {
            // Falls back to an un-equipped hull (`makeShip`) — if this fires
            // for the player's own ship, they'll fly with none of their
            // fitted outfits and no other clue why.
            Log.world.error("Galaxy.makeLoadedShip: loadout(\(shipID)) failed — falling back to an unequipped makeShip(\(shipID))")
            return makeShip(shipID, government: govt, at: position, angle: angle, skillScale: skillScale)
        }
        // EV Nova hulls rotate through 36 headings. (shän's other counts are
        // *animation sets* — banking / lit variants — not headings, so we must NOT
        // use them here; this count must match SpriteTextures.rotationFrames.)
        let shan = game.shan(shipID)
        let frames = 36
        let radius: Double = shan.map { max(10, Double(max($0.baseWidth, $0.baseHeight)) / 2) } ?? 18
        let shipRes = game.ship(shipID)
        let baseStats = ShipStats(speed: lo.speed, acceleration: lo.acceleration,
                                  turnRate: lo.turnRate, turnBonus: lo.turnBonus,
                                  rotationFrames: frames, tuning: flightTuning)
        let stats = skilledStats(baseStats, skillScale: skillScale,
                                 government: govt ?? shipRes?.inherentCombatGovt ?? independentGovt, game: game)
        let ship = Ship(name: lo.name, stats: stats, position: position, angle: angle)
        ship.shipTypeID = shipID
        ship.explosionSoundID = shipRes.flatMap { game.deathExplosionSoundID($0) }
        ship.explosionBoomID = shipRes.flatMap { $0.finalExplosionBoomID ?? $0.breakupExplosionBoomID }
        // `inherentGovt` is encoded (e.g. 1130 = attributes-only govt 130, no
        // combat govt); use the decoded combat govt so an encoded hull isn't
        // assigned a nonexistent government id like 1130.
        ship.government = govt ?? shipRes?.inherentCombatGovt ?? independentGovt
        ship.radius = radius
        ship.exitPoints = exitPoints(forShip: shipID)
        ship.combatStrength = Double(max(1, shipRes?.strength ?? 1))
        ship.disableArmorFraction = (shipRes.map { $0.flags & 0x0010 != 0 } ?? false) ? Ship.lowDisableFraction : Ship.standardDisableFraction
        ship.fleeWhenOutOfAmmo = shipRes?.fleeWhenOutOfAmmo ?? false
        ship.ionizeMax = Double(max(0, shipRes?.ionizeMax ?? 0) + lo.ionCapacityBonus)
        ship.deionizePerSec = (shipRes?.deionizePerTick ?? 1.0) * 30 + Double(lo.deionizeBonus) * 0.3
        ship.jamming = lo.jamming
        ship.rawTurnRate = shipRes?.turnRate ?? 0
        ship.keyCarriedShipID = shipRes?.keyCarriedShipID ?? -1
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
        ship.instantJump = lo.instantJump
        ship.hasDensityScanner = lo.hasDensityScanner
        ship.reinforcementInhibitorClasses = lo.reinforcementInhibitorClasses
        ship.iffScramblerClasses = lo.iffScramblerClasses
        ship.paintColor = lo.paintColor
        ship.hullShieldsStellars = shipRes?.ignoresDeadlyStellars ?? false
        ship.hasGravityResistOutfit = lo.hasGravityResist
        ship.hasStellarResistOutfit = lo.hasStellarResist
        if let shipRes { ship.applyHullTraits(shipRes) }

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
        // The player's ammo weapons share one pool per AmmoType (B-3); NPCs
        // and bays keep their own rounds. The loadout already credited the
        // whole pool to each mount naming it.
        if !includeHullWeapons {
            var pools: [Int: AmmoPool] = [:]
            for m in mounts where (0...255).contains(m.spec.ammoTypeRaw) && m.spec.guidance != .bay && m.ammo >= 0 {
                let key = m.spec.ammoTypeRaw
                if let p = pools[key] { m.pool = p } else {
                    let p = AmmoPool(rounds: m.ammo)
                    pools[key] = p
                    m.pool = p
                }
            }
        }
        ship.weapons = mounts
        return ship
    }
}

extension NovaGame {
    /// The purchase mass of everything a hull comes with — its stock weapons
    /// (through the outfit that installs each), their `AmmoLoad` and its
    /// `DefaultItems` — which the original's loader adds to the class FreeMass
    /// (0x004bd3c0). Items at TechLevel 32767 or above are left out, as there.
    public func stockFittingMass(_ s: ShipRes) -> Int {
        var total = 0
        func add(_ oid: Int?, _ count: Int) {
            guard let oid, count > 0, let o = outfit(oid), o.techLevel < 0x7FFF else { return }
            total += o.effectiveMass(shipMass: s.mass) * count
        }
        for w in s.weapons {
            add(outfitInstalling(weapon: w.id), w.count)
            add(outfitLoadingAmmo(for: w.id), w.ammo)
        }
        for (oid, count) in s.outfits { add(oid, count) }
        return total
    }
}
