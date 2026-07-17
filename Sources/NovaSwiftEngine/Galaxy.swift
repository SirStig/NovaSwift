import Foundation
import NovaSwiftKit

/// A stellar object the AI can navigate to (planet / station). `canLand` gates
/// whether traders will treat it as a destination — true only for bodies that
/// are both landable (`spöb.isLandable`) AND inhabited (`!spöb.isUninhabited`,
/// flag 0x20): the AI should only ever land on inhabited planets/stations, per
/// the Bible's own "uninhabited" services flag, never bare rocks or deep-space
/// stellars that happen to carry a landing pict.
public struct StellarBody {
    public let id: Int
    public let position: Vec2
    public let radius: Double
    public let canLand: Bool
    /// `spöb.isLandable`, *without* the inhabited requirement `canLand` adds —
    /// true for any body with real landing art, including bare/uninhabited
    /// rocks. This is what gates whether the *player* may approach and select
    /// a body to land on (`GameScene.isPlayerLandTarget`): the player can set
    /// down on an uninhabited body (getting the bare, services-less spaceport
    /// screen `SpaceportView` already renders for one), even though the AI
    /// never treats it as a travel destination.
    public let isLandable: Bool
    /// The government that owns this stellar (`spöb.Govt`; < 128 = independent).
    /// Drives hypergate clearance and which government's ships emerge from a gate.
    public let government: Int
    public let isHypergate: Bool
    public let isWormhole: Bool
    /// `spöb.Flags2` 0x0100: "all ships that touch it are destroyed
    /// immediately" (Bible). No stock stellar sets this bit — see
    /// `SpobRes.isDeadly` — but the flag reads correctly if a plug-in uses it.
    public let isDeadly: Bool
    /// Fixed emerge angle (radians, engine convention) for ships appearing from
    /// this gate, or nil to pick a random direction. Non-gates: nil.
    public let gateEmergeAngle: Double?
    public var isGate: Bool { isHypergate || isWormhole }

    public init(id: Int, position: Vec2, radius: Double, canLand: Bool, isLandable: Bool? = nil,
                government: Int = independentGovt, isHypergate: Bool = false,
                isWormhole: Bool = false, isDeadly: Bool = false, gateEmergeAngle: Double? = nil) {
        self.id = id; self.position = position; self.radius = radius; self.canLand = canLand
        // Defaults to `canLand` when the caller doesn't distinguish the two
        // (test fixtures, ad-hoc bodies) — `canLand` already implies landable.
        self.isLandable = isLandable ?? canLand
        self.government = government; self.isHypergate = isHypergate
        self.isWormhole = isWormhole; self.isDeadly = isDeadly; self.gateEmergeAngle = gateEmergeAngle
    }
}

/// The geometry of the system the player is currently in: its landable bodies,
/// its centre, and the radius at which ships enter/leave hyperspace. Drives NPC
/// navigation (travel, patrol, flee/jump-out) and where new arrivals appear.
public struct SystemContext {
    public var bodies: [StellarBody] = []
    public var center: Vec2 = Vec2()
    /// Ships past this radius from `center` are at the hyperspace edge. Default
    /// matches the *smallest* end of `systemContext(for:)`'s normal clamped
    /// range (1400...3200) rather than some larger guess — this value is what
    /// a lookup-miss fallback (system id not found) hands back, and a small
    /// safe default there reads as "somewhat quiet" instead of stranding the
    /// player absurdly far from center in a system that was never actually
    /// this size.
    public var jumpRadius: Double = 1400
    /// Where arriving NPCs pop in (just inside the edge).
    public var spawnRadius: Double = 1190
    /// Half-width of the wrap-around playfield, centred on `center`. EV Nova's
    /// systems are a fixed finite size that wraps toroidally: fly off one edge and
    /// you reappear on the opposite side (the player's "no walls, but you roll over
    /// to the other side"). Kept comfortably larger than `jumpRadius` so an NPC
    /// heading out to jump reaches the hyperspace edge (and despawns) well before
    /// it would ever wrap. See `World.wrapIntoSystem`.
    public var wrapExtent: Double = 10000
    /// The government that controls this system (`sÿst.Govt`). Drives which
    /// ships count as "the local authority" and may run the patrol beat / scan
    /// traffic — foreign combat ships just pass through. `independentGovt`
    /// (unowned) means anyone armed may patrol.
    public var systemGovt: Int = independentGovt

    public init() {}
    public init(bodies: [StellarBody], center: Vec2 = Vec2(),
                jumpRadius: Double = 1400, spawnRadius: Double = 1190,
                wrapExtent: Double = 10000, systemGovt: Int = independentGovt) {
        self.bodies = bodies; self.center = center
        self.jumpRadius = jumpRadius; self.spawnRadius = spawnRadius
        self.wrapExtent = wrapExtent
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
    /// `shïp.Flags2` 0x0040 — inertialess (no-drift) flight.
    public let inertialess: Bool
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
    /// `bööm` id for this hull's death explosion (final, falling back to breakup),
    /// or nil — drives the real explosion sprite the renderer plays on death.
    public let explosionBoomID: Int?
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
    private var fleetCatalogCache: [FleetRes]?

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

    /// Every `flët` the data defines, decoded once and cached. EV Nova spawns
    /// fleets galaxy-wide by `flët.LinkSyst` (a fleet listed in *no* system's
    /// own spawn table still appears across every system its `LinkSyst` matches —
    /// this is how the game is full of Federation patrols, pirate packs, and
    /// cargo convoys even though almost no `sÿst` pins a fleet in its `DudeTypes`
    /// table). The `Spawner` sweeps this catalog per system; decoding all ~256
    /// fleets on every system entry was needless churn, so it's cached here.
    public func fleetCatalog() -> [FleetRes] {
        if let cached = fleetCatalogCache { return cached }
        let fleets = game.fleets()
        fleetCatalogCache = fleets
        return fleets
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
            shieldRechargePerSec: max(0, Double(s.shieldRecharge) * 0.03),
            armorRechargePerSec: Double(s.armorRecharge) * 0.03,
            radius: radius, government: s.inherentCombatGovt, strength: s.strength,
            disableArmorFraction: (s.flags & 0x0010 != 0) ? 0.10 : 0.33, skillVar: s.skillVar,
            fleeWhenOutOfAmmo: s.fleeWhenOutOfAmmo, inertialess: s.inertialess,
            ionizeMax: Double(max(0, s.ionizeMax)),
            deionizePerSec: Ship.flooredDeionize(rate: Double(max(0, s.deionize)) * 0.3,
                                                 ionizeMax: Double(max(0, s.ionizeMax))),
            mounts: mounts, explosionSoundID: game.deathExplosionSoundID(s),
            explosionBoomID: s.finalExplosionBoomID ?? s.breakupExplosionBoomID,
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
        ship.explosionBoomID = spec.explosionBoomID
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
        ship.inertialess = spec.inertialess
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
            // `spöb.X/Y` is the same classic Mac/QuickDraw-era coordinate format as
            // `sÿst.X/Y` (galaxy-map position, authored +y-down — see
            // `GameContainerView.outboundHeading`'s doc comment), so it needs the
            // same flip into this engine's +y-up world. Left unflipped, every
            // system's in-system layout (planet placement/orbit angle) renders
            // vertically mirrored relative to the real game.
            let pos = Vec2(Double(s.x), Double(-s.y))
            // Match the same sprite-derived size the renderer uses (GameContainerView's
            // PlanetVisual), so landing/collision geometry agrees with what's on screen
            // instead of every body sharing one hardcoded radius.
            let radius = Double(game.spobSprite(spobID)?.frameWidth ?? 48) / 2
            // `canLand` stays "landable AND inhabited" so AI traders/patrols keep
            // treating only real ports as destinations — gates are handled by the
            // player-landing/gate paths separately (see `isGate`), never as trade
            // stops. EV Nova gate emerge angles are degrees clockwise from north,
            // which matches this engine's `Vec2(sinθ, cosθ)` heading directly.
            bodies.append(StellarBody(
                id: spobID, position: pos, radius: radius,
                canLand: s.isLandable && !s.isUninhabited, isLandable: s.isLandable,
                government: s.government, isHypergate: s.isHypergate, isWormhole: s.isWormhole,
                isDeadly: s.isDeadly,
                gateEmergeAngle: s.gateEmergeAngle.map { $0 * .pi / 180 }))
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
        // believable everywhere. Tuned down from an earlier 2600–6000 band that
        // left the player's post-hyperjump arrival (spawnRadius, below) coasting
        // in from far past where the real game ever put you — the original
        // arrival always read as "just off the system's bulk," not a multi-second
        // crossing from its outer edge.
        let dists = bodies.map { ($0.position - center).length }.sorted()
        let ref: Double = dists.isEmpty ? 900
            : dists[min(dists.count - 1, Int((Double(dists.count - 1) * 0.8).rounded()))]
        let jumpRadius = min(3200, max(1400, ref * 1.1 + 400))
        // Fixed, finite playfield that wraps toroidally (EV Nova's systems roll
        // over at the edge). Held well clear of `jumpRadius` (max 6000) so ships
        // heading out to jump always hit the hyperspace edge before the wrap.
        let wrapExtent = max(jumpRadius + 3000, 10000)
        return SystemContext(bodies: bodies, center: center,
                             jumpRadius: jumpRadius, spawnRadius: jumpRadius * 0.85,
                             wrapExtent: wrapExtent, systemGovt: sys.government)
    }
}
