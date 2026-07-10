import Foundation

// Typed decoders for EV Nova resource *bodies*. Field offsets are the on-disk
// byte layout (big-endian), cross-checked against NovaJS `novaparse` and the
// EV Nova Bible. All multi-byte fields are big-endian (classic Mac / QuickDraw).

// MARK: Little byte helpers (big-endian, bounds-safe)

@inline(__always) private func i16(_ d: Data, _ off: Int) -> Int {
    guard off >= 0, off + 2 <= d.count else { return 0 }
    let base = d.startIndex + off
    let v = (Int(d[base]) << 8) | Int(d[base + 1])
    return v >= 0x8000 ? v - 0x10000 : v
}

@inline(__always) private func u16(_ d: Data, _ off: Int) -> Int {
    guard off >= 0, off + 2 <= d.count else { return 0 }
    let base = d.startIndex + off
    return (Int(d[base]) << 8) | Int(d[base + 1])
}

@inline(__always) private func u32(_ d: Data, _ off: Int) -> UInt32 {
    guard off >= 0, off + 4 <= d.count else { return 0 }
    let b = d.startIndex + off
    return (UInt32(d[b]) << 24) | (UInt32(d[b + 1]) << 16) | (UInt32(d[b + 2]) << 8) | UInt32(d[b + 3])
}

/// A single 64-bit big-endian flag field (`Contribute`/`Require` — ResForge's
/// `QB64` template type reads them as one 8-byte value, not two Int32s).
@inline(__always) private func u64(_ d: Data, _ off: Int) -> UInt64 {
    guard off >= 0, off + 8 <= d.count else { return 0 }
    let b = d.startIndex + off
    var v: UInt64 = 0
    for i in 0..<8 { v = (v << 8) | UInt64(d[b + i]) }
    return v
}

/// Read a NUL-terminated Mac Roman C-string from a fixed-size field at `off`,
/// reading at most `maxLen` bytes. Trailing garbage after the NUL is ignored.
@inline(__always) private func cstr(_ d: Data, _ off: Int, _ maxLen: Int) -> String {
    guard off >= 0, off < d.count else { return "" }
    let start = d.startIndex + off
    let end = min(start + maxLen, d.endIndex)
    var bytes: [UInt8] = []
    var i = start
    while i < end {
        let b = d[i]
        if b == 0 { break }
        bytes.append(b)
        i += 1
    }
    return String(bytes: bytes, encoding: .macOSRoman) ?? ""
}

// MARK: spïn — sprite descriptor (which rlëD, and its tile grid)

public struct SpinRes {
    public let id: Int
    public let spriteID: Int   // → rlëD / rlë8 resource id
    public let maskID: Int
    public let tileWidth: Int
    public let tileHeight: Int
    public let tilesAcross: Int
    public let tilesDown: Int

    public init(_ r: Resource) {
        id = r.id
        let d = r.data
        spriteID = i16(d, 0)
        maskID = i16(d, 2)
        tileWidth = i16(d, 4)
        tileHeight = i16(d, 6)
        tilesAcross = i16(d, 8)
        tilesDown = i16(d, 10)
    }
}

// MARK: shän — ship animation (base hull + engine glow/light/weapon overlay
// layers, and real per-hull weapon exit points). Full 192-byte layout verified
// byte-for-byte against ResForge's Shan Editor (`ShanWindowController.load()`,
// third_party/ResForge/Plugins/Sources/NovaTools/Shan Editor/) and cross-checked
// against real base-game data (e.g. shän #131 "Leviathan": engine layer 1406/
// 1407/180×180 distinct from the 1006/1007/144×144 base layer; beamPoints show
// a genuine symmetric (±20, 40) dual-turret mount pair).

/// One weapon exit point on a hull, in the ship's own sprite-space coordinates
/// (origin at the hull's centre; +y is "up" in the unrotated sprite, i.e. the
/// nose direction). `z` is QuickDraw draw-order depth (front/behind the hull),
/// not a third spatial axis.
public struct ShanExitPoint {
    public let x: Int
    public let y: Int
    public let z: Int
}

public struct ShanRes {
    public let id: Int
    public let baseSpriteID: Int   // → rlëD id directly (spïn indirection is a fallback; see NovaGame.shipSpriteData)
    public let baseSetCount: Int   // number of animation *sets* (banking/lit variants), NOT headings; hulls rotate through 36 headings
    public let baseWidth: Int
    public let baseHeight: Int
    /// The ship's own authored engine-glow overlay sprite (→ rlëD id), drawn
    /// centred on the hull and additively blended — real per-hull thruster
    /// art, not a synthesized effect. <= 0 means this hull has none (rare;
    /// most warship/freighter hulls do).
    public let engineSpriteID: Int
    public let engineWidth: Int
    public let engineHeight: Int
    /// Real weapon mount points, up to 4 per kind (unused slots repeat a
    /// placeholder position — callers should cross-reference `ShipRes.maxGuns`/
    /// `maxTurrets`/weapon count to know how many are actually meaningful).
    public let gunPoints: [ShanExitPoint]
    public let turretPoints: [ShanExitPoint]
    public let guidedPoints: [ShanExitPoint]
    public let beamPoints: [ShanExitPoint]

    public init(_ r: Resource) {
        id = r.id
        let d = r.data
        baseSpriteID = i16(d, 0)
        baseSetCount = i16(d, 4)
        baseWidth = i16(d, 6)
        baseHeight = i16(d, 8)
        engineSpriteID = i16(d, 22)
        engineWidth = i16(d, 26)
        engineHeight = i16(d, 28)

        func points(xBase: Int, yBase: Int, zBase: Int) -> [ShanExitPoint] {
            (0..<4).map { i in
                ShanExitPoint(x: i16(d, xBase + i * 2), y: i16(d, yBase + i * 2), z: i16(d, zBase + i * 2))
            }
        }
        // x's then y's per point-kind (@72), then compress factors (@136-143),
        // then z's per point-kind (@144) — matches the on-disk field order.
        gunPoints = points(xBase: 72, yBase: 80, zBase: 144)
        turretPoints = points(xBase: 88, yBase: 96, zBase: 152)
        guidedPoints = points(xBase: 104, yBase: 112, zBase: 160)
        beamPoints = points(xBase: 120, yBase: 128, zBase: 168)
    }
}

// MARK: shïp — ship type & stats
//
// Full field layout verified against novaparse `ShipResource.ts` (the EV Nova
// reference parser). All big-endian. Note on **fuel**: EV Nova's ship resource
// stores a single blue-gauge resource at @10/@94 that novaparse labels "energy";
// in EV Nova this is the player-facing **Fuel** gauge (100 units = one hyperjump,
// also spent by afterburners). We name it `fuelCapacity`/`fuelRegen` accordingly.

public struct ShipRes {
    public let id: Int
    public let name: String

    // Cargo & mass
    public let cargoSpace: Int      // @0  base cargo hold, tons
    public let freeMass: Int        // @12 free mass available for outfits, tons
    public let mass: Int            // @62 hull mass (inertia / scan)

    // Defenses
    public let shield: Int          // @2  max shield
    public let shieldRecharge: Int  // @16 shield regen stat (→ pts/sec via ×FPS/1000)
    public let armor: Int           // @14 max armor
    public let armorRecharge: Int   // @54 armor regen stat (0 for most hulls)
    /// `bööm` id for the mid-death "breaking up" explosion, or nil if none.
    public let breakupExplosionBoomID: Int?  // @56
    /// `bööm` id for the final death explosion — drives the kill-sound the
    /// player actually hears when a ship dies. Falls back to
    /// `breakupExplosionBoomID` when absent.
    public let finalExplosionBoomID: Int?    // @58

    // Flight
    public let acceleration: Int    // @4
    public let speed: Int           // @6  max speed
    public let turnRate: Int        // @8

    // Fuel (the blue gauge; novaparse "energy")
    public let fuelCapacity: Int    // @10 fuel units (100 = one jump)
    public let fuelRegen: Int       // @94 fuel regen stat (frames per unit; 0 = none)

    // Weapon mounts
    public let maxGuns: Int         // @42
    public let maxTurrets: Int      // @44

    // Economy / meta
    public let techLevel: Int       // @46
    public let cost: Int            // @50
    public let deathDelay: Int      // @52
    public let length: Int          // @64
    public let crew: Int            // @68
    public let podCount: Int        // @76 escape pods

    /// Default AI disposition (0 = none); a spawning `düde` overrides it.
    public let inherentAI: Int      // @66
    /// Combat rating — how tough this hull is, used for engagement odds/morale.
    public let strength: Int        // @70
    /// Government this hull "belongs" to when spawned outside a `düde`.
    public let inherentGovt: Int    // @72
    public let flags: UInt16        // @74
    /// "Show % armor on target display instead of 'Shields Down'" (Nova Bible,
    /// `shïp.Flags` 0x0100) — only relevant once the target's shields are fully
    /// depleted (0%); the target readout normally shows literal "Shields Down"
    /// text in that case, this flag substitutes the armor percentage instead.
    public var showArmorOnTargetDisplay: Bool { flags & 0x0100 != 0 }
    /// "Don't show armor or shield state on status display" (Nova Bible,
    /// `shïp.Flags` 0x0200) — the target readout omits the shield/armor line
    /// entirely for this ship type.
    public var hidesShieldArmorOnStatusDisplay: Bool { flags & 0x0200 != 0 }
    /// "The amount (in percent) to which this ship's pilots' skill varies" —
    /// EV Nova Bible. Applied as a per-instance jitter to acceleration/turn
    /// rate (one pilot-skill roll affects both) so ships of the same class
    /// aren't all identical. 0 = no variance. Offset verified against
    /// novaparse `ShipResource.ts` (`skillVariation`).
    public let skillVar: Int        // @96
    /// Second flags field. Offset verified against novaparse `ShipResource.ts`
    /// (`flags2N`).
    public let flags2: UInt16       // @98
    /// "AI ships of this type will run away/dock if out of ammo for all
    /// ammo-using weapons" (EV Nova Bible, `shïp.Flags2` 0x0080).
    public var fleeWhenOutOfAmmo: Bool { flags2 & 0x0080 != 0 }
    /// "The rate at which this ship type dissipates ionization charge. A
    /// value of 100 equals 1 point of ion energy per 1/30th of a second"
    /// (Bible). Offset verified against novaparse `ShipResource.ts` (`deionize`).
    public let deionize: Int        // @874
    /// "The amount of ion charge at which a ship of this type will be
    /// considered 'fully ionized'" (Bible's IonizeMax). Offset verified
    /// against novaparse `ShipResource.ts` (`ionization`).
    public let ionizeMax: Int       // @876

    /// Built-in weapons: (weapon id, count, ammo). Drives NPC + starting loadouts.
    public let weapons: [(id: Int, count: Int, ammo: Int)]
    /// Preinstalled outfits: (outfit id, count). These grant their stat mods and
    /// weapons on top of the hull's stock weapons.
    public let outfits: [(id: Int, count: Int)]

    // Mission/story-gated availability (Nova Bible; offsets verified against
    // ResForge's `shïp` TMPL — see docs/DATA_FORMAT.md). Distinct from
    // `techLevel`, which fully hides a hull; these default to "shown, greyed,
    // unpurchasable" (see `Flags3` 0x0100/0x0200 below). Unlike outfits, ships
    // have no documented `RequireGovt` — the Bible's shïp section never
    // mentions govt-scoped requirements, so `require` applies everywhere.
    public let contribute: UInt64   // @100 bits this hull contributes toward outfits'/ships' Require
    public let availBits: String    // @108 NCB control-bit test expression gating purchase
    public let require: UInt64      // @896 bits that must be met (via owned outfits/current ship) to buy
    /// "The subtitle to show on the target display for this ship type" (Nova
    /// Bible). Offset verified against novaparse `ShipResource.ts` (`subtitle`)
    /// and real bytes: shïp #128 "Shuttle" carries the text "Version A" here.
    public let subtitle: String     // @1766, 64-byte NUL-terminated field
    public let flags3: UInt16       // @1830  0x0100 hide-if-unavailable · 0x0200 hide-if-require-unmet
    /// "The percent chance that a ship of this type will be available for
    /// purchase on a given day... A BuyRandom of 0 means this ship will never
    /// be made available for purchase" (Bible). @904. Unlike outfits, 0 means
    /// never here, not always.
    public let buyRandom: Int

    public init(_ r: Resource) {
        id = r.id
        name = r.name.isEmpty ? "Ship \(r.id)" : r.name
        let d = r.data
        cargoSpace = i16(d, 0)
        shield = i16(d, 2)
        acceleration = i16(d, 4)
        speed = i16(d, 6)
        turnRate = i16(d, 8)
        fuelCapacity = i16(d, 10)
        freeMass = i16(d, 12)
        armor = i16(d, 14)
        shieldRecharge = i16(d, 16)
        maxGuns = i16(d, 42)
        maxTurrets = i16(d, 44)
        techLevel = i16(d, 46)
        cost = i16(d, 50)
        deathDelay = i16(d, 52)
        armorRecharge = i16(d, 54)
        breakupExplosionBoomID = boomID(raw: i16(d, 56))
        finalExplosionBoomID = boomID(raw: i16(d, 58))
        mass = i16(d, 62)
        length = i16(d, 64)
        inherentAI = i16(d, 66)
        crew = i16(d, 68)
        strength = i16(d, 70)
        inherentGovt = i16(d, 72)
        flags = UInt16(truncatingIfNeeded: u16(d, 74))
        podCount = i16(d, 76)
        fuelRegen = i16(d, 94)
        skillVar = i16(d, 96)
        flags2 = UInt16(truncatingIfNeeded: u16(d, 98))
        deionize = i16(d, 874)
        ionizeMax = i16(d, 876)
        contribute = u64(d, 100)
        availBits = cstr(d, 108, 255)
        require = u64(d, 896)
        subtitle = cstr(d, 1766, 64)
        flags3 = UInt16(truncatingIfNeeded: u16(d, 1830))
        buyRandom = i16(d, 904)

        // Stock weapons: 4 primary slots (ids @18, counts @26, ammo @34) plus
        // 4 extended slots stored far down the resource (ids @1742, …).
        var w: [(Int, Int, Int)] = []
        for i in 0..<4 {
            let wid = i16(d, 18 + i * 2)
            if wid >= 128 { w.append((wid, i16(d, 26 + i * 2), i16(d, 34 + i * 2))) }
        }
        for i in 0..<4 {
            let wid = i16(d, 1742 + i * 2)
            if wid >= 128 { w.append((wid, i16(d, 1750 + i * 2), i16(d, 1758 + i * 2))) }
        }
        weapons = w

        // Preinstalled outfits: 4 slots (ids @78, counts @86) plus 4 more (@880/@888).
        var o: [(Int, Int)] = []
        for i in 0..<4 {
            let oid = i16(d, 78 + i * 2)
            if oid >= 128 { o.append((oid, max(1, i16(d, 86 + i * 2)))) }
        }
        for i in 0..<4 {
            let oid = i16(d, 880 + i * 2)
            if oid >= 128 { o.append((oid, max(1, i16(d, 888 + i * 2)))) }
        }
        outfits = o
    }

    /// Full-hide opt-ins (Bible `shïp.Flags3`): normally a locked hull still
    /// shows greyed-out; these bits mean "omit it from the shipyard list
    /// entirely" instead.
    public var hidesWhenLocked: Bool { flags3 & 0x0100 != 0 || flags3 & 0x0200 != 0 }
}

// MARK: sÿst — star system (map position, hyperspace links, stellar objects)

public struct SystRes {
    public let id: Int
    public let name: String
    public let x: Int
    public let y: Int
    public let links: [Int]  // ids of connected systems
    public let spobs: [Int]  // ids of stellar objects in this system
    /// What spawns here: (spawn id, probability). Positive id = `düde`; negative
    /// id = `flët` (fleet id = −value, so −128 → fleet 128).
    public let spawns: [(id: Int, prob: Int)]
    /// Roughly how many NPC ships populate the system at once.
    public let averageShips: Int
    /// Controlling government (−1 = independent/contested).
    public let government: Int
    /// How many asteroids to place in this system, 0-16 (`sÿst.Asteroids`).
    public let asteroidCount: Int
    /// Which `röid` type ids (128-143) are enabled for this system, per the
    /// `AstTypes` bitmask.
    public let asteroidTypeIDs: [Int]

    /// Spawn entries that reference dudes directly.
    public var dudeSpawns: [(dudeID: Int, prob: Int)] {
        spawns.filter { $0.id >= 128 }.map { (dudeID: $0.id, prob: $0.prob) }
    }
    /// Spawn entries that reference fleets.
    public var fleetSpawns: [(fleetID: Int, prob: Int)] {
        spawns.filter { $0.id < 0 }.map { (fleetID: -$0.id, prob: $0.prob) }
    }

    public init(_ r: Resource) {
        id = r.id
        name = r.name.isEmpty ? "System \(r.id)" : r.name
        let d = r.data
        x = i16(d, 0)
        y = i16(d, 2)
        links = (0..<16).map { i16(d, 4 + $0 * 2) }.filter { $0 >= 128 }
        spobs = (0..<16).map { i16(d, 36 + $0 * 2) }.filter { $0 >= 128 }
        // Spawn table: 8 ids @68, 8 probs @84 (verified: real Federation system
        // probabilities sum to 100), avg ship count @100, government @102.
        var sp: [(Int, Int)] = []
        for i in 0..<8 {
            let sid = i16(d, 68 + i * 2)
            let prob = i16(d, 84 + i * 2)
            if sid != -1 && sid != 0 && prob > 0 { sp.append((sid, prob)) }
        }
        spawns = sp
        averageShips = i16(d, 100)
        government = i16(d, 102)
        asteroidCount = max(0, min(16, i16(d, 106)))
        // AstTypes: two bitmask bytes. @148 ("roidTypes1") bits 0-7 select röid
        // 136-143 (dust/crystal); @149 ("roidTypes2") bits 0-7 select röid
        // 128-135 (metal/ice) — offsets and bit→id mapping verified against the
        // real sÿst TMPL (#521) and the Bible's "AstTypes" field table.
        let roidTypes1 = d.count > 148 ? Int(d[d.startIndex + 148]) : 0
        let roidTypes2 = d.count > 149 ? Int(d[d.startIndex + 149]) : 0
        var types: [Int] = []
        for bit in 0..<8 where (roidTypes2 >> bit) & 1 == 1 { types.append(128 + bit) }
        for bit in 0..<8 where (roidTypes1 >> bit) & 1 == 1 { types.append(136 + bit) }
        asteroidTypeIDs = types
    }
}

// MARK: röid — asteroid type (strength, yield, fragmentation)

/// One of the 16 asteroid types (`röid` #128-143). Fields verified byte-for-byte
/// against the real TMPL (#516, `evnova-extract tmpl … 516`) and the Nova Bible's
/// "The röid resource" section.
public struct RoidRes {
    public let id: Int
    public let name: String
    /// Equivalent to armor for ships.
    public let strength: Int
    /// Frame-advance rate through the 36-frame rotation sheet; 100 = 30 fps.
    public let spinRate: Int
    /// 0-5 = standard cargo type, 1000+ = jünk id, -1 = none.
    public let yieldType: Int
    /// Average resource-box yield on destruction, ±50%.
    public let yieldQty: Int
    public let partCount: Int
    public let partColor: NovaColor
    /// Sub-asteroid types to fragment into on death (-1 = none). If both are
    /// set, Nova randomly picks between them per fragment.
    public let fragType1: Int
    public let fragType2: Int
    /// Average number of sub-asteroids on death, ±50% (0 = no fragmentation).
    public let fragCount: Int
    /// `bööm` id (0-63, +1000 for the spark variant), -1 = none.
    public let explodeType: Int
    public let mass: Int

    public init(_ r: Resource) {
        id = r.id
        name = r.name.isEmpty ? "Asteroid \(r.id)" : r.name
        let d = r.data
        strength = i16(d, 0)
        spinRate = i16(d, 2)
        yieldType = i16(d, 4)
        yieldQty = i16(d, 6)
        partCount = i16(d, 8)
        if d.count >= 14 {
            let b = d.startIndex + 10
            partColor = NovaColor(r: d[b + 1], g: d[b + 2], b: d[b + 3])
        } else {
            partColor = NovaColor(r: 0, g: 0, b: 0)
        }
        fragType1 = i16(d, 14)
        fragType2 = i16(d, 16)
        fragCount = i16(d, 18)
        explodeType = i16(d, 20)
        mass = i16(d, 22)
    }
}

// MARK: spöb — stellar object (planet / station placed in a system)

public struct SpobRes {
    public let id: Int
    public let name: String
    public let x: Int
    public let y: Int
    public let graphicSpinID: Int  // → spïn id for the planet sprite
    public let flags: UInt32
    public let techLevel: Int
    public let government: Int
    public let landingPictID: Int
    /// Custom ambient `snd ` id for this stellar's spaceport (e.g. a station's
    /// own hum), or nil to use no special ambience. Verified empirically: Holpa
    /// Station (#299, government #129 "Auroran Empire") carries id 10033,
    /// "Auroran station.SFIL" — a real, thematically-correct pairing.
    public let ambientSoundID: Int?

    public init(_ r: Resource) {
        id = r.id
        name = r.name.isEmpty ? "Planet \(r.id)" : r.name
        let d = r.data
        x = i16(d, 0)
        y = i16(d, 2)
        // Graphic field 0..63 maps to spïn ids 2000+, with one skipped at 2058.
        var g = i16(d, 4) + 2000
        if g > 2058 { g -= 1 }
        graphicSpinID = g
        flags = u32(d, 6)
        techLevel = i16(d, 12)
        government = i16(d, 20)
        landingPictID = u16(d, 24)
        let rawAmbient = i16(d, 26)
        ambientSoundID = rawAmbient == -1 ? nil : rawAmbient
    }
}

// MARK: High-level accessor over a resolved ResourceCollection

/// Decode results shared by every copy of a `NovaGame` built from the same
/// `ResourceCollection`. Parsing a resource's raw bytes into its typed `...Res`
/// form (and decoding RLE sprite sheets) is pure and idempotent, so it only
/// ever needs to happen once — without this, views that read e.g. `outfits()`
/// several times per render (the Outfitter/Shipyard grids) re-parse the whole
/// catalog on every read. A class (not a `var` on the struct) so the cache
/// survives `NovaGame` being copied around by value.
private final class NovaGameCache {
    let lock = NSLock()
    var ships: [ShipRes]?
    var outfits: [OutfRes]?
    var govts: [GovtRes]?
    var shipSprites: [Int: SpriteSheet?] = [:]
    var engineGlowSprites: [Int: SpriteSheet?] = [:]
    var asteroidSprites: [Int: SpriteSheet?] = [:]
    var starfieldSprite: SpriteSheet??
}

/// Typed, indexed view of a merged `ResourceCollection`. Decodes resource bodies
/// on demand and resolves cross-references (e.g. a ship → its sprite).
public struct NovaGame {
    public let resources: ResourceCollection
    private let cache = NovaGameCache()
    public init(_ resources: ResourceCollection) { self.resources = resources }

    public func ship(_ id: Int) -> ShipRes? { resources.resource(NovaType.ship, id).map(ShipRes.init) }
    public func ships() -> [ShipRes] {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if let cached = cache.ships { return cached }
        let v = resources.resources(of: NovaType.ship).map(ShipRes.init)
        cache.ships = v
        return v
    }
    public func spin(_ id: Int) -> SpinRes? { resources.resource(NovaType.spin, id).map(SpinRes.init) }
    public func shan(_ id: Int) -> ShanRes? { resources.resource(NovaType.shan, id).map(ShanRes.init) }
    public func system(_ id: Int) -> SystRes? { resources.resource(NovaType.syst, id).map(SystRes.init) }
    public func systems() -> [SystRes] { resources.resources(of: NovaType.syst).map(SystRes.init) }
    public func spob(_ id: Int) -> SpobRes? { resources.resource(NovaType.spob, id).map(SpobRes.init) }

    // AI-driving resources.
    public func govt(_ id: Int) -> GovtRes? { resources.resource(NovaType.govt, id).map(GovtRes.init) }
    public func govts() -> [GovtRes] {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if let cached = cache.govts { return cached }
        let v = resources.resources(of: NovaType.govt).map(GovtRes.init)
        cache.govts = v
        return v
    }
    public func dude(_ id: Int) -> DudeRes? { resources.resource(NovaType.dude, id).map(DudeRes.init) }
    public func dudes() -> [DudeRes] { resources.resources(of: NovaType.dude).map(DudeRes.init) }
    public func fleet(_ id: Int) -> FleetRes? { resources.resource(NovaType.fleet, id).map(FleetRes.init) }
    public func fleets() -> [FleetRes] { resources.resources(of: NovaType.fleet).map(FleetRes.init) }
    public func weapon(_ id: Int) -> WeapRes? { resources.resource(NovaType.weapon, id).map(WeapRes.init) }
    public func weapons() -> [WeapRes] { resources.resources(of: NovaType.weapon).map(WeapRes.init) }
    public func boom(_ id: Int) -> BoomRes? { resources.resource(NovaType.boom, id).map(BoomRes.init) }

    /// A hull's death-explosion `snd` id: prefers the final explosion's sound,
    /// falling back to the breakup explosion's if the final one has none.
    public func deathExplosionSoundID(_ ship: ShipRes) -> Int? {
        [ship.finalExplosionBoomID, ship.breakupExplosionBoomID]
            .compactMap { $0 }
            .compactMap { boom($0)?.soundID }
            .first
    }
    public func outfit(_ id: Int) -> OutfRes? { resources.resource(NovaType.outfit, id).map(OutfRes.init) }
    public func outfits() -> [OutfRes] {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if let cached = cache.outfits { return cached }
        let v = resources.resources(of: NovaType.outfit).map(OutfRes.init)
        cache.outfits = v
        return v
    }

    // Starting scenarios (chär). Base ships one; plug-ins add more.
    public func character(_ id: Int) -> CharRes? { resources.resource(NovaType.char, id).map(CharRes.init) }
    public func characters() -> [CharRes] { resources.resources(of: NovaType.char).map(CharRes.init) }
    /// Scenarios to show in a new-pilot picker: hidden ("."-prefixed) scenarios are
    /// dropped when at least one visible scenario exists; otherwise all are shown.
    /// Sorted by id (the default character first if flagged).
    public func selectableScenarios() -> [CharRes] {
        let all = characters().sorted { ($0.isDefault ? 0 : 1, $0.id) < ($1.isDefault ? 0 : 1, $1.id) }
        let visible = all.filter { !$0.isHidden }
        return visible.isEmpty ? all : visible
    }

    // Story / mission resources (see MissionModels.swift).
    public func mission(_ id: Int) -> MissionRes? { resources.resource(NovaType.mission, id).map(MissionRes.init) }
    public func missions() -> [MissionRes] { resources.resources(of: NovaType.mission).map(MissionRes.init) }
    public func cron(_ id: Int) -> CronRes? { resources.resource(NovaType.cron, id).map(CronRes.init) }
    public func crons() -> [CronRes] { resources.resources(of: NovaType.cron).map(CronRes.init) }
    public func pers(_ id: Int) -> PersRes? { resources.resource(NovaType.pers, id).map(PersRes.init) }
    public func persons() -> [PersRes] { resources.resources(of: NovaType.pers).map(PersRes.init) }
    public func rank(_ id: Int) -> RankRes? { resources.resource(NovaType.rank, id).map(RankRes.init) }
    public func ranks() -> [RankRes] { resources.resources(of: NovaType.rank).map(RankRes.init) }
    public func roid(_ id: Int) -> RoidRes? { resources.resource(NovaType.roid, id).map(RoidRes.init) }
    public func roids() -> [RoidRes] { resources.resources(of: NovaType.roid).map(RoidRes.init) }
    public func desc(_ id: Int) -> DescRes? { resources.resource(NovaType.desc, id).map(DescRes.init) }
    public func stringList(_ id: Int) -> StringListRes? { resources.resource(NovaType.strList, id).map(StringListRes.init) }
    /// Convenience: the narrative text of a `dësc` resource, or "" if absent.
    public func descText(_ id: Int) -> String { desc(id)?.text ?? "" }

    /// Resolve a ship's base hull sprite: shïp id → shän (same id) → rlëD.
    ///
    /// For **ships**, the shän's base-image id references the `rlëD` directly (the
    /// spïn indirection is used for planets / weapons / asteroids, not hulls). We
    /// therefore try the direct `rlëD` first and only fall back through spïn if the
    /// data numbers it that way.
    public func shipSpriteData(_ shipID: Int) -> (spin: SpinRes?, rleD: Data)? {
        guard let shan = shan(shipID) else { return nil }
        if let rle = resources.resource(NovaType.rleD, shan.baseSpriteID)?.data {
            return (nil, rle)
        }
        if let spin = spin(shan.baseSpriteID),
           let rle = resources.resource(NovaType.rleD, spin.spriteID)?.data {
            return (spin, rle)
        }
        return nil
    }

    /// Decode a ship's base hull sprite sheet, if available. Cached per hull —
    /// RLE decode is real work, and this is called repeatedly for the same
    /// hull (every jump/land rebuilds the scene's own texture cache from
    /// scratch, and the Shipyard's fallback thumbnail calls this per tile,
    /// per render).
    public func shipSprite(_ shipID: Int) -> SpriteSheet? {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if let cached = cache.shipSprites[shipID] { return cached }
        guard let (_, rle) = shipSpriteData(shipID) else {
            cache.shipSprites[shipID] = .some(nil)
            return nil
        }
        let v = try? RLED.decode(rle)
        cache.shipSprites[shipID] = .some(v)
        return v
    }

    /// Decode a ship's real, per-hull-authored engine-glow overlay sprite (the
    /// `shän` engine layer), if this hull has one. Same rotation-frame layout
    /// as the base hull sprite — index it with the same `spriteFrame`. Cached
    /// for the same reason as `shipSprite`.
    public func engineGlowSprite(_ shipID: Int) -> SpriteSheet? {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if let cached = cache.engineGlowSprites[shipID] { return cached }
        guard let shan = shan(shipID), shan.engineSpriteID > 0,
              let rle = resources.resource(NovaType.rleD, shan.engineSpriteID)?.data else {
            cache.engineGlowSprites[shipID] = .some(nil)
            return nil
        }
        let v = try? RLED.decode(rle)
        cache.engineGlowSprites[shipID] = .some(v)
        return v
    }

    // MARK: Stellar objects

    /// Resolve a stellar object's sprite: spöb.graphic → spïn → rlëD.
    /// (Some stellars use PICT, which isn't decoded yet — those return nil.)
    public func spobSprite(_ spobID: Int) -> SpriteSheet? {
        guard let spob = spob(spobID) else { return nil }
        if let spin = spin(spob.graphicSpinID),
           let rle = resources.resource(NovaType.rleD, spin.spriteID)?.data {
            return try? RLED.decode(rle)
        }
        if let rle = resources.resource(NovaType.rleD, spob.graphicSpinID)?.data {
            return try? RLED.decode(rle)
        }
        return nil
    }

    /// Resolve an asteroid type's rotating rock sprite: `röid` id → `spïn`
    /// (fixed offset `röidID + 672`, the Bible's reserved 800-815 asteroid
    /// spïn range) → `rlëD`. Cached like `shipSprite`/`engineGlowSprite`.
    public func asteroidSprite(_ roidID: Int) -> SpriteSheet? {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if let cached = cache.asteroidSprites[roidID] { return cached }
        let spinID = roidID + 672
        var result: SpriteSheet?
        if let spin = spin(spinID), let rle = resources.resource(NovaType.rleD, spin.spriteID)?.data {
            result = try? RLED.decode(rle)
        }
        cache.asteroidSprites[roidID] = .some(result)
        return result
    }

    /// The real background star sprite (`spïn` #700 "Stars" → `rlëD`), a small
    /// multi-frame tile Nova scatters across the parallax starfield. Cached
    /// once — there is only ever one.
    public func starfieldSprite() -> SpriteSheet? {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if let cached = cache.starfieldSprite { return cached }
        var result: SpriteSheet?
        if let spin = spin(700), let rle = resources.resource(NovaType.rleD, spin.spriteID)?.data {
            result = try? RLED.decode(rle)
        }
        cache.starfieldSprite = .some(result)
        return result
    }

    /// A reasonable starting system when the pilot's start isn't known: the most
    /// populated system (most stellar objects), so there's something to see.
    public func startingSystem() -> SystRes? {
        systems().filter { !$0.spobs.isEmpty }.max { $0.spobs.count < $1.spobs.count }
    }

    /// The stellar objects of a system, decoded, with sprites where available.
    public func stellarObjects(in systemID: Int) -> [(spob: SpobRes, sprite: SpriteSheet?)] {
        guard let system = system(systemID) else { return [] }
        return system.spobs.compactMap { id in
            guard let s = spob(id) else { return nil }
            return (s, spobSprite(id))
        }
    }

    // MARK: Audio

    /// All `snd ` resource ids present in the loaded data, ascending.
    public func soundIDs() -> [Int] { resources.resources(of: NovaType.snd).map(\.id) }

    /// The name of a `snd ` resource, if any (useful for a sound browser).
    public func soundName(_ id: Int) -> String? {
        guard let r = resources.resource(NovaType.snd, id), !r.name.isEmpty else { return nil }
        return r.name
    }

    /// Decode a `snd ` resource into playable PCM. Returns nil if the resource is
    /// missing or uses an encoding we don't support.
    public func sound(_ id: Int) -> NovaSound? {
        guard let r = resources.resource(NovaType.snd, id) else { return nil }
        return try? SndDecoder.decode(r.data)
    }

    // MARK: Prewarming

    /// Eagerly decodes the catalog data + sprites that would otherwise be
    /// parsed lazily on first access (e.g. the first Shipyard/Outfitter visit,
    /// or the first time a hull is seen after a jump), populating the caches
    /// above so gameplay only ever hits warm reads. Intended to run once,
    /// off the main thread, while a loading screen is shown — safe to call
    /// from any thread. `onProgress` is called periodically (not every
    /// iteration) with a human-readable status string.
    public func prewarm(onProgress: (String) -> Void = { _ in }) {
        let allShips = ships()
        onProgress("Decoding \(allShips.count) ship type(s)…")
        for (i, ship) in allShips.enumerated() {
            _ = shipSprite(ship.id)
            _ = engineGlowSprite(ship.id)
            if i % 10 == 0 { onProgress("Decoding ship sprites… \(i)/\(allShips.count)") }
        }
        let allOutfits = outfits()
        onProgress("Decoded \(allOutfits.count) outfit(s).")
        let allGovts = govts()
        onProgress("Decoded \(allGovts.count) government(s).")
    }
}
