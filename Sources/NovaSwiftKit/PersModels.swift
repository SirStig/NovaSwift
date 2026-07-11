import Foundation

@inline(__always) private func pi16(_ d: Data, _ off: Int) -> Int {
    guard off >= 0, off + 2 <= d.count else { return 0 }
    let b = d.startIndex + off
    let v = (Int(d[b]) << 8) | Int(d[b + 1])
    return v >= 0x8000 ? v - 0x10000 : v
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
    /// `ShipType`: the `shïp` class the person flies. @10.
    public let shipType: Int
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
        shipType = pi16(d, 10)
        grantClass = pi16(d, 308)
        grantProb = pi16(d, 310)
        grantCount = pi16(d, 312)
    }

    /// True if boarding this person can yield outfit loot (`GrantClass` set and a
    /// nonzero grant chance).
    public var grantsLoot: Bool { grantClass > 0 && grantProb > 0 && grantCount > 0 }
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
