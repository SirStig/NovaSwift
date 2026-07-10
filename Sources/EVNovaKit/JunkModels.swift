import Foundation

// Typed decoder for `jünk` — "specialized commodities that can be bought and
// sold at a few locations" (Nova Bible, lines 1163-1207): a parallel, much
// narrower trade-goods system layered on top of the six standard commodities
// (`Commodity` in NovaEconomy.swift). Unlike those, a junk type trades only at
// specific `spöb` ids and has a single average price rather than a per-stellar
// Low/Med/High tier. See docs/reverse-engineering/ECONOMY.md §3.
//
// Byte layout (TMPL #509, `Templates.rsrc`, 676 bytes total) — confirmed
// against all 23 real records in `Nova Data 1.rez` (ids 128-150):
// `SoldAt1-8`@0 (8×RSID, 16B) `BoughtAt1-8`@16 (8×RSID, 16B) `BasePrice`@32
// (WORD, 2B) `Flags`@34 (WORV, 2B) `ScanMask`@36 (WB16, 2B) `LCName`@38 (C040,
// 64B) `Abbrev`@102 (C040, 64B) `BuyOn`@166 (n0FF/NCB Test, 255B) `SellOn`@421
// (n0FF/NCB Test, 255B).

// MARK: Byte helpers (big-endian, bounds-safe; file-private, matching the
// convention in NovaModels.swift/NovaAIModels.swift of a per-file copy rather
// than a shared internal module).

@inline(__always) private func ji16(_ d: Data, _ off: Int) -> Int {
    guard off >= 0, off + 2 <= d.count else { return 0 }
    let base = d.startIndex + off
    let v = (Int(d[base]) << 8) | Int(d[base + 1])
    return v >= 0x8000 ? v - 0x10000 : v
}

@inline(__always) private func ju16(_ d: Data, _ off: Int) -> UInt16 {
    guard off >= 0, off + 2 <= d.count else { return 0 }
    let base = d.startIndex + off
    return UInt16(d[base]) << 8 | UInt16(d[base + 1])
}

/// Read a NUL-terminated Mac Roman C-string from a fixed-size field at `off`,
/// reading at most `maxLen` bytes. Trailing garbage after the NUL is ignored.
@inline(__always) private func jcstr(_ d: Data, _ off: Int, _ maxLen: Int) -> String {
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

/// A junk cargo type: salvage/specialty trade goods sellable/buyable only at
/// specific stellars, distinct from the six standard commodities. Verified
/// against `jünk` 128 "Vrenna Ice Lizard Pelts" (see ECONOMY.md §3/§5).
public struct JunkRes {
    public let id: Int
    public let name: String

    /// `SoldAt1-8`@0 — the up-to-8 `spöb` ids where this junk type is
    /// available to *buy* (the market "sells" it to the player — the low side
    /// of a buy-low/sell-high pair, hence `lows`). 0/-1 slots stripped.
    public let lows: [Int]
    /// `BoughtAt1-8`@16 — the up-to-8 `spöb` ids where this junk type can be
    /// *sold* (the market "buys" it from the player — the high side of a
    /// buy-low/sell-high pair, hence `highs`). 0/-1 slots stripped.
    public let highs: [Int]
    /// `BasePrice`@32 — "the average price of the commodity (works much like
    /// the base prices for 'regular' commodities)": one flat credit value,
    /// not a Low/Medium/High per-stellar tier.
    public let basePrice: Int
    /// `Flags`@34 — cargo-bay side effects. See `multipliesInCargoHold` /
    /// `decaysInCargoHold` below.
    public let flags: UInt16
    /// `ScanMask`@36 — illegal-cargo bitmask, ANDed against a ship's
    /// government's `ScanMask` (same mechanism as `OutfRes.scanMask`); a set
    /// bit in common makes this junk type contraband to that government.
    public let scanMask: UInt16
    /// `LCName`@38 (64B) — player-info-dialog name (lowercase, per Bible).
    public let lowercaseName: String
    /// `Abbrev`@102 (64B) — status-bar abbreviation.
    public let statusBarAbbrev: String
    /// `BuyOn`@166 (255B) — NCB control-bit test expression gating whether
    /// this junk type may be bought. Independent boolean gate, not a percent
    /// chance (junk has no `BuyRandom`-style field).
    public let buyOn: String
    /// `SellOn`@421 (255B) — NCB control-bit test expression gating whether
    /// this junk type may be sold.
    public let sellOn: String

    /// Bible `Flags` 0x0001 "Tribbles" — this junk multiplies in the cargo
    /// bay over time.
    public var multipliesInCargoHold: Bool { flags & 0x0001 != 0 }
    /// Bible `Flags` 0x0002 "Perishable" — this junk decays away in the cargo
    /// bay over time.
    public var decaysInCargoHold: Bool { flags & 0x0002 != 0 }

    public init(_ r: Resource) {
        id = r.id
        name = r.name.isEmpty ? "Junk \(r.id)" : r.name
        let d = r.data
        lows = (0..<8).map { ji16(d, 0 + $0 * 2) }.filter { $0 > 0 }
        highs = (0..<8).map { ji16(d, 16 + $0 * 2) }.filter { $0 > 0 }
        basePrice = ji16(d, 32)
        flags = ju16(d, 34)
        scanMask = ju16(d, 36)
        lowercaseName = jcstr(d, 38, 64)
        statusBarAbbrev = jcstr(d, 102, 64)
        buyOn = jcstr(d, 166, 255)
        sellOn = jcstr(d, 421, 255)
    }
}

extension NovaGame {
    public func junk(_ id: Int) -> JunkRes? {
        resources.resource(NovaType.junk, id).map(JunkRes.init)
    }
    public func junks() -> [JunkRes] {
        resources.resources(of: NovaType.junk).map(JunkRes.init)
    }
}
