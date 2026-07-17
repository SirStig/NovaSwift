import Foundation

// The spaceport economy layer: what a `spöb` sells and at what price. This adds
// only *derived* views on top of the already-decoded resources — the raw byte
// layout stays owned by `NovaModels.swift`. Everything here is additive
// (extensions + small value types), so the interaction/landing UI can read a
// planet's market, outfitter and shipyard without new field decoding.
//
// All offsets are big-endian and verified against the real game data (see
// docs/DATA_FORMAT.md): the `spöb` `flags` word (@6) packs both the six standard
// commodity price levels (one nibble each in the upper 24 bits, Food first) and
// the service bits (low byte); `chär` holds the starting pilot. The standard
// commodity prices themselves are scenario data: per the Bible's Appendix III
// ("Patching STR# Resources", lines 3580-3609), a plugin overrides them with
// single `STR ` resources 9300-9305 (one base-price string per commodity),
// the same override mechanism `STR ` 9400-9405 uses for status-bar
// abbreviations — see `NovaGame.commodityPrices(_:)` below. The hardcoded
// table on `Commodity.prices` is only the fallback for data that doesn't
// define the override (see docs/reverse-engineering/ECONOMY.md §1/§5).

// MARK: Local big-endian helpers (the ones in NovaModels are file-private)

@inline(__always) private func be16(_ d: Data, _ off: Int) -> Int {
    guard off >= 0, off + 2 <= d.count else { return 0 }
    let b = d.startIndex + off
    let v = (Int(d[b]) << 8) | Int(d[b + 1])
    return v >= 0x8000 ? v - 0x10000 : v
}

@inline(__always) private func be32(_ d: Data, _ off: Int) -> Int {
    guard off >= 0, off + 4 <= d.count else { return 0 }
    let b = d.startIndex + off
    let v = (UInt32(d[b]) << 24) | (UInt32(d[b + 1]) << 16) | (UInt32(d[b + 2]) << 8) | UInt32(d[b + 3])
    return Int(Int32(bitPattern: v))
}

// MARK: - Standard commodities & price levels

/// EV Nova's six standard trade goods. Display names come from `STR# 4000` at
/// runtime (see `NovaGame.commodityName`); the built-in names here are the
/// fallback, and the Low/Medium/High table is the credits-per-ton price. Per
/// the Bible's Appendix III, those absolute prices are themselves patchable
/// scenario data (`STR ` 9300-9305) — see `NovaGame.commodityPrices(_:)`,
/// which prefers that data and falls back to the table below only when the
/// data doesn't define it.
public enum Commodity: Int, CaseIterable, Sendable {
    case food = 0, industrial, medical, luxury, metal, equipment

    /// Cargo-hold key (matches EV Nova's cargo type numbering and the `STR# 4000`
    /// index; mission cargo uses ids ≥ 6).
    public var cargoID: Int { rawValue }

    public var fallbackName: String {
        switch self {
        case .food:       return "Food"
        case .industrial: return "Industrial"
        case .medical:    return "Medical Supplies"
        case .luxury:     return "Luxury Goods"
        case .metal:      return "Metal"
        case .equipment:  return "Equipment"
        }
    }

    /// (low, medium, high) credits per ton — the built-in fallback table, used
    /// when the scenario data has no `STR ` 9300-9305 override. Prefer
    /// `NovaGame.commodityPrices(_:)` for the actual in-game price.
    public var prices: (low: Int, medium: Int, high: Int) {
        switch self {
        case .food:       return (12, 15, 18)
        case .industrial: return (30, 35, 40)
        case .medical:    return (80, 90, 100)
        case .luxury:     return (150, 175, 200)
        case .metal:      return (200, 250, 300)
        case .equipment:  return (400, 450, 500)
        }
    }

    /// The commodity for a cargo-hold key, if it is one of the six standard goods.
    public static func standard(cargoID: Int) -> Commodity? { Commodity(rawValue: cargoID) }
}

/// A planet's price stance for one commodity: not traded, or Low / Medium / High.
public enum PriceLevel: Int, Sendable, Equatable {
    case notTraded = 0, low, medium, high

    /// Decode from a `spöb` price nibble (0 = not traded, 1 = low, 2 = med, 4 = high).
    public init(nibble: Int) {
        switch nibble {
        case 1:  self = .low
        case 2:  self = .medium
        case 4:  self = .high
        default: self = .notTraded
        }
    }

    public var isTraded: Bool { self != .notTraded }

    public var label: String {
        switch self {
        case .notTraded: return "—"
        case .low:       return "Low"
        case .medium:    return "Med"
        case .high:      return "High"
        }
    }

    /// The market price for `commodity` at this level, or nil if not traded here.
    public func price(for commodity: Commodity) -> Int? {
        switch self {
        case .notTraded: return nil
        case .low:       return commodity.prices.low
        case .medium:    return commodity.prices.medium
        case .high:      return commodity.prices.high
        }
    }
}

// MARK: - spöb services & prices (derived from the flags word)

extension SpobRes {
    // Service bits live in the low byte of the 32-bit `flags` word.
    public var canLand: Bool               { flags & 0x01 != 0 }
    public var hasCommodityExchange: Bool  { flags & 0x02 != 0 }
    public var hasOutfitter: Bool          { flags & 0x04 != 0 }
    public var hasShipyard: Bool           { flags & 0x08 != 0 }
    public var isStation: Bool             { flags & 0x10 != 0 }
    public var isUninhabited: Bool         { flags & 0x20 != 0 }
    public var hasBar: Bool                { flags & 0x40 != 0 }
    public var landsOnlyWhenDestroyed: Bool { flags & 0x80 != 0 }

    /// Whether the player can dock here at all. (Uninhabited rocks that carry no
    /// "can land" bit are still fly-by scenery.)
    public var isLandable: Bool { canLand || (landingPictID > 0 && landingPictID != 0xFFFF) }

    /// The Low/Med/High/not-traded level for one standard commodity. Each good is
    /// a 4-bit nibble in the upper 24 bits of `flags`, Food (index 0) highest.
    public func priceLevel(_ commodity: Commodity) -> PriceLevel {
        let shift = UInt32(28 - 4 * commodity.rawValue)
        return PriceLevel(nibble: Int((flags >> shift) & 0xF))
    }
}

// The full `chär` starting-scenario decoder (`CharRes`) lives in
// CharacterModels.swift; `startingChar()` below returns it.

// MARK: - NovaGame economy accessors

extension NovaGame {
    /// The scenario's starting-pilot template (`chär`) — the lowest-id one, which
    /// is EV Nova's default character.
    public func startingChar() -> CharRes? {
        resources.resources(of: NovaType.char).min { $0.id < $1.id }.map(CharRes.init)
    }

    /// Display name of one of the six standard commodities (`STR# 4000`, falling
    /// back to the built-in name if the data doesn't define it).
    public func commodityName(_ commodity: Commodity) -> String {
        if let list = stringList(4000), commodity.rawValue < list.strings.count {
            let s = list.strings[commodity.rawValue]
            if !s.isEmpty { return s }
        }
        return commodity.fallbackName
    }

    /// A single override `STR ` resource (**not** the indexed `STR#` list) —
    /// the mechanism the Bible's Appendix III uses for its numbered
    /// "replace this id to override that built-in value" ranges, e.g.
    /// 9300-9305 for commodity base prices. Classic Mac resource format: one
    /// length byte, then that many Mac Roman bytes (a single Pascal string).
    private func overrideString(_ id: Int) -> String? {
        guard let d = resources.resource(FourCharCode("STR ")!, id)?.data, !d.isEmpty else { return nil }
        let length = Int(d[d.startIndex])
        guard length > 0, d.count >= 1 + length else { return nil }
        let raw = d.subdata(in: (d.startIndex + 1)..<(d.startIndex + 1 + length))
        return String(data: raw, encoding: .macOSRoman)
    }

    /// The base credit price for `commodity`, per Appendix III's `STR `
    /// 9300-9305 override range (one base-price string per commodity, food
    /// first — matching `STR# 4000`'s ordering). "Works much like the base
    /// prices for 'regular' commodities" is how the Bible itself describes
    /// `jünk.BasePrice` by analogy to this field. Returns nil when the data
    /// doesn't define an override for this commodity.
    public func commodityBasePrice(_ commodity: Commodity) -> Int? {
        guard let raw = overrideString(9300 + commodity.rawValue) else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespaces))
    }

    /// The Low/Medium/High credit price for `commodity`, preferring the
    /// scenario's own `STR ` 9300-9305 override (see `commodityBasePrice`)
    /// over the hardcoded `Commodity.prices` table — the same
    /// data-first/hardcoded-fallback pattern `commodityName` uses for
    /// `STR# 4000`. The Bible documents only *one* base-price string per
    /// commodity (Medium is that value); it doesn't state a Low/High
    /// formula, so this keeps this build's existing per-commodity-tuned
    /// Low/High *offsets* from Medium and re-anchors them to the override
    /// when present. Falls back to the untouched hardcoded triple when no
    /// override exists, so scenarios without it behave exactly as before.
    public func commodityPrices(_ commodity: Commodity) -> (low: Int, medium: Int, high: Int) {
        let hardcoded = commodity.prices
        guard let medium = commodityBasePrice(commodity) else { return hardcoded }
        let lowDelta = hardcoded.medium - hardcoded.low
        let highDelta = hardcoded.high - hardcoded.medium
        return (medium - lowDelta, medium, medium + highDelta)
    }

    /// A `spöb`'s extra "special tech" levels. These unlock outfits/ships whose
    /// tech level matches exactly, on top of the base tech gate. Read straight
    /// from the raw resource (@14/16/18) since `SpobRes` doesn't surface them.
    public func spobSpecialTech(_ spobID: Int) -> [Int] {
        guard let d = resources.resource(NovaType.spob, spobID)?.data else { return [] }
        return [14, 16, 18].map { be16(d, $0) }.filter { $0 > 0 }
    }

    /// Whether an item with `techLevel` is offered at `spob`: either the planet's
    /// tech level covers it, or it appears in the planet's special-tech list.
    public func sells(techLevel: Int, at spob: SpobRes) -> Bool {
        techLevel <= spob.techLevel || spobSpecialTech(spob.id).contains(techLevel)
    }

    /// The commodity market at `spob`: each traded good with its level and price.
    /// Empty when the planet has no commodity exchange. Prices come from
    /// `commodityPrices(_:)`, i.e. the scenario's `STR ` 9300-9305 override
    /// when present, else the hardcoded table.
    public func commodityMarket(at spob: SpobRes) -> [(commodity: Commodity, level: PriceLevel, price: Int)] {
        guard spob.hasCommodityExchange else { return [] }
        return Commodity.allCases.compactMap { c in
            let level = spob.priceLevel(c)
            guard level.isTraded else { return nil }
            let prices = commodityPrices(c)
            let price: Int
            switch level {
            case .low:       price = prices.low
            case .medium:    price = prices.medium
            case .high:      price = prices.high
            case .notTraded: return nil
            }
            return (c, level, price)
        }
    }

    /// The outfits for sale at `spob`, ordered as EV Nova's outfitter lists them
    /// (by display weight, then id). Empty when there's no outfitter. `day`
    /// (an absolute day count, e.g. `GameDate.julianDay`) applies `BuyRandom`
    /// — the Bible's "not everything shows every time" per-day stocking roll;
    /// pass `nil` to skip it (e.g. tooling that wants the full catalog).
    public func outfitsSold(at spob: SpobRes, day: Int? = nil) -> [OutfRes] {
        guard spob.hasOutfitter else { return [] }
        return outfits()
            // Bible `Flags 0x0800`: "This item can be sold anywhere, regardless
            // of tech level, requirements, or mission bits" — sell-side only
            // (waives the outfitter-stock restriction when selling an owned
            // item back; see the sell-back path). It does NOT bypass the
            // buy-listing tech-level gate — see OUTFITTERS.md §3.5.
            .filter { sells(techLevel: $0.techLevel, at: spob) }
            .filter { outfit in
                guard let day else { return true }
                return onOfferToday(buyRandom: outfit.buyRandom, neverIfZero: false,
                                     spobID: spob.id, itemID: outfit.id, day: day)
            }
            .sorted { ($0.displayWeight, $0.id) < ($1.displayWeight, $1.id) }
    }

    /// The hulls for sale at `spob`, cheapest first. Empty when there's no
    /// shipyard. `day` applies `BuyRandom` the same way as `outfitsSold` —
    /// except for ships a `BuyRandom` of exactly 0 means *never* stocked, not
    /// always (the Bible documents the two fields with opposite zero-behavior).
    public func shipsSold(at spob: SpobRes, day: Int? = nil) -> [ShipRes] {
        guard spob.hasShipyard else { return [] }
        return ships()
            .filter { $0.cost > 0 && sells(techLevel: $0.techLevel, at: spob) }
            .filter { ship in
                guard let day else { return true }
                return onOfferToday(buyRandom: ship.buyRandom, neverIfZero: true,
                                     spobID: spob.id, itemID: ship.id, day: day)
            }
            .sorted { ($0.cost, $0.id) < ($1.cost, $1.id) }
    }

    /// Whether a `BuyRandom`-gated item is stocked today: a deterministic roll
    /// seeded by (day, spöb, item) — stable within one in-game day (reopening
    /// the outfitter, or relaunching the app, on the same day shows the same
    /// stock), and re-rolls only when the day changes. Not persisted state;
    /// just a stable hash compared against the percent chance, so it needs no
    /// save-file support. `neverIfZero` selects the Bible's per-type zero
    /// behavior (outfits: 0/negative → always; ships: 0 → never).
    private func onOfferToday(buyRandom: Int, neverIfZero: Bool, spobID: Int, itemID: Int, day: Int) -> Bool {
        if buyRandom <= 0 { return !neverIfZero }
        let percent = min(buyRandom, 100)
        var hash: UInt64 = 14_695_981_039_346_656_037            // FNV-1a offset basis
        for value in [day, spobID, itemID] {
            for byte in withUnsafeBytes(of: Int64(value).bigEndian, Array.init) {
                hash ^= UInt64(byte)
                hash = hash &* 1_099_511_628_211                 // FNV-1a prime
            }
        }
        let roll = Int(hash % 100) + 1                           // 1...100
        return roll <= percent
    }
}
