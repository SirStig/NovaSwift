import Foundation

@inline(__always) private func pi16(_ d: Data, _ off: Int) -> Int {
    guard off >= 0, off + 2 <= d.count else { return 0 }
    let b = d.startIndex + off
    let v = (Int(d[b]) << 8) | Int(d[b + 1])
    return v >= 0x8000 ? v - 0x10000 : v
}
@inline(__always) private func pi32(_ d: Data, _ off: Int) -> Int {
    guard off >= 0, off + 4 <= d.count else { return 0 }
    let b = d.startIndex + off
    let v = (UInt32(d[b]) << 24) | (UInt32(d[b + 1]) << 16) | (UInt32(d[b + 2]) << 8) | UInt32(d[b + 3])
    return Int(Int32(bitPattern: v))
}
@inline(__always) private func pu16(_ d: Data, _ off: Int) -> UInt16 {
    guard off >= 0, off + 2 <= d.count else { return 0 }
    let b = d.startIndex + off
    return UInt16(d[b]) << 8 | UInt16(d[b + 1])
}
@inline(__always) private func pcstr(_ d: Data, _ off: Int, _ maxLen: Int) -> String {
    guard off >= 0, off < d.count else { return "" }
    let start = d.startIndex + off, end = min(start + maxLen, d.endIndex)
    var bytes: [UInt8] = []; var i = start
    while i < end, d[i] != 0 { bytes.append(d[i]); i += 1 }
    return String(bytes: bytes, encoding: .macOSRoman) ?? ""
}

// MARK: përs — a named AI personality the player can encounter

/// A `përs` resource: a specific named individual who can appear flying a
/// particular ship, and — the part this port cares about first — what outfit
/// "loot" they hand over when the player boards their disabled ship (the
/// `ItemClass` grant mechanic). The broader përs system (hail quotes, link
/// missions, grudges) is not modeled here yet; this decodes the identity +
/// spawn-gating + boarding-grant fields.
///
/// Offsets confirmed empirically against the 516 shipped `përs` records:
/// `ShipType@10` is a valid `shïp` id in all 516; `Govt@2`/`AIType@4` match the
/// Bible's field order; `GrantClass@308` carries the one real `ItemClass` value
/// in the data (25, "Dr Ralph"), with `GrantProb@310`/`GrantCount@312` following
/// it in the Bible-stated order.
public struct PersRes {
    public let id: Int
    public let name: String
    /// `LinkSyst` (Bible): where the person can appear. -1 = anywhere; 128-2175 a
    /// specific system; 9999-10255 any system of that govt; 15000-15255 an ally's;
    /// 20000-20255 any but that govt; 25000-25255 an enemy's. @0.
    public let linkSyst: Int
    /// `Govt`: the person's government (-1 = independent). @2.
    public let govt: Int
    /// `AIType` (1 wimpy trader … 4 interceptor). @4.
    public let aiType: Int
    /// `Aggress`: how close ships get before the person attacks (1 close … 3 far). @6.
    public let aggression: Int
    /// `Coward`: percent of shields at which the person flees a fight. @8.
    public let coward: Int
    /// `ShipType`: the `shïp` class the person flies. @10.
    public let shipType: Int
    /// `WeapType`/`WeapCount`/`AmmoLoad` (4 slots each): extra weapons layered on
    /// top of the hull's stock fit at spawn. @12-19 / @20-27 / @28-35.
    public let weapType: [Int]
    public let weapCount: [Int]
    public let ammoLoad: [Int]
    /// `Credits`: credits the person carries (±25%), for boarding plunder. @36 (int32).
    public let credits: Int
    /// `ShieldMod`: percent shield scale (100 = stock, 130 = +30%, <0 = invincible). @40.
    public let shieldMod: Int
    /// `HailPict`: `PICT` shown in the comms dialog instead of the ship's default. @42.
    public let hailPict: Int
    /// `CommQuote`: 1-based index into `STR#` 7100, shown in the comms dialog. @44.
    public let commQuote: Int
    /// `HailQuote`: 1-based index into `STR#` 7101, shown over the radio (bottom
    /// of screen), gated by the flag conditions below. @46.
    public let hailQuote: Int
    /// `LinkMission`: `mïsn` id offered when this ship is hailed or boarded. @48.
    public let linkMission: Int
    /// `Flags`: behaviour bits (grudge, quote conditions, mission handling). @50.
    public let flags: UInt16
    /// `ActiveOn`: NCB test expression gating whether this person can appear. @52.
    public let activeOn: String
    /// `GrantClass` (Bible): "The class of outfit item given out by this person's
    /// ship when boarded by the player" — an `oütf.ItemClass` value. 0/-1 =
    /// nothing. @308.
    public let grantClass: Int
    /// `GrantProb`: percent chance (0-100) of granting any items when boarded. @310.
    public let grantProb: Int
    /// `GrantCount`: max items given; the actual count is between
    /// `GrantCount/2` and `GrantCount` (Bible). @312.
    public let grantCount: Int

    public init(_ r: Resource) {
        id = r.id
        name = r.name.isEmpty ? "Person \(r.id)" : r.name
        let d = r.data
        linkSyst = pi16(d, 0)
        govt = pi16(d, 2)
        aiType = pi16(d, 4)
        aggression = pi16(d, 6)
        coward = pi16(d, 8)
        shipType = pi16(d, 10)
        weapType = (0..<4).map { pi16(d, 12 + $0 * 2) }
        weapCount = (0..<4).map { pi16(d, 20 + $0 * 2) }
        ammoLoad = (0..<4).map { pi16(d, 28 + $0 * 2) }
        credits = pi32(d, 36)
        shieldMod = pi16(d, 40)
        hailPict = pi16(d, 42)
        commQuote = pi16(d, 44)
        hailQuote = pi16(d, 46)
        linkMission = pi16(d, 48)
        flags = pu16(d, 50)
        activeOn = pcstr(d, 52, 255)
        grantClass = pi16(d, 308)
        grantProb = pi16(d, 310)
        grantCount = pi16(d, 312)
    }

    /// True if boarding this person can yield outfit loot (`GrantClass` set and a
    /// nonzero grant chance).
    public var grantsLoot: Bool { grantClass > 0 && grantProb > 0 && grantCount > 0 }

    // Flags (Bible përs.Flags @50):
    /// 0x0001 — holds a grudge if attacked; then attacks the player everywhere.
    public var holdsGrudge: Bool { flags & 0x0001 != 0 }
    /// 0x0002 — uses an escape pod & has an afterburner.
    public var usesEscapePod: Bool { flags & 0x0002 != 0 }
    /// 0x0004 — only show HailQuote when the ship has a grudge against the player.
    public var hailQuoteWhenGrudge: Bool { flags & 0x0004 != 0 }
    /// 0x0008 — only show HailQuote when the ship likes the player.
    public var hailQuoteWhenLikes: Bool { flags & 0x0008 != 0 }
    /// 0x0010 — only show HailQuote when the ship begins to attack the player.
    public var hailQuoteWhenAttacking: Bool { flags & 0x0010 != 0 }
    /// 0x0020 — only show HailQuote when the ship is disabled.
    public var hailQuoteWhenDisabled: Bool { flags & 0x0020 != 0 }
    /// 0x0080 — only show the quote once.
    public var quoteOnce: Bool { flags & 0x0080 != 0 }
    /// 0x0100 — deactivate the person after accepting its LinkMission.
    public var deactivateAfterMission: Bool { flags & 0x0100 != 0 }
    /// 0x0200 — offer LinkMission when boarding rather than hailing.
    public var offerMissionOnBoard: Bool { flags & 0x0200 != 0 }
    /// 0x0400 — don't show the quote when the LinkMission isn't available.
    public var noQuoteWithoutMission: Bool { flags & 0x0400 != 0 }
    /// 0x0800 — the ship leaves after its LinkMission is accepted.
    public var leaveAfterMission: Bool { flags & 0x0800 != 0 }
    /// 0x8000 — show disaster info when hailed.
    public var showsDisasterInfo: Bool { flags & 0x8000 != 0 }
}

extension NovaGame {
    public func pers(_ id: Int) -> PersRes? { resources.resource(NovaType.pers, id).map(PersRes.init) }
    public func perses() -> [PersRes] { resources.resources(of: NovaType.pers).map(PersRes.init) }

    /// The outfit ids classified `itemClass` (`oütf.ItemClass`) — the pool a
    /// `përs` grant draws from. Sorted for determinism.
    public func outfits(ofClass itemClass: Int) -> [Int] {
        guard itemClass > 0 else { return [] }
        return outfits().filter { $0.itemClass == itemClass }.map(\.id).sorted()
    }

    /// Resolve a `përs` boarding grant deterministically from `seed`: returns the
    /// list of outfit ids the person hands over. Empty if the roll fails, the
    /// person grants no loot, or its class has no matching outfits. Per the Bible:
    /// grant with `GrantProb`% chance, then between `GrantCount/2` and
    /// `GrantCount` random outfits of `GrantClass`.
    public func personBoardingGrant(_ pers: PersRes, seed: UInt64) -> [Int] {
        guard pers.grantsLoot else { return [] }
        let pool = outfits(ofClass: pers.grantClass)
        guard !pool.isEmpty else { return [] }
        var h = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        func next() -> UInt64 { h ^= h << 13; h ^= h >> 7; h ^= h << 17; return h }

        if Int(next() % 100) >= pers.grantProb { return [] }   // GrantProb% chance
        let lo = max(1, pers.grantCount / 2)
        let span = max(0, pers.grantCount - lo)
        let n = lo + (span > 0 ? Int(next() % UInt64(span + 1)) : 0)
        return (0..<n).map { _ in pool[Int(next() % UInt64(pool.count))] }
    }
}
