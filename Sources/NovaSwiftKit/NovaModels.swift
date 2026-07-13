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

/// A signed 32-bit big-endian field (ResForge's `DLNG` template type).
@inline(__always) private func i32(_ d: Data, _ off: Int) -> Int {
    Int(Int32(bitPattern: u32(d, off)))
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
    /// Running-lights overlay (→ rlëD id), the blinking hull lights layer.
    /// <= 0 means none. Fields @30/@34/@36 (spriteID/width/height).
    public let lightSpriteID: Int
    public let lightWidth: Int
    public let lightHeight: Int
    /// Weapon-glow overlay (→ rlëD id), flashed when the hull fires. <= 0 means
    /// none. Fields @38/@42/@44.
    public let weaponGlowSpriteID: Int
    public let weaponGlowWidth: Int
    public let weaponGlowHeight: Int
    /// Shield-bubble overlay (→ rlëD id), drawn over the hull and flared when
    /// the ship's shields absorb a hit — the layer the "Shields" graphics
    /// plug-in populates (base-game hulls leave it at -1). <= 0 means none.
    /// Fields @64/@68/@70 (spriteID/width/height); mask @66 is unused by us.
    public let shieldSpriteID: Int
    public let shieldWidth: Int
    public let shieldHeight: Int
    /// Number of sprite frames in ONE full rotation (Bible "FramesPer", @52).
    /// Usually 36 (10°/frame); big hulls use more (e.g. 64) for smoother turns.
    /// The base sheet packs `baseSetCount` such sets back-to-back, so frame
    /// `set*framesPerSet + heading` selects a given set's heading.
    public let framesPerSet: Int
    /// The base-image "extra frames" flags (@46). See `ExtraFrames`; the first
    /// four uses (banking/folding/keyCarried/animation) are mutually exclusive.
    public let extraFrameFlags: Int
    /// Frame-advance delay for animated/folding parts, in 1/30 s (Bible AnimDelay, @48).
    public let animDelay: Int
    /// Weapon-glow fade-out rate (Bible WeapDecay, @50); lower = slower decay.
    public let weapDecay: Int
    /// Running-light blink behaviour (@54) and its four parameters (@56–@62).
    /// Meaning of A–D depends on `blinkMode` (Bible BlinkMode 1=square,
    /// 2=triangle, 3=random; 0/-1 = steady-on).
    public let blinkMode: Int
    public let blinkValues: (a: Int, b: Int, c: Int, d: Int)

    /// How the base image's extra sprite sets are used. Decoded from
    /// `extraFrameFlags`; the first matching flag wins (the uses are mutually
    /// exclusive per the Bible, except banking+folding which we treat as banking).
    public enum ExtraFrames {
        case none
        case banking       // set 0 level, 1 = bank left, 2 = bank right
        case folding       // cycled on land/takeoff/hyperspace (deferred → level)
        case keyCarried    // 2nd set shown when not carrying key ships (deferred → level)
        case animation     // extra sets cycled in sequence at animDelay
    }
    public var extraFrames: ExtraFrames {
        if extraFrameFlags & 0x0001 != 0 { return .banking }
        if extraFrameFlags & 0x0002 != 0 { return .folding }
        if extraFrameFlags & 0x0004 != 0 { return .keyCarried }
        if extraFrameFlags & 0x0008 != 0 { return .animation }
        return .none
    }
    /// "Hide running-light sprites while the ship is disabled" (flag 0x0040).
    public var hidesLightsWhenDisabled: Bool { extraFrameFlags & 0x0040 != 0 }
    /// Real weapon mount points, up to 4 per kind (unused slots repeat a
    /// placeholder position — callers should cross-reference `ShipRes.maxGuns`/
    /// `maxTurrets`/weapon count to know how many are actually meaningful).
    public let gunPoints: [ShanExitPoint]
    public let turretPoints: [ShanExitPoint]
    public let guidedPoints: [ShanExitPoint]
    public let beamPoints: [ShanExitPoint]
    /// Perspective foreshortening applied to exit points, as (x%, y%). EV Nova
    /// squishes a ¾-view hull's exit offsets by these factors — `upCompress`
    /// when the hull faces the upper half of the screen, `downCompress` when it
    /// faces the lower half. 100 = no compression (the common case). Fields
    /// @136–142; a stored 0 means "unset" and defaults to 100 (matches
    /// novaparse `ShanResource.ts`).
    public let upCompress: (x: Int, y: Int)
    public let downCompress: (x: Int, y: Int)

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
        lightSpriteID = i16(d, 30)
        lightWidth = i16(d, 34)
        lightHeight = i16(d, 36)
        weaponGlowSpriteID = i16(d, 38)
        weaponGlowWidth = i16(d, 42)
        weaponGlowHeight = i16(d, 44)
        shieldSpriteID = i16(d, 64)
        shieldWidth = i16(d, 68)
        shieldHeight = i16(d, 70)
        let fps = i16(d, 52)
        framesPerSet = fps > 0 ? fps : 36        // guard against 0 → avoids div-by-0 downstream
        extraFrameFlags = i16(d, 46)
        animDelay = i16(d, 48)
        weapDecay = i16(d, 50)
        blinkMode = i16(d, 54)
        blinkValues = (a: i16(d, 56), b: i16(d, 58), c: i16(d, 60), d: i16(d, 62))

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
        // 0 on disk means "unset" → 100% (no compression).
        func comp(_ off: Int) -> Int { let v = i16(d, off); return v == 0 ? 100 : v }
        upCompress = (x: comp(136), y: comp(138))
        downCompress = (x: comp(140), y: comp(142))
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
    /// Purchase price, credits. A 4-byte `DLNG` at @48 — NOT the 2-byte @50 word
    /// it was long mis-decoded as, which silently dropped the high 16 bits and
    /// wrapped every hull over 32,767 cr (e.g. Fed Viper read −31,072 instead of
    /// its true 100,000). Escort hire/daily fees key off this, so the full width
    /// matters. Verified against raw bytes: Shuttle @48 = 0·65536+10000 = 10,000.
    public let cost: Int            // @48 DLNG (4 bytes)
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
    /// `shïp` Flags2 0x0040 — "Ship is inertialess" (Nova Bible): no momentum, the
    /// hull's velocity tracks its heading with no drift. An `oütf` inertial-dampener
    /// (ModType 38) grants the same at runtime.
    public var inertialess: Bool { flags2 & 0x0040 != 0 }
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
    /// "The percent chance that a ship of this type will be available for
    /// hire in the bar on a given day. A HireRandom of 0 means this ship
    /// will never be made available for hire" (Bible). @906, `DWRD`. Same
    /// zero-means-never semantics as `buyRandom`; offset confirmed against a
    /// 284-ship sweep in docs/reverse-engineering/ESCORTS.md §2.2. Restock
    /// gating (day-seeded roll) is implemented for `buyRandom` in
    /// `NovaEconomy.swift`'s `onOfferToday` — a bar-hiring equivalent that
    /// consumes this field is not wired up here.
    public let hireRandom: Int
    /// "Which of the four categories of escorts to put this ship type into
    /// when organizing the escort control menu" (Bible's `EscortType`,
    /// unlabeled `DWRD` in the TMPL). @1842. -1 = Automatic, 0 = Fighter,
    /// 1 = Medium Ship, 2 = Warship, 3 = Freighter.
    public let escortCategory: Int
    /// "ID of the ship class this ship can be upgraded to" (Bible's
    /// `UpgradeTo`). @1832, `RSID`. -1 = not upgradable.
    public let escortUpgradesTo: Int
    /// Credit cost to upgrade this escort to `escortUpgradesTo` (Bible's
    /// `EscUpgrdCost`). @1834, `DLNG`, 4 bytes.
    public let escortUpgradeCost: Int
    /// Credits paid out when this escort is sold/dismissed (Bible's
    /// `EscSellValue`). @1838, `DLNG`, 4 bytes. Empirically 0 for
    /// essentially every stock ship — per the Bible, "≤0 defaults to 10% of
    /// the ship's original Cost," so this raw field alone doesn't capture
    /// the effective sale value; the fallback math belongs to the
    /// behavior-layer (PilotStore) consumer, not this decode.
    public let escortSellValue: Int

    // MARK: Escort hire economics
    //
    // EV Nova charges a flat fee to hire an escort at a bar PLUS a recurring
    // daily fee while you keep it (captured/mission escorts are free). Neither
    // number is a resource field — both are engine-hardcoded and undocumented in
    // the Bible. The one confirmed relationship is that the daily fee is ~10% of
    // the hire price (community-documented). The hire↔Cost ratio is a chosen
    // constant: 10% of Cost, which keeps hiring well below buying (so capturing
    // stays the better play, per the wiki) and matches the lone community data
    // point. See docs/reverse-engineering/ESCORTS.md.

    /// Flat up-front price to hire this hull as an escort — 10% of `cost`.
    public var escortHireFee: Int { max(1, cost / 10) }
    /// Recurring daily upkeep for a **hired** escort of this hull — 10% of the
    /// hire fee (= 1% of `cost`). Captured/mission escorts pay nothing.
    public var escortDailyFee: Int { max(1, cost / 100) }

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
        cost = i32(d, 48)
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
        hireRandom = i16(d, 906)
        escortUpgradesTo = i16(d, 1832)
        escortUpgradeCost = i32(d, 1834)
        escortSellValue = i32(d, 1838)
        escortCategory = i16(d, 1842)

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

/// A galaxy-map nebula (`nëbu`) — a coloured background region on the star map.
///
/// Layout reverse-engineered from the base data (Nova Data 5, ids 128–131):
/// the resource is 534 bytes but only the first four big-endian `int16`s carry
/// data — `x`, `y`, `width`, `height` — a top-left-anchored box in the **same
/// coordinate space as `sÿst`** (verified: the Holpa Nebula box (430,45)+251×298
/// contains the Holpa system at (486,120) and its neighbours). The graphic isn't
/// referenced in the resource; by convention each nebula owns a 7-id `PICT`
/// block at `9500 + 7·index` holding its zoom levels (¼/½/1×), the largest being
/// `9502 + 7·index` — see `NovaGame.nebulaImageID`.
public struct NebuRes {
    public let id: Int
    public let name: String
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(_ r: Resource) {
        id = r.id
        name = r.name
        let d = r.data
        x = i16(d, 0)
        y = i16(d, 2)
        width = i16(d, 4)
        height = i16(d, 6)
    }
}

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
    /// `Message` (@104): index into `STR#` 1000 of the message-buoy text shown to
    /// the player on entering this system; -1 = no buoy. Verified against real
    /// data (Kania -1, Tichel 1, …).
    public let message: Int
    /// `Person1-8` (@110, 8×int16): përs ids that are *guaranteed* to appear in
    /// this system (designers pin story/bounty characters to fixed locations).
    /// Filtered to valid ids (>=128). Verified: Sol pins #128/#227/#156/#299
    /// (Terrapin, Valkyrie, Drifting Derelict, Galadriel).
    public let pinnedPersons: [Int]
    /// `sÿst.Interference` (Bible): "How thick the static in the system should
    /// be. 0 is no static, 100 is complete sensor blackout." Degrades radar /
    /// sensor range (see `World` detection). @108, confirmed against real data
    /// (0-100, sits right after Asteroids@106).
    public let interference: Int
    /// `sÿst.Murk` (Bible): "The murkiness of the system (0-100). Zero will
    /// cause everything to appear normally — 100 will cause the player to
    /// question their current glasses prescription. A value less than zero is
    /// equivalent to zero murk but also hides the starfield." A visual fog
    /// depth for the renderer. @146, confirmed against real data (sits right
    /// before AstTypes@148).
    public let murk: Int
    /// Which `röid` type ids (128-143) are enabled for this system, per the
    /// `AstTypes` bitmask.
    public let asteroidTypeIDs: [Int]
    /// Reactive reinforcement fleet: `flët` id to summon as backup when
    /// allies are outmatched (Bible's `ReinfFleet`). @406, `RSID`. -1 = none.
    /// Distinct from `spawns`/`fleetSpawns` (ambient background traffic) —
    /// see docs/reverse-engineering/FLEETS.md §5. No reactive summon
    /// mechanism consumes this yet; only `gövt.MaxOdds`-driven pre-fight
    /// gating exists today (`AIBrain.favorableOdds`).
    public let reinforcementFleet: Int
    /// Delay, in frames, before `reinforcementFleet` arrives after being
    /// triggered (Bible's `ReinfTime`). @408, `DWRD`.
    public let reinforcementDelay: Int
    /// Minimum interval, in days, between `reinforcementFleet` regenerations
    /// (Bible's `ReinfIntrval`). @410, `DWRD`.
    public let reinforcementRegen: Int
    /// `sÿst.Visibility` (@150, 256-byte NCB **test** expression): when it
    /// evaluates false against the player's control bits, the whole system is
    /// hidden from the map and can't be entered — EV Nova's mechanism for making
    /// systems appear/disappear mid-game (new territory opening up, or replacing
    /// a system with an identical-coordinate copy for a "the system changed"
    /// illusion; Bible §sÿst "Visibility"). Empty = always visible. Offset
    /// cross-validated: every surrounding `sÿst` field the decoder already reads
    /// (`links@4`, `spobs@36`, `spawns@68`, `murk@146`, `reinfFleet@406`…) lands
    /// exactly where computed from the ResForge `sÿst` TMPL (#521) field order.
    public let visibility: String

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
        message = i16(d, 104)
        asteroidCount = max(0, min(16, i16(d, 106)))
        interference = i16(d, 108)
        pinnedPersons = (0..<8).map { i16(d, 110 + $0 * 2) }.filter { $0 >= 128 }
        murk = i16(d, 146)
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
        reinforcementFleet = i16(d, 406)
        reinforcementDelay = i16(d, 408)
        reinforcementRegen = i16(d, 410)
        visibility = cstr(d, 150, 256)
    }
}

// MARK: röid — asteroid type (strength, yield, fragmentation)

/// One of the 16 asteroid types (`röid` #128-143). Fields verified byte-for-byte
/// against the real TMPL (#516, `novaswift-extract tmpl … 516`) and the Nova Bible's
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
    /// `Flags2` (`spöb` second flag longword, @30 — verified empirically against
    /// the base data: all 23 named "Wormhole" spöbs carry `0x2000`, all 35 "HG-*"
    /// hypergates carry `0x1000`). Bits: `0x1000` hypergate, `0x2000` wormhole,
    /// `0x0100` deadly, `0x0400` buys any outfit, `0x0020` always dominated, …
    public let flags2: UInt32
    /// `HyperLink1-8` (@38, eight `int16`s): the `spöb` ids of the other
    /// hypergates/wormholes this gate connects to (−1/0 = unused; a wormhole
    /// with all −1 connects randomly). Empty for a non-gate stellar.
    public let hyperLinks: [Int]

    // MARK: Domination / Demand Tribute (Nova Bible; offsets verified against
    // TMPL #520 + real data — see docs/reverse-engineering/DOMINATION.md).

    /// `Tribute` (@10, `int16`): what a *dominated* stellar pays the player, in
    /// credits **per day** (auto-added by the day clock, not collected on
    /// landing). `-1`/`0` = the default payout, `1000 × TechLevel` (see
    /// `dailyTributeAmount`); `≥1` = exactly that many credits/day.
    public let tribute: Int
    /// `DefenseDude` (@28, `RSID`): the `düde` class this stellar launches to
    /// defend itself when the player demands tribute. `< 128` = no defense fleet
    /// (the stellar can't be forced into submission by combat).
    public let defenseDude: Int
    /// `DefCount` (@30) raw value. EV Nova decimal-packs this: a value `> 1000`
    /// launches defenders in *waves* — the last digit is the ships-per-wave, and
    /// the leading digits with 1 subtracted from the first digit are the total
    /// fleet size (Bible: `1082` → 4 waves of 2 = 8 total; `2005` → waves of 5,
    /// 100 total). Verified: Earth `7006` → 600 total, 6/wave. Decoded into
    /// `defenseTotal`/`defenseWaveSize` below.
    public let defenseCountRaw: Int

    /// `OnDominate` (@54, 255-byte NCB set expression): control bits set when the
    /// player successfully dominates this stellar. Empty = none.
    public let onDominate: String
    /// `OnRelease` (@309, 255-byte NCB set expression): control bits set when the
    /// stellar is released from the player's domination. Empty = none.
    public let onRelease: String
    /// `OnDestroy` (@582, 255-byte NCB set expression): control bits set when the
    /// stellar is destroyed (by weapon fire or a mission `Y` op). Empty = none.
    /// Offset cross-validated: every surrounding `spöb` field the existing
    /// decoder reads (`hyperLinks@38`, `graphic@4`, `minStatus@22`…) lands
    /// exactly where computed from the ResForge `spöb` TMPL (#520) field order.
    public let onDestroy: String
    /// `OnRegen` (@837, 255-byte NCB set expression): control bits set when the
    /// stellar regenerates after being destroyed (a mission `U` op). Empty = none.
    public let onRegen: String
    /// `DestroyedGraphic` (@576, `int16`): the graphic shown once this stellar is
    /// destroyed — a wreck / debris field. `-1` (or ≤0) = invulnerable / no wreck
    /// art. Same 0–63 → `spïn` mapping as `graphicSpinID`. Offset from the same
    /// verified `spöb` TMPL chain that puts `OnDestroy`@582 (576 + DeadType 2 +
    /// RegenTime 2 + Explosion 2 = 582).
    public let destroyedGraphicRaw: Int
    /// The `spïn` id of the destroyed/wreck graphic, or nil when the stellar has
    /// none (`-1`/≤0 → invulnerable, shown as simply *gone* when destroyed).
    public var destroyedGraphicSpinID: Int? {
        guard destroyedGraphicRaw > 0 else { return nil }
        var g = destroyedGraphicRaw + 2000
        if g > 2058 { g -= 1 }
        return g
    }
    /// `spöb.Flags` 0x0080 — the stellar can *only* be landed on once destroyed
    /// (a hidden base revealed when its cover is blown). Hidden/unlandable until
    /// then; visible + landable after.
    public var landableOnlyWhenDestroyed: Bool { flags & 0x0080 != 0 }

    /// Total number of ships in this stellar's defense fleet (decoded from
    /// `defenseCountRaw`). 0 = no defenders.
    public var defenseTotal: Int {
        guard defenseCountRaw > 0 else { return 0 }
        guard defenseCountRaw > 1000 else { return defenseCountRaw }  // small count = launched at once
        // Waves: last digit = wave size; leading digits minus 1 from the first
        // digit = total. e.g. 7006 → lead 700, first digit 7→6 → 600.
        let lead = defenseCountRaw / 10
        let places = Int(pow(10.0, Double(String(lead).count - 1)))
        return lead - places
    }
    /// Ships launched per defense wave (decoded from `defenseCountRaw`). For a
    /// small (`≤1000`) count the whole fleet launches at once, so the wave size
    /// equals the total.
    public var defenseWaveSize: Int {
        guard defenseCountRaw > 1000 else { return max(1, defenseTotal) }
        return max(1, defenseCountRaw % 10)
    }
    /// This stellar fields a defense fleet, so it can be forced to submit by
    /// destroying its defenders (the Demand-Tribute flow).
    public var hasDefenseFleet: Bool { defenseDude >= 128 && defenseTotal > 0 }
    /// `Flags2 0x0020`: the stellar begins the game already dominated by the
    /// player ("all your base are belong to us").
    public var startsDominated: Bool { flags2 & 0x0020 != 0 }
    /// The tribute this stellar pays per day once dominated, resolving the
    /// `-1`/`0` "default" sentinel to the Bible's `1000 × TechLevel`.
    public var dailyTributeAmount: Int { tribute >= 1 ? tribute : max(0, 1000 * techLevel) }

    /// `MinStatus` (@22, `int16`): the point on your legal record with this
    /// stellar's `government` at or below which you're denied landing clearance
    /// (Nova Bible): `-32767` = always land, `-1…-32766` = "you can be this evil
    /// before we shun you", `0…32766` = "we have to like you this much", `32767`
    /// = never land. Ignored by the base game when the stellar is uninhabited —
    /// but the stock hypergates (govt #183 "Hypergate") all carry `32767`, so
    /// gate access is deliberately a *clearance* mechanic, not a standing one
    /// (see `playerMayUseGate`).
    public let minStatus: Int

    /// For a gate, the fixed angle (degrees, `0..<360`) at which ships emerge
    /// from it — the Bible repurposes `CustSndID` (@26) for this on hypergates
    /// and wormholes. `nil` = emerge in a random direction (any out-of-range
    /// value), or a non-gate stellar. HG-V01 (#1400) carries `120`.
    public let gateEmergeAngle: Double?

    /// This stellar is a hypergate (lands → pick a connected hypergate).
    public var isHypergate: Bool { flags2 & 0x1000 != 0 }
    /// This stellar is a wormhole (lands → transported to a linked wormhole).
    public var isWormhole: Bool { flags2 & 0x2000 != 0 }
    public var isGate: Bool { isHypergate || isWormhole }

    /// Gates are always something the player can fly to and set down on, even
    /// when the stock data flags them a "station"/uninhabited (HG-V01 is flagged
    /// a station) — landing on one is how you *use* it. Non-gates fall back to
    /// the normal landable test.
    public var isLandableStellar: Bool { isGate || isLandable }

    /// Whether the player may pass through this gate given their relationship to
    /// its owning `government`. Wormholes are open to everyone (no requirements).
    /// Hypergates require landing *clearance* from the owner: independent gates
    /// are open; a hostile owner always refuses; a "restricted network" gate
    /// (`minStatus == 32767`, the stock case) needs the player allied-with or in
    /// positive standing with the owner; otherwise the ordinary `MinStatus`
    /// threshold applies. Pure — the caller supplies the relationship, so this
    /// stays in NovaSwiftKit with no dependency on the engine's `Diplomacy`.
    public func playerMayUseGate(standing: Int, hostile: Bool, allied: Bool) -> Bool {
        if isWormhole { return true }
        guard isHypergate else { return false }
        if government < 128 { return true }        // independent gate: open to all
        if hostile { return false }                // enemies never get clearance
        if minStatus >= 32767 { return allied || standing > 0 }
        if minStatus <= -32767 { return true }
        return standing >= minStatus
    }

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
        minStatus = i16(d, 22)
        let flags2v = u32(d, 30)
        flags2 = flags2v
        // @26 (CustSndID) is an ambient-sound id on ordinary stellars but the
        // ships-emerge angle on gates (Bible) — so a gate has no ambient sound,
        // and its @26 becomes the emerge angle (nil = random / out-of-range).
        let rawCust = i16(d, 26)
        let isGateStellar = flags2v & 0x3000 != 0
        ambientSoundID = (isGateStellar || rawCust == -1) ? nil : rawCust
        gateEmergeAngle = (isGateStellar && (0...359).contains(rawCust)) ? Double(rawCust) : nil
        hyperLinks = (0..<8).map { i16(d, 38 + $0 * 2) }.filter { $0 >= 128 }
        tribute = i16(d, 10)
        defenseDude = i16(d, 28)
        defenseCountRaw = i16(d, 30)
        onDominate = cstr(d, 54, 255)
        onRelease = cstr(d, 309, 255)
        onDestroy = cstr(d, 582, 255)
        onRegen = cstr(d, 837, 255)
        destroyedGraphicRaw = i16(d, 576)
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
    /// Decoded sprite sheets keyed by the `rlëD` resource id they were decoded
    /// from — so art shared by several ships/planets/weapons decodes at most once,
    /// and hulls, engine glows, shields, planets, wrecks, shots and asteroids all
    /// draw from one pool. A `nil` value is a negative cache (known missing or
    /// undecodable), so a bad id is only ever chased down once.
    var rleSheets: [Int: SpriteSheet?] = [:]
    /// `spöb` id → the id of the system that lists it in its `spobs`. Built once
    /// (walking every system) so gate transport can resolve a linked gate's
    /// destination system without re-scanning the galaxy each time.
    var spobSystemIndex: [Int: Int]?
    /// Cross-launch cache of decoded sheets on disk; nil when no writable cache
    /// location exists. Set once at `NovaGame` init.
    var diskCache: SpriteDiskCache?
}

/// Typed, indexed view of a merged `ResourceCollection`. Decodes resource bodies
/// on demand and resolves cross-references (e.g. a ship → its sprite).
public struct NovaGame {
    public let resources: ResourceCollection
    private let cache = NovaGameCache()
    public init(_ resources: ResourceCollection, spriteCache: SpriteDiskCache? = nil) {
        self.resources = resources
        cache.diskCache = spriteCache
    }

    /// Decode the sprite sheet in `rlëD` resource `rleID`, memoised in RAM and —
    /// when a disk cache is attached — persisted across launches so the RLE
    /// decode is paid at most once, ever. The decode runs **outside** the cache
    /// lock: it's the one genuinely expensive step, and holding the mutex across
    /// it would serialise concurrent prewarm threads (and any scene build racing
    /// prewarm) into single-file. The small window where two threads decode the
    /// same id is harmless — the result is pure and identical.
    private func decodedRLE(_ rleID: Int) -> SpriteSheet? {
        cache.lock.lock()
        if let hit = cache.rleSheets[rleID] { cache.lock.unlock(); return hit }
        let disk = cache.diskCache
        cache.lock.unlock()

        var sheet: SpriteSheet?
        if let cached = disk?.load(rleID) {
            sheet = cached
        } else if let data = resources.resource(NovaType.rleD, rleID)?.data {
            sheet = try? RLED.decode(data)
            if let sheet { disk?.store(rleID, sheet) }
        }

        cache.lock.lock()
        cache.rleSheets[rleID] = .some(sheet)
        cache.lock.unlock()
        return sheet
    }

    /// Release every decoded sprite sheet held in RAM (hulls, engine glows,
    /// shields, planets, wrecks, shots, asteroids). The pool grows with the
    /// unique art seen over a session and is the single largest RAM consumer —
    /// full decoded RGBA surfaces — so this is the lever for memory-pressure
    /// response. Cheap to undo: each sheet re-decodes on next access, and when a
    /// disk cache is attached that's a fast mmap + decompress rather than a fresh
    /// RLE decode. Returns the number of entries released (for logging).
    @discardableResult
    public func flushSpriteSheets() -> Int {
        cache.lock.lock(); defer { cache.lock.unlock() }
        let released = cache.rleSheets.count
        cache.rleSheets.removeAll(keepingCapacity: false)
        return released
    }

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
    public func nebulae() -> [NebuRes] { resources.resources(of: NovaType.nebula).map(NebuRes.init) }
    /// Highest-resolution `PICT` id for the nebula at `index` (id − 128): the
    /// last of its 7-id block. Callers fall back to `-1`/`-2` if it's absent.
    public func nebulaImageID(index: Int) -> Int { 9502 + 7 * index }
    public func spob(_ id: Int) -> SpobRes? { resources.resource(NovaType.spob, id).map(SpobRes.init) }
    public func spobs() -> [SpobRes] { resources.resources(of: NovaType.spob).map(SpobRes.init) }

    /// The id of the system that contains `spobID`, or nil if no system lists it.
    /// Backed by a one-time index over every system's `spobs` (see `spobSystemIndex`).
    public func systemContaining(spob spobID: Int) -> Int? {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if cache.spobSystemIndex == nil {
            var idx: [Int: Int] = [:]
            for sys in resources.resources(of: NovaType.syst).map(SystRes.init) {
                for sp in sys.spobs where idx[sp] == nil { idx[sp] = sys.id }
            }
            cache.spobSystemIndex = idx
        }
        return cache.spobSystemIndex?[spobID]
    }

    /// The destinations a hypergate offers: for each valid `HyperLink` gate, the
    /// linked gate's `spöb` and the system that holds it. Skips links that don't
    /// resolve to a real gate in a real system (bad/self data), deduped by
    /// destination system so the galaxy map draws one line per reachable system.
    public func gateDestinations(from gate: SpobRes) -> [(gateSpobID: Int, systemID: Int)] {
        var seenSystems = Set<Int>()
        var out: [(Int, Int)] = []
        for linkID in gate.hyperLinks {
            guard linkID != gate.id, let linked = spob(linkID), linked.isGate,
                  let sysID = systemContaining(spob: linkID), seenSystems.insert(sysID).inserted
            else { continue }
            out.append((linkID, sysID))
        }
        return out
    }

    /// Where a wormhole can spit the player out. If it has `HyperLink`s, those are
    /// its exits (same as a hypergate). If it has none, the Bible says it connects
    /// to another *link-less* wormhole picked at random — so the candidates are
    /// every other link-less wormhole in the galaxy (falling back to any other
    /// wormhole if none are link-less). Each candidate carries its own system.
    public func wormholeExitCandidates(from wormhole: SpobRes) -> [(gateSpobID: Int, systemID: Int)] {
        if !wormhole.hyperLinks.isEmpty { return gateDestinations(from: wormhole) }
        func collect(_ predicate: (SpobRes) -> Bool) -> [(Int, Int)] {
            var out: [(Int, Int)] = []
            for s in spobs() where s.id != wormhole.id && s.isWormhole && predicate(s) {
                if let sys = systemContaining(spob: s.id) { out.append((s.id, sys)) }
            }
            return out
        }
        let linkless = collect { $0.hyperLinks.isEmpty }
        return linkless.isEmpty ? collect { _ in true } : linkless
    }

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
    public func rank(_ id: Int) -> RankRes? { resources.resource(NovaType.rank, id).map(RankRes.init) }
    public func ranks() -> [RankRes] { resources.resources(of: NovaType.rank).map(RankRes.init) }
    public func roid(_ id: Int) -> RoidRes? { resources.resource(NovaType.roid, id).map(RoidRes.init) }
    public func roids() -> [RoidRes] { resources.resources(of: NovaType.roid).map(RoidRes.init) }
    public func desc(_ id: Int) -> DescRes? { resources.resource(NovaType.desc, id).map(DescRes.init) }
    public func stringList(_ id: Int) -> StringListRes? { resources.resource(NovaType.strList, id).map(StringListRes.init) }
    /// The narrative text of a `dësc` resource, or "" if absent.
    ///
    /// `dësc` bodies are mutable: they can embed `{bXXX …}` / `{G …}` / `{P …}`
    /// conditionals that Nova resolves as it draws them. Every caller wants the
    /// resolved text, so resolve here rather than at each display site — passing
    /// the player's control bits and gender through `context` when they're known.
    public func descText(_ id: Int, context: NovaTextContext = .init()) -> String {
        guard let raw = desc(id)?.text else { return "" }
        return NovaDescFormatter.render(raw, context: context)
    }

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
        guard let shan = shan(shipID) else { return nil }
        // Hulls reference the `rlëD` directly (spïn indirection is for
        // planets/weapons/asteroids); fall back through spïn only if the data
        // numbers it that way — matching `shipSpriteData`'s resolution order.
        if resources.resource(NovaType.rleD, shan.baseSpriteID) != nil {
            return decodedRLE(shan.baseSpriteID)
        }
        if let spin = spin(shan.baseSpriteID), resources.resource(NovaType.rleD, spin.spriteID) != nil {
            return decodedRLE(spin.spriteID)
        }
        return nil
    }

    /// Decode a ship's real, per-hull-authored engine-glow overlay sprite (the
    /// `shän` engine layer), if this hull has one. Same rotation-frame layout
    /// as the base hull sprite — index it with the same `spriteFrame`. Cached
    /// for the same reason as `shipSprite`.
    public func engineGlowSprite(_ shipID: Int) -> SpriteSheet? {
        guard let shan = shan(shipID), shan.engineSpriteID > 0,
              resources.resource(NovaType.rleD, shan.engineSpriteID) != nil else { return nil }
        return decodedRLE(shan.engineSpriteID)
    }

    /// Decode a ship's shield-bubble overlay sprite (the `shän` shield layer),
    /// if this hull defines one. Base-game hulls leave `shieldSpriteID` at -1,
    /// so this is nil for stock data; the "Shields" graphics plug-in populates
    /// it for every hull. Unlike the hull/engine sheets this is an independent
    /// animation (its own frame count) — drive it with its own flare clock,
    /// not the hull's `spriteFrame`. Cached like the other layers.
    public func shieldSprite(_ shipID: Int) -> SpriteSheet? {
        guard let shan = shan(shipID), shan.shieldSpriteID > 0,
              resources.resource(NovaType.rleD, shan.shieldSpriteID) != nil else { return nil }
        return decodedRLE(shan.shieldSpriteID)
    }

    /// Decode a ship's running-lights overlay sprite (the `shän` light layer), if
    /// present. Shares the base hull's frame layout (same set/heading count,
    /// including banking sets, per the Bible), so index it with the same
    /// `set*framesPerSet + heading`. Its opacity is then driven by the shän's
    /// blink mode. <= 0 / missing → nil.
    public func lightSprite(_ shipID: Int) -> SpriteSheet? {
        guard let shan = shan(shipID), shan.lightSpriteID > 0,
              resources.resource(NovaType.rleD, shan.lightSpriteID) != nil else { return nil }
        return decodedRLE(shan.lightSpriteID)
    }

    /// Decode a ship's weapon-glow overlay sprite (the `shän` weapon layer), if
    /// present — the muzzle flash flashed on firing and faded per `weapDecay`.
    /// Shares the base frame layout like the engine/light layers. <= 0 → nil.
    public func weaponGlowSprite(_ shipID: Int) -> SpriteSheet? {
        guard let shan = shan(shipID), shan.weaponGlowSpriteID > 0,
              resources.resource(NovaType.rleD, shan.weaponGlowSpriteID) != nil else { return nil }
        return decodedRLE(shan.weaponGlowSpriteID)
    }

    // MARK: Stellar objects

    /// Resolve a stellar object's sprite: spöb.graphic → spïn → rlëD.
    /// (Some stellars use PICT, which isn't decoded yet — those return nil.)
    public func spobSprite(_ spobID: Int) -> SpriteSheet? {
        guard let spob = spob(spobID) else { return nil }
        if let spin = spin(spob.graphicSpinID),
           resources.resource(NovaType.rleD, spin.spriteID) != nil {
            return decodedRLE(spin.spriteID)
        }
        if resources.resource(NovaType.rleD, spob.graphicSpinID) != nil {
            return decodedRLE(spob.graphicSpinID)
        }
        return nil
    }

    /// Resolve a stellar's **destroyed** (wreck) sprite: `spöb.DestroyedGraphic`
    /// → `spïn` → `rlëD`. nil when the stellar is invulnerable / has no wreck art
    /// (the renderer then just drops it from the system when destroyed).
    public func spobDestroyedSprite(_ spobID: Int) -> SpriteSheet? {
        guard let spob = spob(spobID), let spinID = spob.destroyedGraphicSpinID else { return nil }
        if let spin = spin(spinID), resources.resource(NovaType.rleD, spin.spriteID) != nil {
            return decodedRLE(spin.spriteID)
        }
        if resources.resource(NovaType.rleD, spinID) != nil {
            return decodedRLE(spinID)
        }
        return nil
    }

    /// Resolve a weapon's shot graphic (`wëap.graphicSpinID` → `spïn` → `rlëD`)
    /// into a sprite sheet — the real torpedo/rocket/bolt animation, so shots
    /// draw their authored art instead of a generic dot. Decoded once and shared
    /// through the common sheet cache (the renderer also caches the built
    /// textures per graphic id).
    public func weaponSprite(spinID: Int) -> SpriteSheet? {
        if let spin = spin(spinID), resources.resource(NovaType.rleD, spin.spriteID) != nil {
            return decodedRLE(spin.spriteID)
        }
        if resources.resource(NovaType.rleD, spinID) != nil {
            return decodedRLE(spinID)
        }
        return nil
    }

    /// Resolve an asteroid type's rotating rock sprite: `röid` id → `spïn`
    /// (fixed offset `röidID + 672`, the Bible's reserved 800-815 asteroid
    /// spïn range) → `rlëD`. Cached like `shipSprite`/`engineGlowSprite`.
    public func asteroidSprite(_ roidID: Int) -> SpriteSheet? {
        let spinID = roidID + 672
        guard let spin = spin(spinID),
              resources.resource(NovaType.rleD, spin.spriteID) != nil else { return nil }
        return decodedRLE(spin.spriteID)
    }

    /// The real background star sprite (`spïn` #700 "Stars" → `rlëD`), a small
    /// multi-frame tile Nova scatters across the parallax starfield. Cached
    /// once — there is only ever one.
    public func starfieldSprite() -> SpriteSheet? {
        guard let spin = spin(700),
              resources.resource(NovaType.rleD, spin.spriteID) != nil else { return nil }
        return decodedRLE(spin.spriteID)
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
    /// from any thread. `onProgress` is called in order, periodically (not
    /// every iteration), and always ends at `completed == total`.
    public func prewarm(onProgress: @Sendable (PrewarmProgress) -> Void = { _ in }) {
        let allShips = ships()
        // Ship sprites dominate (two decodes per hull); outfits and governments
        // are one bulk decode apiece. Counting all three against a single total
        // is what lets `fraction` rise monotonically across the whole run
        // instead of restarting per phase.
        let total = allShips.count + 2

        onProgress(PrewarmProgress(phase: "Decoding ship sprites", completed: 0, total: total))

        // Hull + engine-glow decodes are independent and CPU-bound — exactly what
        // `concurrentPerform` is for. The decode runs off the cache lock (see
        // `decodedRLE`), so this scales across cores instead of queueing on a
        // mutex. A tiny lock guards only the shared progress counter.
        //
        // We deliberately do NOT prewarm planet/weapon/asteroid art here: that's
        // galaxy-wide and would balloon resident memory on mobile (see the OOM
        // notes). Those stay lazy — decoded once on first sight, then served warm
        // from RAM and, across launches, from the disk cache.
        if !allShips.isEmpty {
            let progressLock = NSLock()
            var completed = 0
            DispatchQueue.concurrentPerform(iterations: allShips.count) { i in
                let id = allShips[i].id
                _ = shipSprite(id)
                _ = engineGlowSprite(id)
                progressLock.lock()
                completed += 1
                let done = completed
                progressLock.unlock()
                // Report every 8 hulls (and on the last) — enough to keep the bar
                // moving without flooding the main actor with hops.
                if done % 8 == 0 || done == allShips.count {
                    onProgress(PrewarmProgress(phase: "Decoding ship sprites", completed: done, total: total))
                }
            }
        }

        onProgress(PrewarmProgress(phase: "Decoding outfits", completed: allShips.count, total: total))
        _ = outfits()
        onProgress(PrewarmProgress(phase: "Decoding governments", completed: allShips.count + 1, total: total))
        _ = govts()
        onProgress(PrewarmProgress(phase: "Ready", completed: total, total: total))
    }
}

/// One ordered progress report from `NovaGame.prewarm`. `completed`/`total`
/// span the entire prewarm, not the current `phase`, so a progress bar driven
/// by `fraction` never jumps backwards when the phase changes.
public struct PrewarmProgress: Sendable, Equatable {
    /// What's being decoded right now, e.g. "Decoding ship sprites".
    public let phase: String
    public let completed: Int
    public let total: Int

    public init(phase: String, completed: Int, total: Int) {
        self.phase = phase
        self.completed = completed
        self.total = total
    }

    public var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }
}
