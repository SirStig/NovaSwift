import Foundation

// Typed decoders for the resources that drive EV Nova's NPC AI: governments
// (`gövt`), dudes (`düde`, an AI ship archetype), fleets (`flët`), and weapons
// (`wëap`). Field offsets are the on-disk big-endian byte layout, taken from the
// EV Nova / ResForge `TMPL` templates and **verified against the real game data**
// (e.g. `gövt` 128 "Federation": Comms Name at @52; `düde` 128 ship-probabilities
// sum to exactly 100). See docs/DATA_FORMAT.md and docs/AI.md.

// MARK: Byte helpers (big-endian, bounds-safe)

@inline(__always) private func ai16(_ d: Data, _ off: Int) -> Int {
    guard off >= 0, off + 2 <= d.count else { return 0 }
    let base = d.startIndex + off
    let v = (Int(d[base]) << 8) | Int(d[base + 1])
    return v >= 0x8000 ? v - 0x10000 : v
}

@inline(__always) private func au16(_ d: Data, _ off: Int) -> UInt16 {
    guard off >= 0, off + 2 <= d.count else { return 0 }
    let base = d.startIndex + off
    return UInt16(d[base]) << 8 | UInt16(d[base + 1])
}

@inline(__always) private func ai32(_ d: Data, _ off: Int) -> Int {
    guard off >= 0, off + 4 <= d.count else { return 0 }
    let b = d.startIndex + off
    let v = (UInt32(d[b]) << 24) | (UInt32(d[b + 1]) << 16) | (UInt32(d[b + 2]) << 8) | UInt32(d[b + 3])
    return Int(Int32(bitPattern: v))
}

/// A single 64-bit big-endian flag field (EV Nova's `Contribute`/`Require`
/// pairs — ResForge's `QB64` template type reads them as one 8-byte value,
/// not two independent Int32s).
@inline(__always) private func au64(_ d: Data, _ off: Int) -> UInt64 {
    guard off >= 0, off + 8 <= d.count else { return 0 }
    let b = d.startIndex + off
    var v: UInt64 = 0
    for i in 0..<8 { v = (v << 8) | UInt64(d[b + i]) }
    return v
}

/// A 4-byte `LCOL` color field (`0x00RRGGBB` — first byte padding), same
/// on-disk shape as `IntfRes`'s color fields in `InterfaceModels.swift`.
@inline(__always) private func acolor(_ d: Data, _ off: Int) -> NovaColor {
    guard off >= 0, off + 4 <= d.count else { return NovaColor(r: 0, g: 0, b: 0) }
    let b = d.startIndex + off
    return NovaColor(r: d[b + 1], g: d[b + 2], b: d[b + 3])
}

/// Read a NUL-terminated Mac Roman C-string from a fixed-size field at `off`,
/// reading at most `maxLen` bytes. Trailing garbage after the NUL is ignored.
@inline(__always) private func acstr(_ d: Data, _ off: Int, _ maxLen: Int) -> String {
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

/// Resolve a `wëap`/`shïp` "explosion" field to a `bööm` resource id: raw `-1` =
/// none; raw `≥1000` is the "explosion + sparks" variant (bööm id = raw − 1000 +
/// base); otherwise bööm id = raw + base. `base` is 128 for both fields.
@inline(__always) func boomID(raw: Int, base: Int = 128) -> Int? {
    guard raw != -1 else { return nil }
    return raw >= 1000 ? raw - 1000 + base : raw + base
}

// MARK: oütf — outfit (equipment sold at outfitters; modifies the ship)

/// What an outfit *does* to the ship it's installed on. These are EV Nova's
/// "ModType" function codes (the number stored in each of an outfit's four
/// modifier slots), from novaparse `OutfResource.ts`. Most carry a signed value;
/// the boolean-style ones ignore it. `NovaSwiftEngine` aggregates these into a
/// ship's effective stats.
public enum OutfitModType: Int, Sendable {
    case none = 0
    case weapon = 1            // grants weapon (value = wëap id)
    case freeCargo = 2         // +cargo capacity (tons)
    case ammunition = 3        // +ammo for a weapon (value = wëap id)
    case shield = 4            // +max shield
    case shieldRecharge = 5    // +shield regen
    case armor = 6             // +max armor
    case acceleration = 7      // +acceleration
    case speed = 8             // +max speed
    case turnRate = 9          // +turn rate
    case escapePod = 11
    case fuelCapacity = 12     // +fuel capacity (novaparse "energy")
    case densityScanner = 13
    case iff = 14
    case afterburner = 15      // afterburner fuel cost (value = fuel/frame ×?)
    case map = 16
    case cloak = 17
    case fuelRegen = 18        // +fuel regen (novaparse "energyRecharge")
    case autoRefuel = 19
    case autoEject = 20
    case cleanRecord = 21
    case hyperspaceSpeed = 22
    case hyperspaceDist = 23
    case interference = 24
    case marines = 25
    case increaseMax = 27
    case murk = 28
    case armorRecharge = 29
    case cloakScanner = 30
    case miningScoop = 31
    case multiJump = 32
    case jam1 = 33, jam2 = 34, jam3 = 35, jam4 = 36
    case fastJump = 37
    case inertialDamper = 38
    case deionize = 39
    case ionCapacity = 40
    case gravityResist = 41
    case stellarResist = 42
    case paint = 43
    case reinforcementInhibitor = 44
    case maxGuns = 45
    case maxTurrets = 46
    case bomb = 47
    case iffScrambler = 48
    case repairSystem = 49
    case nonlethalBomb = 50
    case unknown = 1000

    public init(raw: Int) { self = OutfitModType(rawValue: raw) ?? .unknown }
}

/// An outfit: what it weighs, costs, and the up-to-four modifiers it applies to a
/// ship. Offsets verified against novaparse `OutfResource.ts`.
public struct OutfRes {
    public let id: Int
    public let name: String
    public let displayWeight: Int   // @0  sort order in the outfitter
    public let mass: Int            // @2  tons of free mass this consumes
    public let techLevel: Int       // @4
    public let maxInstallable: Int  // @10 max the player may own (0 = unlimited)
    public let cost: Int            // @14 credits (int32)
    /// The outfit's modifier slots: (function, value). Slots that are empty
    /// (`.none`/`.unknown`) are stripped.
    public let modifiers: [(type: OutfitModType, value: Int)]

    // Mission/story-gated availability (Nova Bible; offsets verified against
    // ResForge's `oütf` TMPL — see docs/DATA_FORMAT.md). Distinct from
    // `techLevel`, which fully hides an item; these instead default to
    // "shown, greyed, unpurchasable" (see `Flags` 0x0100/0x4000 below).
    public let flags: UInt16        // @12  0x0008 can't-sell · 0x0100/0x4000 hide-rules · 0x0800 sell-anywhere-ignore-reqs
    public let contribute: UInt64   // @30  bits this outfit contributes toward other items' Require
    public let require: UInt64      // @38  bits that must be met (via ship/outfit Contribute) to buy this
    public let availBits: String    // @46  NCB control-bit test expression gating purchase
    /// Which governments' stellars `require`'s bits apply at: -1 = everywhere;
    /// see the Bible's `RequireGovt` range encoding (128-383 this govt/allies
    /// only, 1128-1383 + independent, 2128-2383 all-but, 3128-3383 all-but +
    /// independent). @1010.
    public let requireGovt: Int
    /// "The percent chance that an item of this type will be available for
    /// purchase on a given day, from 1-100. Values less than 1 or greater
    /// than 100 are interpreted as 100" (Bible). @1008. This is the same
    /// on-disk field the Bible calls `BuyRandom` on both `oütf` and `shïp`;
    /// `requireBitsApplyTo` below is likewise the Bible's `RequireGovt`
    /// already decoded here as `requireGovt` — see OUTFITTERS.md §8.
    public let buyRandom: Int
    /// "The item's classification, used in the pêrs resource for items that
    /// are given out by non-player characters' ships" (Bible `ItemClass`).
    /// @1004. Confirmed via OUTFITTERS.md §8 against real `oütf` TMPL +
    /// raw data (offset `contribute@30`..`unused@1012` all re-derived and
    /// cross-checked there).
    public let itemClass: Int
    /// Outfit-level `ScanMask` (Bible): marks this outfit as contraband to
    /// any government whose own `gövt.ScanMask` shares a set bit. @1006.
    /// Distinct from `MissionRes.scanMask` (a different, mission-level
    /// field used for boarding/cargo-scan checks) — see OUTFITTERS.md §6.
    public let scanMask: UInt16
    /// `OnPurchase` (Bible): "Control bit set expression... evaluated when the
    /// item is bought." An NCB *set* expression (same grammar as a mission's
    /// OnAccept), run as a side effect of a shop purchase — e.g. a permit that
    /// flips a story bit. @301, `n0FF` (255-byte NCB string). Empty = no effect.
    /// See OUTFITTERS.md §3.3a / §8.
    public let onPurchase: String
    /// `OnSell` (Bible): the sibling NCB set expression "evaluated when the item
    /// is sold." @556, `n0FF`. Empty = no effect.
    public let onSell: String

    public init(_ r: Resource) {
        id = r.id
        name = r.name.isEmpty ? "Outfit \(r.id)" : r.name
        let d = r.data
        displayWeight = ai16(d, 0)
        mass = ai16(d, 2)
        techLevel = ai16(d, 4)
        maxInstallable = ai16(d, 10)
        flags = au16(d, 12)
        cost = ai32(d, 14)
        // Four modifier slots at 6, 18, 22, 26 — each is (Int16 type, Int16 value).
        var mods: [(OutfitModType, Int)] = []
        for pos in [6, 18, 22, 26] {
            let t = OutfitModType(raw: ai16(d, pos))
            guard t != .none, t != .unknown else { continue }
            mods.append((t, ai16(d, pos + 2)))
        }
        modifiers = mods
        contribute = au64(d, 30)
        require = au64(d, 38)
        availBits = acstr(d, 46, 255)
        requireGovt = ai16(d, 1010)
        buyRandom = ai16(d, 1008)
        itemClass = ai16(d, 1004)
        scanMask = au16(d, 1006)
        onPurchase = acstr(d, 301, 255)
        onSell = acstr(d, 556, 255)
    }

    /// Full-hide opt-ins (Bible `oütf.Flags`): normally a locked item still
    /// shows greyed-out; these bits mean "omit it from the list entirely"
    /// unless the player already owns one.
    public var hidesWhenLocked: Bool { flags & 0x0100 != 0 || flags & 0x4000 != 0 }
    /// "This item can be sold anywhere, regardless of tech level,
    /// requirements, or mission bits" (Bible, `Flags` 0x0800).
    public var ignoresRequirements: Bool { flags & 0x0800 != 0 }

    /// Sum of one modifier kind across this outfit's slots (0 if absent).
    public func value(of kind: OutfitModType) -> Int {
        modifiers.filter { $0.type == kind }.reduce(0) { $0 + $1.value }
    }
    /// True if any slot has this modifier (for boolean-style outfits).
    public func has(_ kind: OutfitModType) -> Bool {
        modifiers.contains { $0.type == kind }
    }
    /// Weapon ids this outfit grants (ModType 1).
    public var grantedWeapons: [Int] {
        modifiers.filter { $0.type == .weapon }.map(\.value)
    }
    /// (weapon id) this outfit supplies ammo for (ModType 3), if any.
    public var ammoFor: [Int] {
        modifiers.filter { $0.type == .ammunition }.map(\.value)
    }
    /// The ModVals of this outfit's map modifiers (`ModType 16`), if any. A map
    /// outfit reveals systems when acquired — see `NovaGame.mapRevealedSystems`
    /// for what each value means (positive = N jumps out; -1 = inhabited
    /// independent; <= -1000 = a govt class). Usually one entry.
    public var mapModVals: [Int] {
        modifiers.filter { $0.type == .map }.map(\.value)
    }
    /// The government ids this outfit clears the player's legal record with when
    /// acquired (`ModType 21`, "clean legal record"): the Bible's "ID of govt to
    /// clear legal record with, or -1 for all". Empty if this isn't a
    /// record-clearing outfit.
    public var cleanRecordGovts: [Int] {
        modifiers.filter { $0.type == .cleanRecord }.map(\.value)
    }
    /// The outfit ids whose maximum this outfit raises (`ModType 27`, "increase
    /// maximum"): "The ID number of another outfit item... whose maximum value
    /// is to be increased." See `NovaGame.effectiveMaxInstallable`.
    public var increasesMaxOf: [Int] {
        modifiers.filter { $0.type == .increaseMax }.map(\.value)
    }
}

// MARK: gövt — government (diplomatic relations & behavior)

/// A government: its diplomatic stance (class membership, ally/enemy classes),
/// crime penalties, and behavior flags. Two governments are hostile when one's
/// `enemies` classes intersect the other's `classes`, or a xenophobe/attack flag
/// applies. See `Diplomacy` in NovaSwiftEngine.
public struct GovtRes {
    public let id: Int
    public let name: String

    public let voiceType: Int
    public let flags1: UInt16
    public let flags2: UInt16
    public let scanFine: Int
    public let crimeTolerance: Int
    public let smugglePenalty: Int
    public let disablePenalty: Int
    public let boardPenalty: Int
    public let killPenalty: Int
    public let shootPenalty: Int
    public let initialRecord: Int
    public let maxOdds: Int
    /// The classes this government belongs to (−1 slots stripped).
    public let classes: [Int]
    /// Classes this government is allied with.
    public let allies: [Int]
    /// Classes this government is hostile to.
    public let enemies: [Int]
    public let shipSpeedFactor: Int
    /// `gövt.ScanMask` (Bible): 16-bit contraband jurisdiction mask. "If any of
    /// the 1 bits in a government's ScanMask field match any of the 1 bits in a
    /// mission's [or jünk type's, or outfit's] ScanMask field, that government
    /// will consider that cargo illegal." `0` = this govt polices nothing. @50,
    /// `WB16`, confirmed against real data: Federation `0x8000`, its sub-factions
    /// (Bureau `0x8008`, Civvies `0x8010`) inherit the `0x8000` bit — the same
    /// bit-space `mïsn.ScanMask@24` uses. See docs/reverse-engineering/GOVERNMENT.md.
    public let scanMask: UInt16
    /// "The short string to show for ships of this government when they are
    /// hailed by the player" (EV Nova Bible). Falls back to `name` when blank.
    public let commName: String
    /// "The short string to show in the player's target display when a ship of
    /// this government is targeted." Falls back to `name` when blank.
    public let targetCode: String
    /// `Require` (Bible): AND'ed against the player's ship+outfit
    /// `Contribute` bits; unmet ⇒ can't land on any planet/station of this
    /// government at all ("useful for making travel permits"). @84, 8 bytes
    /// (`QB64`, same 64-bit shape as `OutfRes.contribute`/`.require` above).
    /// Confirmed via GOVERNMENT.md's "Correction" section against the real
    /// `gövt` TMPL + a raw `gövt #128` dump.
    public let require: UInt64
    /// `InhJam1-4` (Bible): inherent jamming 0-100% per of 4 jam types.
    /// @92, `RECT` = 4× `DWRD` (2 bytes each).
    public let jamming: [Int]
    /// `MediumName` (Bible): "used in 'Sensors detect *xxx* reinforcement
    /// fleet approaching.'" A longer name than `commName`, distinct field.
    /// @100, `C040`, 64 bytes, Mac Roman C-string.
    public let mediumName: String
    /// `Color` (Bible): "HTML-style theme color for UI." @164, `LCOL`, 4 bytes.
    public let mapColor: NovaColor
    /// `ShipColor` (Bible): "HTML-style theme color for... ship paint."
    /// @168, `LCOL`, 4 bytes.
    public let shipColor: NovaColor
    /// `Interface` (Bible): `ïntf` resource id used when the player flies a
    /// ship whose inherent govt equals this govt (values <128 clamp to 128).
    /// @172, `RSID`, 2 bytes.
    public let interface: Int
    /// `NewsPic` (Bible): news-window background PICT id when landed on this
    /// govt's turf; <128 falls back to generic (PICT 9000). @174, `RSID`, 2 bytes.
    public let newsPic: Int

    // Flags 1 (behavior)
    public var xenophobic: Bool       { flags1 & 0x0001 != 0 } // attacks everyone except allies
    public var nosy: Bool             { flags1 & 0x0002 != 0 } // attacks player where he's a criminal
    public var alwaysAttacksPlayer: Bool { flags1 & 0x0004 != 0 }
    public var immuneToPlayer: Bool   { flags1 & 0x0008 != 0 }
    public var warshipsRetreat: Bool  { flags1 & 0x0010 != 0 } // retreat below 25% shields
    public var neverAttacksPlayer: Bool { flags1 & 0x0040 != 0 }
    public var warshipsTakeBribes: Bool { flags1 & 0x0200 != 0 }
    public var cantBeHailed: Bool     { flags1 & 0x0400 != 0 }
    public var plundersBeforeKilling: Bool { flags1 & 0x1000 != 0 }
    /// "Can't Request Assist/Mercy, non-talkative" — never has anything to say
    /// when hailed even though `cantBeHailed` is false.
    public var nonTalkative: Bool     { flags2 & 0x0001 != 0 }
    /// "Roadside Assistance" (Bible `Flags2` 0x0010): this govt refuels and
    /// repairs the player for free at its ports. NOT `flags1` 0x0010 — that bit
    /// is `warshipsRetreat`. (Historically the spaceport read the wrong word.)
    public var roadsideAssistance: Bool { flags2 & 0x0010 != 0 }
    /// `gövt.Flags2` gate-travel dispositions (Bible): whether this govt's ships
    /// avoid hypergates, prefer them over jumping out, or prefer wormholes.
    /// Drives which govts' ships emerge from / depart via a system's gates.
    public var avoidsHypergates: Bool  { flags2 & 0x0020 != 0 }
    public var prefersHypergates: Bool { flags2 & 0x0040 != 0 }
    public var prefersWormholes: Bool  { flags2 & 0x0080 != 0 }

    public init(_ r: Resource) {
        id = r.id
        name = r.name.isEmpty ? "Govt \(r.id)" : r.name
        let d = r.data
        voiceType = ai16(d, 0)
        flags1 = au16(d, 2)
        flags2 = au16(d, 4)
        scanFine = ai16(d, 6)
        crimeTolerance = ai16(d, 8)
        smugglePenalty = ai16(d, 10)
        disablePenalty = ai16(d, 12)
        boardPenalty = ai16(d, 14)
        killPenalty = ai16(d, 16)
        shootPenalty = ai16(d, 18)
        initialRecord = ai16(d, 20)
        maxOdds = ai16(d, 22)
        classes = (0..<4).map { ai16(d, 24 + $0 * 2) }.filter { $0 != -1 }
        allies  = (0..<4).map { ai16(d, 32 + $0 * 2) }.filter { $0 != -1 }
        enemies = (0..<4).map { ai16(d, 40 + $0 * 2) }.filter { $0 != -1 }
        shipSpeedFactor = ai16(d, 48)
        scanMask = au16(d, 50)
        let rawName = acstr(d, 52, 16)
        commName = rawName.isEmpty ? name : rawName
        let rawTarget = acstr(d, 68, 16).trimmingCharacters(in: .whitespaces)
        targetCode = rawTarget.isEmpty ? name : rawTarget
        require = au64(d, 84)
        jamming = (0..<4).map { ai16(d, 92 + $0 * 2) }
        mediumName = acstr(d, 100, 64)
        mapColor = acolor(d, 164)
        shipColor = acolor(d, 168)
        interface = ai16(d, 172)
        newsPic = ai16(d, 174)
    }
}

/// Applies a legal-record penalty to `govt` plus the Bible's §1.2 ally/enemy
/// propagation: "Doing evil deeds to one government will improve your rating
/// with its enemies, and vice versa. Allied governments also communicate your
/// actions, so attacking one government will make its allies hate you too."
/// Neither propagation's magnitude is quantified by the Bible; both use the
/// same invented-but-consistent half-penalty, mirrored in sign (allies
/// suffer, enemies benefit). Used for the *universal* (mission-driven) legal
/// record — see `applyLocal` for the spatial version hostile ship-to-ship
/// actions use instead. Shared by `NovaSwiftEngine.Diplomacy` and
/// `NovaSwiftStory.ContrabandScan` so both apply the same rule instead of
/// drifting apart — `NovaSwiftStory` can't depend on `NovaSwiftEngine`, so
/// this lives in the shared base module.
public enum LegalRecordPropagation {
    public static func apply(penalty: Int, to govt: Int, in record: inout [Int: Int], govts: [Int: GovtRes]) {
        record[govt, default: 0] -= penalty
        guard let victim = govts[govt] else { return }
        for (id, other) in govts where id != govt {
            if !Set(other.classes).isDisjoint(with: victim.allies) {
                record[id, default: 0] -= penalty / 2
            }
            if !Set(other.classes).isDisjoint(with: victim.enemies) {
                record[id, default: 0] += penalty / 2
            }
        }
    }

    /// The same ally/enemy propagation as `apply`, but for a hostile action
    /// against a ship (combat, boarding, a detected-smuggling scan) rather
    /// than a mission reward — per the EVN wiki's Legal Status page: "Hostile
    /// actions against ships will be reflected locally, while status changes
    /// due to missions will be reflected universally... Hostile actions
    /// against ships that a government regards favorably will be reflected
    /// in a 3 system radius. Hostile actions against ships that a government
    /// regards negatively will be reflected in a 5 system radius." `current`
    /// (the system the action happened in) gets the full, unscaled penalty —
    /// same magnitude as `apply` would give it. `spread` receives a tapered
    /// share (linear falloff to 0 at the radius edge — the wiki doesn't
    /// quantify the falloff shape, only that farther systems count for less)
    /// in every *other* system within radius, keyed govt id -> system id.
    public static func applyLocal(penalty: Int, to govt: Int, atSystem origin: Int,
                                  current: inout [Int: Int], spread: inout [Int: [Int: Int]],
                                  govts: [Int: GovtRes], game: NovaGame) {
        func apply(delta: Int, to targetGovt: Int) {
            guard delta != 0 else { return }
            current[targetGovt, default: 0] += delta
            let radius = delta < 0 ? 5 : 3   // unfavorable felt farther than favorable
            for (systemID, hop) in game.systemsWithinHops(of: origin, maxHops: radius) where hop > 0 {
                let scaled = delta * (radius - hop) / radius
                guard scaled != 0 else { continue }
                spread[targetGovt, default: [:]][systemID, default: 0] += scaled
            }
        }
        apply(delta: -penalty, to: govt)
        guard let victim = govts[govt] else { return }
        for (id, other) in govts where id != govt {
            if !Set(other.classes).isDisjoint(with: victim.allies) { apply(delta: -penalty / 2, to: id) }
            if !Set(other.classes).isDisjoint(with: victim.enemies) { apply(delta: penalty / 2, to: id) }
        }
    }
}

extension NovaGame {
    /// System ids within `maxHops` hyperspace jumps of `origin` (via
    /// `sÿst.links`), BFS-limited, mapped to their hop distance (`origin`
    /// itself is hop 0). Backs `LegalRecordPropagation.applyLocal`'s spatial
    /// decay — the wiki's "actions in adjacent systems are also taken into
    /// consideration, although given less weight than actions committed in
    /// the immediate vicinity."
    public func systemsWithinHops(of origin: Int, maxHops: Int) -> [Int: Int] {
        var dist: [Int: Int] = [origin: 0]
        var frontier = [origin]
        var hop = 0
        while hop < maxHops, !frontier.isEmpty {
            hop += 1
            var next: [Int] = []
            for sid in frontier {
                guard let s = system(sid) else { continue }
                for link in s.links where dist[link] == nil {
                    dist[link] = hop
                    next.append(link)
                }
            }
            frontier = next
        }
        return dist
    }
}

// MARK: düde — an AI ship archetype (what actually gets spawned)

/// EV Nova's AI dispositions, from `düde`'s AI Type field. Higher-fidelity
/// behavior branches off these in the engine's `AIBrain`.
public enum AIType: Int, Sendable {
    case wimpyTrader = 1   // flees at the first sign of trouble
    case braveTrader = 2   // fights back if attacked, then flees when hurt
    case warship = 3       // seeks out and attacks hostiles
    case interceptor = 4   // aggressive warship; pursues relentlessly
    case unknown = 0

    public init(raw: Int) { self = AIType(rawValue: raw) ?? .unknown }
    public var isTrader: Bool { self == .wimpyTrader || self == .braveTrader }
    public var isWarship: Bool { self == .warship || self == .interceptor }
}

/// A "dude": an NPC archetype tying an AI disposition + government to a weighted
/// table of ship classes it can appear as. Spawning picks a ship by probability.
public struct DudeRes {
    public let id: Int
    public let name: String
    public let aiTypeRaw: Int
    public let govt: Int
    public let flags: UInt16
    /// (ship class id, spawn probability 0…100). Probabilities across the table
    /// sum to ~100 in real data.
    public let ships: [(shipID: Int, prob: Int)]

    public var aiType: AIType { AIType(raw: aiTypeRaw) }
    /// This dude may not damage or be damaged by the player (escort/ally scenery).
    public var cantHitPlayer: Bool { flags & 0x0100 != 0 }

    // `Booty` (Bible): which commodities a boarded ship of this dude class
    // carries. Shares this same field with `cantHitPlayer` above.
    public var carriesFood: Bool { flags & 0x0001 != 0 }
    public var carriesIndustrial: Bool { flags & 0x0002 != 0 }
    public var carriesMedical: Bool { flags & 0x0004 != 0 }
    public var carriesLuxury: Bool { flags & 0x0008 != 0 }
    public var carriesMetal: Bool { flags & 0x0010 != 0 }
    public var carriesEquipment: Bool { flags & 0x0020 != 0 }
    /// The commodities this dude class carries, in `Commodity` order — empty
    /// means "you were repelled while attempting to board" (Bible), i.e. no
    /// cargo loot at all regardless of what's actually in the hold.
    public var bootyCommodities: [Commodity] {
        [
            carriesFood ? .food : nil, carriesIndustrial ? .industrial : nil,
            carriesMedical ? .medical : nil, carriesLuxury ? .luxury : nil,
            carriesMetal ? .metal : nil, carriesEquipment ? .equipment : nil,
        ].compactMap { $0 }
    }

    public init(_ r: Resource) {
        id = r.id
        name = r.name.isEmpty ? "Dude \(r.id)" : r.name
        let d = r.data
        aiTypeRaw = ai16(d, 0)
        govt = ai16(d, 2)
        flags = au16(d, 4)
        var table: [(Int, Int)] = []
        for i in 0..<16 {
            let shipID = ai16(d, 8 + i * 2)
            let prob = ai16(d, 40 + i * 2)
            if shipID >= 128 && prob > 0 { table.append((shipID, prob)) }
        }
        ships = table
    }

    /// Pick a ship class from the weighted table using a value in 0..<total.
    /// Deterministic given `roll`, so spawning can use a seeded RNG.
    public func pickShip(roll: Int) -> Int? {
        guard !ships.isEmpty else { return nil }
        let total = ships.reduce(0) { $0 + $1.prob }
        guard total > 0 else { return ships.first?.shipID }
        var acc = 0
        let target = ((roll % total) + total) % total
        for entry in ships {
            acc += entry.prob
            if target < acc { return entry.shipID }
        }
        return ships.last?.shipID
    }
}

// MARK: flët — a fleet (flagship + weighted escorts, and where it appears)

/// A fleet: a lead ship plus escort ship classes with min/max counts, an
/// affiliation government, and a rule for which systems it populates.
public struct FleetRes {
    public let id: Int
    public let name: String
    public let leadShip: Int
    public let escorts: [(shipID: Int, min: Int, max: Int)]
    public let govt: Int
    /// −1 = any system; 128…2175 a specific `sÿst`; 10000+g govt g's systems, etc.
    public let linkSystem: Int
    /// `AppearOn` (Bible): "a control bit test field that will cause a given
    /// fleet to appear only when the expression evaluates to true. If this
    /// field is left blank it will be ignored" (blank ⇒ always eligible).
    /// @30, 256-byte NCB test string. Offset confirmed via FLEETS.md §2/§7
    /// against the real `flët` TMPL + a raw `flët #128` dump.
    public let appearOn: String
    /// `Quote` (Bible, named `Hail Quote` in the TMPL): "show a random string
    /// from the STR# resource with this ID when the fleet enters from
    /// hyperspace" (literal `#` chars replaced with a random digit). @286, `RSID`.
    public let hailQuote: Int
    /// `Flags` (Bible): only bit `0x0001` is documented — see
    /// `freightersHaveRandomCargo` below. @288, `WORV`, 2 bytes.
    public let flags: UInt16

    /// `Flags` 0x0001: "Freighters (`InherentAI` <= 2) in this fleet will
    /// have random cargo when boarded" (Bible).
    public var freightersHaveRandomCargo: Bool { flags & 0x0001 != 0 }

    public init(_ r: Resource) {
        id = r.id
        name = r.name.isEmpty ? "Fleet \(r.id)" : r.name
        let d = r.data
        leadShip = ai16(d, 0)
        var e: [(Int, Int, Int)] = []
        for i in 0..<4 {
            let shipID = ai16(d, 2 + i * 2)
            let mn = ai16(d, 10 + i * 2)
            let mx = ai16(d, 18 + i * 2)
            if shipID >= 128 { e.append((shipID, max(0, mn), max(mn, mx))) }
        }
        escorts = e
        govt = ai16(d, 26)
        linkSystem = ai16(d, 28)
        appearOn = acstr(d, 30, 256)
        hailQuote = ai16(d, 286)
        flags = au16(d, 288)
    }
}

// MARK: wëap — weapon (makes the AI's "attack" real)

/// EV Nova weapon guidance kinds we distinguish for simulation.
public enum WeaponGuidance: Int, Sendable {
    case unguided = -1
    case beam = 0
    case guided = 1
    case beamTurret = 3
    case turret = 4
    case freefallBomb = 5
    case rocket = 6
    case frontQuadrant = 7
    case rearQuadrant = 8
    case pointDefense = 9
    case pointDefenseBeam = 10
    case bay = 99
    case other = 1000

    public init(raw: Int) { self = WeaponGuidance(rawValue: raw) ?? .other }
}

/// A weapon type: damage, projectile behaviour, range and fire rate. Offsets are
/// from novaparse's verified `WeapResource`.
public struct WeapRes {
    public let id: Int
    public let name: String
    public let reload: Int          // frames between shots (lower = faster)
    public let duration: Int        // projectile lifetime in frames
    public let armorDamage: Int
    public let shieldDamage: Int
    public let guidanceRaw: Int
    public let speed: Int           // projectile speed (px per frame at 30 fps)
    public let ammoType: Int        // −1 = no ammo; ≥0 draws from that ammo
    public let accuracy: Int        // spread in degrees (0 = perfect)
    /// `wëap` accuracy is stored signed; a negative value means "fires at a
    /// fixed angle" (no target lead even for turrets). We keep `accuracy` as the
    /// magnitude and expose the sign here.
    public let firesAtFixedAngle: Bool
    public let impact: Int          // @20 knockback impulse (inversely ∝ target mass)
    /// `snd ` id played when this weapon fires, or nil if it's silent.
    public let fireSoundID: Int?
    /// `bööm` id detonated on impact/expiry (drives the hit/explosion sound and
    /// sprite), or nil if this weapon has no explosion.
    public let explosionBoomID: Int?
    /// Continuous-fire weapons (typically beams) loop their fire sound instead of
    /// retriggering it every simulation frame while held.
    public let loopSound: Bool
    public let proxRadius: Int
    public let blastRadius: Int
    public let beamLength: Int
    /// Beam thickness in pixels (`wëap` @50). Only meaningful for beam weapons.
    public let beamWidth: Int
    /// Core beam colour (`wëap` @54, a 4-byte `0x00RRGGBB` field). Drives the
    /// on-screen beam tint so e.g. a Polaris beam renders in its authentic hue
    /// instead of a generic white line. Only meaningful for beam weapons.
    public let beamColor: NovaColor
    /// Beam glow colour (`wëap` @58, a 4-byte `0x00RRGGBB` field, novaparse
    /// `coronaColor`): the outer edge tint a beam fades to away from its
    /// `beamColor` core. Real EV Nova beams have no sprite art at all — they're
    /// drawn as this two-tone core→corona gradient, which is why every beam
    /// looked identical before this was decoded (only the flat core tint was).
    public let coronaColor: NovaColor
    /// How sharply a beam's glow falls off from its core to `coronaColor`
    /// (`wëap` @52, novaparse `coronaFalloff`). Higher = a tighter, harder-edged
    /// core; lower = a softer, wider glow.
    public let coronaFalloff: Int
    /// Which set of `shän` weapon exit points a shot leaves from (`wëap` @88):
    /// -1 = ship centre, 0 = gun, 1 = turret, 2 = guided, 3 = beam. Offset
    /// verified against novaparse `WeapResource.ts` (`exitTypeN`).
    public let exitType: Int
    public let turnRate: Int        // for guided munitions
    public let maxAmmo: Int
    public let count: Int           // rounds consumed / fired per shot
    /// Raw `Flags` field (@28). Offset verified against novaparse `WeapResource.ts`.
    public let flagsRaw: UInt16
    /// Raw "Seeker" field (@30, guided-weapon behavior flags). Offset verified
    /// against novaparse `WeapResource.ts` (`guidedFlags`).
    public let seekerFlagsRaw: Int
    /// "The amount of ionization energy to add to the ship that gets hit by
    /// this weapon" (EV Nova Bible). Offset verified against novaparse
    /// `WeapResource.ts` (`ionization`).
    public let ionization: Int      // @74

    /// `spïn` id of this weapon's own shot graphic (`wëap` @14, +3000 base), or
    /// nil if it draws no sprite. Lets a torpedo/rocket/bolt render its real
    /// animation instead of a generic dot.
    public let graphicSpinID: Int?
    /// "How fast to decay each shot's power: remove one point of shield & armor
    /// damage every this-many frames" (Bible, `wëap` @34). 0/-1 = no decay.
    public let decay: Int
    /// Submunition on shot expiry/detonation: how many, which `wëap` id, angular
    /// spread (deg), and recursion limit. Nil when the shot doesn't split.
    public let subCount: Int        // @62
    public let subID: Int           // @64 (>=128 to be valid)
    public let subTheta: Int        // @66 spread in degrees
    public let subLimit: Int        // @68 recursion cap
    /// "Time delay for the proximity fuse, in 30ths of a second" (Bible, @70).
    public let proxSafety: Int
    /// Burst fire: fire `burstCount` shots at the fast `reload` cadence, then a
    /// long `burstReload` cooldown (Bible, @90/@92). 0/-1 = no burst.
    public let burstCount: Int
    public let burstReload: Int
    /// Recoil impulse applied to the firing ship (@86). -1 → 0 (no recoil);
    /// any other negative value means "thrust the ship forward" instead of the
    /// usual backward kick (Bible), so the sign must survive past decode.
    public let recoil: Int
    /// Raw `Flags2` field (@72), for submunition/prox behaviour flags.
    public let flags2Raw: UInt16
    /// Raw `Flags3` field (@102, novaparse `WeapResource.ts`). Firing-behavior
    /// flags: 0x0001 one-ammo-per-burst, 0x0002 translucent shots, 0x0004 can't
    /// refire until the previous shot ends, 0x0010 fire from the exit point closest
    /// to the target, 0x0020 exclusive (blocks the ship's other weapons).
    public let flags3Raw: UInt16
    /// `Durability` (@104): for a *guided* weapon, how many point-defense hits one
    /// of its shots survives before being shot down. 0 = destroyed by any PD hit
    /// (the default). Ignored for non-guided projectiles and beams.
    public let durability: Int
    /// `Trail` particle system (@36-46): the smoke/spark trail this shot leaves as
    /// it flies. `count` particles per emit, launched at `velocity` px/frame with a
    /// life in `lifeMin...lifeMax` frames, tinted `color`. Inactive when count ≤ 0.
    public let trailParticles: WeaponParticleSpec
    /// Hit particle spray (@76-84): the burst thrown off the impact point when a
    /// shot connects (`count`, single `life`, `velocity`, `color`). Inactive when
    /// count ≤ 0 — the renderer then falls back to a generic shield/armor spark.
    public let hitParticles: WeaponParticleSpec
    /// `LiDensity` (@110): zig-zags per 100 px for a *beam* weapon. 0 = a normal
    /// straight beam; > 0 makes it a lightning beam (Bible). Ignored for non-beams.
    public let lightningDensity: Int
    /// `LiAmplitude` (@112): the amplitude in px of each lightning zig-zag (Bible).
    public let lightningAmplitude: Int
    /// `IonizeColor` (@114, a 4-byte `0x00RRGGBB` LCOL): the tint a ship hit by
    /// this weapon glows once it's "sufficiently ionized" (Bible). Nil when the
    /// field is 0 — the Bible's stated "default bluish color" — so a downstream
    /// default applies instead of flashing the hull black. Offset verified
    /// against novaparse `WeapResource.ts` (`ionizeColor = getColor32(114)`).
    public let ionizeColor: NovaColor?

    public var guidance: WeaponGuidance { WeaponGuidance(raw: guidanceRaw) }
    /// `Flags` 0x0200 / 0x0400: this weapon generates small / big smoke as its
    /// shots fly. `Flags` 0x0800: that smoke trail is more persistent (Bible).
    public var generatesSmallSmoke: Bool { flagsRaw & 0x0200 != 0 }
    public var generatesBigSmoke: Bool { flagsRaw & 0x0400 != 0 }
    public var persistentSmoke: Bool { flagsRaw & 0x0800 != 0 }
    /// A beam whose `LiDensity` is positive renders as a jagged lightning bolt
    /// rather than a straight line (Bible: "makes it look cool").
    public var isLightningBeam: Bool { lightningDensity > 0 }
    /// `Guidance 99` — "Carried ship (AmmoType is the ID of the ship class)"
    /// (Bible). A fighter bay: firing it launches a real sub-ship rather than a
    /// projectile.
    public var isFighterBay: Bool { guidance == .bay }
    /// For a fighter bay (`guidance 99`), the `shïp` class id of the fighter it
    /// launches — stored in `AmmoType` (Bible). Meaningless for other weapons.
    public var fighterShipID: Int { ammoType }
    /// For a fighter bay, how many fighters the bay holds (`MaxAmmo`) — e.g. a
    /// Viper Bay carries 4, a Thunderhead Bay 3 (confirmed against real data).
    public var fighterCapacity: Int { max(0, maxAmmo) }
    /// `Flags` 0x0002: this weapon fires on the *secondary* trigger (typically
    /// missiles/torpedoes), not the primary.
    public var firedBySecondTrigger: Bool { flagsRaw & 0x0002 != 0 }
    /// `Flags` 0x0040: "multiple weapons of this type fire simultaneously". When
    /// off (the default), several copies of the weapon stagger — one barrel at a
    /// time at `reload / count` — instead of volleying every reload.
    public var fireSimultaneously: Bool { flagsRaw & 0x0040 != 0 }
    /// `Flags` 0x0020: "Weapon passes through shields" (Bible, "use sparingly!").
    /// Its mass/armor damage reaches the hull even while the target's shields are
    /// still up — the one authentic exception to shields-protect-armor.
    public var penetratesShields: Bool { flagsRaw & 0x0020 != 0 }
    /// `Flags` 0x8000: "shot detonates at the end of its lifespan" (flak).
    public var detonateOnExpire: Bool { flagsRaw & 0x8000 != 0 }
    /// `Flags2` 0x0200: "This weapon uses the ship's weapon sprite, if
    /// applicable" (Bible) — this shot flashes the firing hull's own `shän`
    /// weapon-glow overlay (`ShanRes.weaponGlowSpriteID`, faded per `WeapDecay`)
    /// instead of (or alongside) its own shot art. Only weapons with this flag
    /// should trigger that overlay.
    public var usesShipWeaponSprite: Bool { flags2Raw & 0x0200 != 0 }
    /// `Flags3` 0x0020: exclusive — while this weapon is firing or reloading, no
    /// other weapon on the ship may fire (Bible).
    public var isExclusive: Bool { flags3Raw & 0x0020 != 0 }
    /// `Flags3` 0x0004: the firing ship can't loose another shot of this weapon
    /// until its previous shot expires or hits something (Bible).
    public var cantRefireUntilShotEnds: Bool { flags3Raw & 0x0004 != 0 }
    /// `Flags3` 0x0010: fire from whichever weapon exit point is closest to the
    /// target, rather than cycling exit points in order (Bible).
    public var firesFromClosestExit: Bool { flags3Raw & 0x0010 != 0 }
    /// `Flags3` 0x0002: this weapon's shots are drawn translucent (visual only).
    public var translucentShots: Bool { flags3Raw & 0x0002 != 0 }
    /// `Flags3` 0x0001: ammo is consumed only at the end of a burst cycle, not per
    /// shot within the burst (Bible).
    public var oneAmmoPerBurst: Bool { flags3Raw & 0x0001 != 0 }
    /// `Flags` 0x0001: spin the shot graphic continuously.
    public var spinShots: Bool { flagsRaw & 0x0001 != 0 }
    /// `Flags2` 0x0020 (inverted): launch submunitions when the shot expires.
    public var subIfExpire: Bool { flags2Raw & 0x0020 == 0 }
    /// `Flags2` 0x0010: submunitions fire toward the nearest valid target.
    public var subFireAtNearest: Bool { flags2Raw & 0x0010 != 0 }
    /// `Flags2` 0x0008 (or any non-guided weapon): the proximity fuse triggers on
    /// ships other than the target too.
    public var proxHitAll: Bool { flags2Raw & 0x0008 != 0 || guidance != .guided }
    /// True when this weapon splits into submunitions.
    public var hasSubmunition: Bool { subID >= 128 && subCount > 0 }
    public var isBeam: Bool { guidance == .beam || guidance == .beamTurret || guidance == .pointDefenseBeam }
    public var isGuided: Bool {
        switch guidance { case .guided, .rocket, .frontQuadrant, .rearQuadrant: return true; default: return false }
    }
    public var isTurret: Bool { guidance == .turret || guidance == .beamTurret }
    /// "Seeker" 0x0020: "Can't fire if ship is ionized" — a per-weapon flag,
    /// not automatic for all guided weapons.
    public var cantFireWhileIonized: Bool { seekerFlagsRaw & 0x0020 != 0 }
    /// "Seeker" 0x0008: "Confused by sensor interference".
    public var confusedByInterference: Bool { seekerFlagsRaw & 0x0008 != 0 }
    /// "Seeker" 0x0010: "Turns away if jammed".
    public var turnsAwayIfJammed: Bool { seekerFlagsRaw & 0x0010 != 0 }
    /// "Guidance = 9/10... fires automatically at incoming guided weapons and
    /// nearby ships" (EV Nova Bible).
    public var isPointDefense: Bool { guidance == .pointDefense || guidance == .pointDefenseBeam }
    /// "Weapon can't be targeted by point defense systems (works only for
    /// homing weapons)" is `Flags` 0x0080; this is the inverse (matches
    /// novaparse's `vulnerableToPD = (flags & 0x80) == 0`).
    public var vulnerableToPD: Bool { flagsRaw & 0x0080 == 0 }
    /// Effective reach in world pixels. Beams use their length; projectiles use
    /// speed × lifetime (the game runs the projectile sim at 30 fps).
    public var range: Double {
        if isBeam { return Double(max(beamLength, 50)) }
        return Double(speed) * Double(max(duration, 1))
    }

    public init(_ r: Resource) {
        id = r.id
        name = r.name.isEmpty ? "Weapon \(r.id)" : r.name
        let d = r.data
        reload = ai16(d, 0)
        duration = ai16(d, 2)
        armorDamage = ai16(d, 4)
        shieldDamage = ai16(d, 6)
        guidanceRaw = ai16(d, 8)
        speed = ai16(d, 10)
        ammoType = ai16(d, 12)
        let rawGraphic = ai16(d, 14)
        graphicSpinID = rawGraphic <= 0 ? nil : rawGraphic + 3000
        let rawAccuracy = ai16(d, 16)
        accuracy = abs(rawAccuracy)
        firesAtFixedAngle = rawAccuracy < 0
        let rawSound = ai16(d, 18)
        fireSoundID = rawSound == -1 ? nil : rawSound + 200
        impact = ai16(d, 20)
        explosionBoomID = boomID(raw: ai16(d, 22))
        let flags = au16(d, 28)
        loopSound = flags & 0x0010 != 0
        flagsRaw = flags
        seekerFlagsRaw = ai16(d, 30)
        decay = ai16(d, 34)
        ionization = ai16(d, 74)
        proxRadius = ai16(d, 24)
        blastRadius = ai16(d, 26)
        beamLength = ai16(d, 48)
        beamWidth = ai16(d, 50)
        coronaFalloff = ai16(d, 52)
        beamColor = acolor(d, 54)
        coronaColor = acolor(d, 58)
        subCount = ai16(d, 62)
        subID = ai16(d, 64)
        subTheta = ai16(d, 66)
        subLimit = ai16(d, 68)
        proxSafety = ai16(d, 70)
        flags2Raw = au16(d, 72)
        flags3Raw = au16(d, 102)
        durability = ai16(d, 104)
        let rawRecoil = ai16(d, 86)
        recoil = rawRecoil == -1 ? 0 : rawRecoil
        exitType = ai16(d, 88)
        burstCount = ai16(d, 90)
        burstReload = ai16(d, 92)
        turnRate = ai16(d, 106)
        maxAmmo = ai16(d, 108)
        count = ai16(d, 118)
        // Trail particles (@36 count, @38 velocity, @40/@42 life min/max, @44 color)
        // and hit particles (@76 count, @78 life, @80 velocity, @82 color) — the
        // shot's smoke/spark trail and its impact spray, straight from the wëap.
        trailParticles = WeaponParticleSpec(count: ai16(d, 36), velocity: ai16(d, 38),
                                            lifeMin: ai16(d, 40), lifeMax: ai16(d, 42),
                                            color: acolor(d, 44))
        let hitLife = ai16(d, 78)
        hitParticles = WeaponParticleSpec(count: ai16(d, 76), velocity: ai16(d, 80),
                                          lifeMin: hitLife, lifeMax: hitLife,
                                          color: acolor(d, 82))
        lightningDensity = ai16(d, 110)
        lightningAmplitude = ai16(d, 112)
        // IonizeColor (@114): 0 → the Bible's "default bluish color", surfaced as
        // nil so a downstream default applies rather than a black hull flash.
        ionizeColor = ai32(d, 114) == 0 ? nil : acolor(d, 114)
    }
}

/// A `wëap` particle burst descriptor — the shared shape of the weapon's `Trail`
/// (in-flight smoke/sparks) and its impact spray. Counts/velocities/lifetimes are
/// in the game's native units (particles per emit, px per 30 fps frame, frames);
/// the renderer scales them into its own particle system.
public struct WeaponParticleSpec: Equatable {
    public let count: Int
    public let velocity: Int
    public let lifeMin: Int
    public let lifeMax: Int
    public let color: NovaColor
    /// Whether this weapon actually emits these particles (a non-zero count).
    public var isActive: Bool { count > 0 }
    public init(count: Int, velocity: Int, lifeMin: Int, lifeMax: Int, color: NovaColor) {
        self.count = count; self.velocity = velocity
        self.lifeMin = lifeMin; self.lifeMax = lifeMax; self.color = color
    }
}

// MARK: bööm — an explosion (sprite + sound), referenced by wëap/shïp explosion fields

/// A decoded `bööm` resource: the animation and sound played when a weapon's
/// shot detonates or a ship breaks up. Offsets verified against `Templates.rsrc`
/// TMPL #500 and cross-checked with NovaJS's `BoomResource.ts`.
public struct BoomRes {
    public let id: Int
    public let name: String
    public let animationRate: Int
    /// `snd ` id played on detonation, or nil if this explosion is silent.
    public let soundID: Int?
    public let graphicSpinID: Int

    public init(_ r: Resource) {
        id = r.id
        name = r.name.isEmpty ? "Boom \(r.id)" : r.name
        let d = r.data
        animationRate = ai16(d, 0)
        let rawSound = ai16(d, 2)
        soundID = rawSound == -1 ? nil : rawSound + 300
        graphicSpinID = ai16(d, 4) + 400
    }
}
