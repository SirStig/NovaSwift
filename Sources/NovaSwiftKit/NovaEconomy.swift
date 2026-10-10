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
// commodity base prices are scenario data: the original reads each one from a
// single `STR ` override (9300-9305) when present, else from `STR# 4004`
// entries 1-6 (`Ship_InitGameplayDataTables` 0x004b0c20) — see
// `NovaGame.commodityBasePrice(_:)`.

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
/// runtime (see `NovaGame.commodityName`) and base prices from `STR# 4004` (see
/// `NovaGame.commodityBasePrice`); the built-in values here are only the
/// fallback for data that defines neither.
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

    /// The stock `STR# 4004` base price, used only when the data has no base
    /// price for this commodity.
    public var fallbackBasePrice: Int {
        switch self {
        case .food:       return 75
        case .industrial: return 350
        case .medical:    return 750
        case .luxury:     return 900
        case .metal:      return 200
        case .equipment:  return 550
        }
    }

    /// The trade center's Low/Medium/High prices for a base price
    /// (`NovaUi_RunTradeCenterWindow` 0x0048c730): Low = trunc(base / scale),
    /// Medium = base, High = trunc(base × scale), each floored at 5. The scale
    /// is 1.25 unless the stellar's system reputation or domination changes it.
    public static func prices(base: Int, scale: Float = 1.25) -> (low: Int, medium: Int, high: Int) {
        let low = Int((Float(base) / scale).rounded(.towardZero))
        let high = Int((Float(base) * scale).rounded(.towardZero))
        return (max(5, low), max(5, base), max(5, high))
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
        // `STR ` 9000+i wins over STR# 4000 entry i+1 (0x004c7040); the built-in
        // name is only for data that defines neither.
        return commodityDisplayName(commodity.rawValue) ?? commodity.fallbackName
    }

    /// A single `STR ` resource (**not** the indexed `STR#` list): one length
    /// byte, then that many Mac Roman bytes. The original checks these as
    /// per-id overrides of `STR#` entries — commodity prices (9300+), buoy
    /// messages (999+), and so on.
    public func singleString(_ id: Int) -> String? {
        guard let d = resources.resource(FourCharCode("STR ")!, id)?.data, !d.isEmpty else { return nil }
        let length = Int(d[d.startIndex])
        guard length > 0, d.count >= 1 + length else { return nil }
        let raw = d.subdata(in: (d.startIndex + 1)..<(d.startIndex + 1 + length))
        return String(data: raw, encoding: .macOSRoman)
    }

    /// The base credit price for `commodity`: `STR ` 9300+index when the data
    /// defines it, else `STR# 4004` entry index+1, parsed as a 16-bit number.
    /// Falls back to the stock value only when neither exists.
    public func commodityBasePrice(_ commodity: Commodity) -> Int {
        let raw = singleString(9300 + commodity.rawValue)
            ?? stringList(4004).flatMap { list in
                commodity.rawValue < list.strings.count ? list.strings[commodity.rawValue] : nil
            }
        guard let raw, let value = Self.stringToNum(raw) else { return commodity.fallbackBasePrice }
        return value
    }

    /// The leading signed decimal number in `s`, truncated to 16 bits as the
    /// original stores it; nil when there is no digit.
    static func stringToNum(_ s: String) -> Int? {
        var chars = Substring(s.trimmingCharacters(in: .whitespaces))
        var negative = false
        if let sign = chars.first, sign == "-" || sign == "+" {
            negative = sign == "-"
            chars = chars.dropFirst()
        }
        let digits = chars.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        var value = 0
        for d in digits { value = (value &* 10 &+ Int(String(d))!) & 0xFFFF }
        let int16 = Int(Int16(truncatingIfNeeded: value))
        return negative ? -int16 : int16
    }

    /// The Low/Medium/High credit price for `commodity` at the default 1.25
    /// trade-center scale (see `Commodity.prices(base:scale:)`).
    public func commodityPrices(_ commodity: Commodity) -> (low: Int, medium: Int, high: Int) {
        Commodity.prices(base: commodityBasePrice(commodity))
    }

    /// A `spöb`'s extra "special tech" levels. These unlock outfits/ships whose
    /// tech level matches exactly, on top of the base tech gate. Read straight
    /// from the raw resource since `SpobRes` doesn't surface them.
    ///
    /// The Bible says "SpecialTech (x8)", and ResForge's `spöb` TMPL #520 shows
    /// where all eight live: the first three sit inline at @14/@16/@18, and the
    /// remaining five were appended to the tail of the record at
    /// @1092/@1094/@1096/@1098/@1100. Reading only the first three (as this did
    /// originally) silently drops five slots per planet, so any outfit or hull
    /// stocked via one of the tail techs was invisible in that shop.
    public func spobSpecialTech(_ spobID: Int) -> [Int] {
        guard let d = resources.resource(NovaType.spob, spobID)?.data else { return [] }
        let offsets = [14, 16, 18, 1092, 1094, 1096, 1098, 1100]
        return offsets.filter { $0 + 2 <= d.count }.map { be16(d, $0) }.filter { $0 > 0 }
    }

    /// Whether an item with `techLevel` is offered at `spob`: either the planet's
    /// tech level covers it, or it appears in the planet's special-tech list.
    ///
    /// Tech levels are 1-based, so a `TechLevel` of 0 or less is the designers'
    /// "never stocked anywhere" marker, not "available at every port" — the base
    /// data uses it exactly once, on oütf #342 "Area Map - Vell-os", a
    /// mission-granted map whose own dësc (#3214) is literally "Placeholder text
    /// … This description is never seen by the player." Reading 0 as
    /// always-eligible put it on the outfitter shelf of every world for anyone
    /// who had been granted one (an owned item is never hidden, so it could not
    /// be filtered out downstream) — placeholder text and all. A `SpecialTech`
    /// slot can still stock such an item deliberately: those are matched
    /// exactly, and `spobSpecialTech` already drops non-positive slots.
    public func sells(techLevel: Int, at spob: SpobRes) -> Bool {
        guard techLevel > 0 else { return spobSpecialTech(spob.id).contains(techLevel) }
        return techLevel <= spob.techLevel || spobSpecialTech(spob.id).contains(techLevel)
    }

    /// The commodity market at `spob`: each traded good with its level and price.
    /// Empty when the planet has no commodity exchange. Prices come from
    /// `commodityPrices(_:)`.
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
    /// (higher display weight first, then id). Empty when there's no outfitter.
    /// `day` (an absolute day count, e.g. `GameDate.julianDay`) applies
    /// `BuyRandom` through the day's galaxy-wide roll (`dailyStockRoll`); pass
    /// `nil` to skip it (e.g. tooling that wants the full catalog). An item in
    /// `owned` skips the roll: the original zeroes the roll of anything the
    /// player owns, so it stays listed (0x0046a220).
    public func outfitsSold(at spob: SpobRes, day: Int? = nil, owned: Set<Int> = []) -> [OutfRes] {
        guard spob.hasOutfitter else { return [] }
        let available = outfits()
            // Bible `Flags 0x0800`: "This item can be sold anywhere, regardless
            // of tech level, requirements, or mission bits" — sell-side only
            // (waives the outfitter-stock restriction when selling an owned
            // item back; see the sell-back path). It does NOT bypass the
            // buy-listing tech-level gate — see OUTFITTERS.md §3.5.
            .filter { sells(techLevel: $0.techLevel, at: spob) }
            .filter { outfit in
                guard let day, !owned.contains(outfit.id) else { return true }
                return Self.stocked(buyRandom: outfit.buyRandom,
                                    roll: Self.dailyStockRoll(day: day, itemID: outfit.id, salt: 0))
            }
        // Bible `Flags 0x1000`: "When this item is available for sale, it
        // prevents all higher-numbered items with equal DispWeight from being
        // made available for sale at the same time." The lowest-id flagged
        // item in each weight tier caps that tier.
        var suppressorID: [Int: Int] = [:]   // displayWeight → lowest flagged id
        for o in available where o.suppressesHigherIDsAtSameWeight {
            suppressorID[o.displayWeight] = min(suppressorID[o.displayWeight] ?? Int.max, o.id)
        }
        return available
            .filter { o in o.id <= (suppressorID[o.displayWeight] ?? Int.max) }
            // Bible `DispWeight`: "Items with a higher display weight are shown
            // closer to the top of the outfit dialog" — descending weight,
            // ascending id within a tier.
            .sorted {
                $0.displayWeight != $1.displayWeight
                    ? $0.displayWeight > $1.displayWeight
                    : $0.id < $1.id
            }
    }

    /// The hulls for sale at `spob` in the shipyard's order (`shipyardList`,
    /// with no Availability or Require hides). Empty when there's no
    /// shipyard. `day` applies `BuyRandom` through the day's roll; `redraws`
    /// says how many times a class's roll was redrawn today (buying a ship
    /// redraws its class, 0x00492f30).
    public func shipsSold(at spob: SpobRes, day: Int? = nil,
                          redraws: (Int) -> Int = { _ in 0 }) -> [ShipRes] {
        guard spob.hasShipyard else { return [] }
        return shipyardList(at: spob, hire: false, stocked: { ship in
            guard let day else { return true }
            return Self.stocked(buyRandom: ship.buyRandom,
                                roll: Self.dailyStockRoll(day: day, itemID: ship.id, salt: 1,
                                                          redraw: redraws(ship.id)))
        }, availabilityPasses: { _ in true }, requirePasses: { _ in true })
    }

    /// `NovaUi_RebuildShipyardAvailabilityList` 0x00469e90: the shipyard's (or,
    /// with `hire`, the bar's) list at `spob`. A class is eligible when its
    /// TechLevel is at least 0 and either within the stellar's tech level or
    /// one of its SpecialTech values; then the day's BuyRandom (HireRandom)
    /// roll must pass. Flags3 0x0200 hides it when Require fails, 0x0100 when
    /// Availability fails. A class with Flags3 0x4000 hides every
    /// later-numbered class of the same DispWeight. The list runs by
    /// DispWeight, highest first, then id. No shipyard flag is checked: the
    /// bar hires at any stellar.
    public func shipyardList(at spob: SpobRes, hire: Bool, stocked: (ShipRes) -> Bool,
                             availabilityPasses: (ShipRes) -> Bool,
                             requirePasses: (ShipRes) -> Bool) -> [ShipRes] {
        let special = spobSpecialTech(spob.id)
        var eligible = ships().sorted { $0.id < $1.id }.filter { s in
            guard s.techLevel >= 0, s.techLevel <= spob.techLevel || special.contains(s.techLevel) else { return false }
            guard stocked(s) else { return false }
            if s.flags3 & 0x0200 != 0, !requirePasses(s) { return false }
            if s.flags3 & 0x0100 != 0, !availabilityPasses(s) { return false }
            return true
        }
        var hidden = Set<Int>()
        for (i, s) in eligible.enumerated() where s.flags3 & 0x4000 != 0 && !hidden.contains(s.id) {
            for later in eligible[(i + 1)...] where later.displayWeight == s.displayWeight {
                hidden.insert(later.id)
            }
        }
        eligible.removeAll { hidden.contains($0.id) }
        return eligible.sorted {
            $0.displayWeight != $1.displayWeight ? $0.displayWeight > $1.displayWeight : $0.id < $1.id
        }
    }

    /// Whether a ship class is on the bar's hire list today: `HireRandom` 0
    /// never, otherwise the class's daily hire roll must not exceed it.
    public static func hireable(_ ship: ShipRes, day: Int, redraw: Int = 0) -> Bool {
        stocked(buyRandom: ship.hireRandom,
                roll: dailyStockRoll(day: day, itemID: ship.id, salt: 2, redraw: redraw))
    }

    /// An item with `BuyRandom` (or `HireRandom`) `chance` shows when the
    /// chance is at least 1 and the day's roll does not exceed it.
    public static func stocked(buyRandom chance: Int, roll: Int) -> Bool {
        chance >= 1 && roll <= chance
    }

    /// The day's stock roll, 1...100, for one outfit (salt 0), shipyard class
    /// (1) or bar hire class (2). The original keeps one roll per item, shared
    /// by every port and redrawn at each daily tick (0x00466cb0); deriving it
    /// from the day gives the same behaviour without saving the table.
    /// `redraw` counts same-day redraws (a purchase or hire).
    public static func dailyStockRoll(day: Int, itemID: Int, salt: Int, redraw: Int = 0) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037            // FNV-1a offset basis
        for value in [day, itemID, salt, redraw] {
            for byte in withUnsafeBytes(of: Int64(value).bigEndian, Array.init) {
                hash ^= UInt64(byte)
                hash = hash &* 1_099_511_628_211                 // FNV-1a prime
            }
        }
        return Int(hash % 100) + 1
    }
}
