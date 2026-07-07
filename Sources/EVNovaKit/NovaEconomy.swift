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
// the service bits (low byte); `chär` holds the starting pilot; the standard
// commodity prices themselves are engine constants (not in the data).

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
/// fallback, and the Low/Medium/High table is the credits-per-ton price. Those
/// absolute prices are **engine constants — they are not stored in the scenario
/// data** — so they live here, tunable in one place.
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

    /// (low, medium, high) credits per ton.
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

// MARK: - chär — the starting pilot template

/// The scenario's new-game defaults: which hull the player starts in, how many
/// credits, and where. (Enough to bootstrap a fresh pilot; ranks/bits/date are
/// applied by the story layer.)
public struct CharRes: Sendable {
    public let id: Int
    public let startingCredits: Int   // @0  int32
    public let startingShip: Int      // @4  shïp id
    public let startingSystems: [Int] // @6/8/10/12 (first valid is the start)

    public init(_ r: Resource) {
        id = r.id
        let d = r.data
        startingCredits = be32(d, 0)
        startingShip = be16(d, 4)
        startingSystems = [6, 8, 10, 12].map { be16(d, $0) }.filter { $0 >= 128 }
    }

    /// The system the pilot begins in (first valid starting system, else 128).
    public var startingSystem: Int { startingSystems.first ?? 128 }
}

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
    /// Empty when the planet has no commodity exchange.
    public func commodityMarket(at spob: SpobRes) -> [(commodity: Commodity, level: PriceLevel, price: Int)] {
        guard spob.hasCommodityExchange else { return [] }
        return Commodity.allCases.compactMap { c in
            let level = spob.priceLevel(c)
            guard let price = level.price(for: c) else { return nil }
            return (c, level, price)
        }
    }

    /// The outfits for sale at `spob`, ordered as EV Nova's outfitter lists them
    /// (by display weight, then id). Empty when there's no outfitter.
    public func outfitsSold(at spob: SpobRes) -> [OutfRes] {
        guard spob.hasOutfitter else { return [] }
        return outfits()
            .filter { sells(techLevel: $0.techLevel, at: spob) }
            .sorted { ($0.displayWeight, $0.id) < ($1.displayWeight, $1.id) }
    }

    /// The hulls for sale at `spob`, cheapest first. Empty when there's no shipyard.
    public func shipsSold(at spob: SpobRes) -> [ShipRes] {
        guard spob.hasShipyard else { return [] }
        return ships()
            .filter { $0.cost > 0 && sells(techLevel: $0.techLevel, at: spob) }
            .sorted { ($0.cost, $0.id) < ($1.cost, $1.id) }
    }
}
