import Foundation

// Typed decoder for `öops` — the Bible's "disaster" resource, explicitly
// documented as a misnomer: "these occurrences simply affect the price of a
// single commodity at a planet or station, for good or bad" (lines 1792-1819).
// A scripted, timed price-modifier event for one of the six standard
// commodities (`Commodity` in NovaEconomy.swift) — not a catastrophe with any
// other gameplay effect. See docs/reverse-engineering/ECONOMY.md §4.
//
// Byte layout (TMPL #512, `Templates.rsrc`, 282 bytes total) — confirmed
// against all 19 real records in `Nova Data 2.rez` (ids 128-146):
// `Stellar`@0 (RSID, 2B) `Commodity`@2 (CASR 6-case enum, 2B) `PriceDelta`@4
// (2B) `Duration`@6 (2B) `Freq`@8 (2B) `ActivateOn`@10 (n100/NCB Test, 256B)
// `[unused]`@266 (F010, 16B).

// MARK: Byte helpers (big-endian, bounds-safe; file-private, matching the
// convention in NovaModels.swift/NovaAIModels.swift of a per-file copy rather
// than a shared internal module).

@inline(__always) private func oi16(_ d: Data, _ off: Int) -> Int {
    guard off >= 0, off + 2 <= d.count else { return 0 }
    let base = d.startIndex + off
    let v = (Int(d[base]) << 8) | Int(d[base + 1])
    return v >= 0x8000 ? v - 0x10000 : v
}

/// Read a NUL-terminated Mac Roman C-string from a fixed-size field at `off`,
/// reading at most `maxLen` bytes. Trailing garbage after the NUL is ignored.
@inline(__always) private func ocstr(_ d: Data, _ off: Int, _ maxLen: Int) -> String {
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

/// A "disaster": a scripted, per-day-rolled price-modifier event for one
/// standard commodity at a stellar (or galaxy-wide). The resource's own
/// `name` doubles as the in-UI label shown in the commodity exchange dialog
/// while it's active (Bible). Verified against `öops` 128 "An enormous food
/// surplus" (see ECONOMY.md §4/§5).
public struct OopsRes {
    public let id: Int
    public let name: String

    /// `Stellar`@0 — scope of the disaster. `128-1628`: a specific `spöb` id.
    /// `-1`: any planet or station (galaxy-wide; "use sparingly" per Bible).
    /// `-2`: no price effect at all — mission-related news flavor only.
    public let stellar: Int
    /// `Commodity`@2 — which of the six standard commodities to affect (0 =
    /// food ... 5 = equipment). The Bible's own `CASR` enum for this field is
    /// a closed six-way choice; every real record stays in 0-5 (ECONOMY.md
    /// §4's resolved question). Use `commodityEnum` for the typed value.
    public let commodity: Int
    /// `PriceDelta`@4 — additive credit adjustment to `commodity`'s price at
    /// `stellar` (negative = price drop). Not a replacement or a percentage.
    public let priceDelta: Int
    /// `Duration`@6 — how many days the disaster lasts before its price
    /// effect reverts.
    public let duration: Int
    /// `Freq`@8 — percent chance *per day* that the disaster occurs (a daily
    /// Bernoulli roll, not a scheduled/deterministic trigger).
    public let freq: Int
    /// `ActivateOn`@10 (256B) — NCB control-bit test expression; the disaster
    /// can only trigger on days where this evaluates true. Blank ("leave
    /// blank if unused") = no gate, `freq` alone governs eligibility.
    public let activateOn: String

    /// `commodity` as the typed six-way enum, or nil if (contrary to every
    /// real base-game record) it falls outside 0-5.
    public var commodityEnum: Commodity? { Commodity(rawValue: commodity) }
    /// `Stellar` == -1: applies galaxy-wide rather than to one specific stellar.
    public var appliesToAnyStellar: Bool { stellar == -1 }
    /// `Stellar` == -2: a no-op disaster with no price effect, used purely to
    /// drive mission/news flavor text via its own name.
    public var isNewsOnly: Bool { stellar == -2 }

    public init(_ r: Resource) {
        id = r.id
        name = r.name.isEmpty ? "Oops \(r.id)" : r.name
        let d = r.data
        stellar = oi16(d, 0)
        commodity = oi16(d, 2)
        priceDelta = oi16(d, 4)
        duration = oi16(d, 6)
        freq = oi16(d, 8)
        activateOn = ocstr(d, 10, 256)
    }
}

extension NovaGame {
    public func oops(_ id: Int) -> OopsRes? {
        resources.resource(NovaType.oops, id).map(OopsRes.init)
    }
    public func oopses() -> [OopsRes] {
        resources.resources(of: NovaType.oops).map(OopsRes.init)
    }

    /// Additive price adjustment for `commodity` at `spobID` from the currently
    /// active `öops` disasters (`activeOops` = the ids the pilot has active). Sums
    /// every matching disaster — one pinned to this stellar or galaxy-wide (-1).
    public func disasterPriceDelta(spobID: Int, commodity: Commodity, activeOops: [Int]) -> Int {
        var delta = 0
        for id in activeOops {
            guard let o = oops(id), o.commodityEnum == commodity else { continue }
            if o.stellar == spobID || o.appliesToAnyStellar { delta += o.priceDelta }
        }
        return delta
    }

    /// Names of active disasters affecting `spobID`, for display in the commodity
    /// exchange dialog (the öops `name` doubles as its in-UI label, per the Bible).
    public func activeDisasterNames(spobID: Int, activeOops: [Int]) -> [String] {
        activeOops.compactMap { oops($0) }
            .filter { $0.stellar == spobID || $0.appliesToAnyStellar }
            .map(\.name)
    }
}
