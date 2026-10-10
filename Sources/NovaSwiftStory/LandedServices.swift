import Foundation
import NovaSwiftKit
import NovaSwiftEngine

/// The original's landed-service rules (FIDELITY_PLAN.md Batch 4): landing
/// clearance and fees, refuelling, the commodity price scale, shipyard pricing,
/// planetary bribes and the bar's racing bets. Pure functions over a
/// `PlayerState`, like `PilotEconomy`; the frontends own the windows.
public enum LandedServices {

    // MARK: Reputation seam

    /// The player's reputation in `system` — the value the original keeps per
    /// system (`system_reputation[]`, EC-02) and reads for landing, the trade
    /// center's price scale and the bribe button.
    ///
    /// Read straight from the pilot's per-system record; an independent system
    /// has a record like any other. `game` is unused and kept for callers.
    public static func systemReputation(_ state: PlayerState, system: Int, game: NovaGame) -> Int {
        state.reputation(atSystem: system)
    }

    /// Whether `spob` is dominated by the player (`spöb` +0x46 in the original).
    public static func isDominated(_ spob: SpobRes, _ state: PlayerState) -> Bool {
        state.hasDominated(spob.id)
    }

    // MARK: Trade center (EC-03)

    /// The trade center's price scale at `spob` (0x0048c730): 1.25, or 1.1 at a
    /// governed stellar whose system reputation is negative, or 1.5 when the
    /// stellar is dominated (tested last, so it wins).
    public static func commodityScale(spob: SpobRes, state: PlayerState, game: NovaGame) -> Double {
        var scale = 1.25
        if spob.government >= 128, let system = game.owningSystem(ofSpob: spob.id, state: state),
           systemReputation(state, system: system, game: game) < 0 {
            scale = 1.1
        }
        if isDominated(spob, state) { scale = 1.5 }
        return scale
    }

    /// One row of the trade center: a standard good (rows 0–5) or the two junk
    /// rows (6: a junk this stellar buys, priced high; 7: one it sells, priced
    /// low). The original allows both Buy and Sell on every row.
    public struct TradeRow: Equatable, Sendable {
        public let cargoID: Int
        /// Low/Medium/High; the junk rows read High (bought here) and Low
        /// (sold here).
        public let level: PriceLevel
        public let price: Int
        public let disaster: Bool
    }

    /// The trade center's rows at `spob` (0x0048c730):
    /// - each traded good at `trunc(base / scale)` (Low), `base` (Medium) or
    ///   `trunc(base × scale)` (High), floored at 5;
    /// - an active `öops` at this stellar *replaces* that price with
    ///   `base + delta`, floored at 5 (the last matching disaster wins);
    /// - row 6: the highest-id junk whose BoughtAt lists this stellar and whose
    ///   BuyOn passes, at `trunc(base × scale)`; row 7: the highest-id junk whose
    ///   SoldAt lists it and whose SellOn passes, at `trunc(base / scale)`. Junk
    ///   prices take no floor. (The match exits only the inner stellar loop, so
    ///   a later junk overwrites an earlier one.)
    ///
    /// Rank `PriceMod` never reaches commodities (EC-10).
    public static func tradeRows(at spob: SpobRes, state: PlayerState, game: NovaGame) -> [TradeRow] {
        guard spob.hasCommodityExchange else { return [] }
        let scale = Float(commodityScale(spob: spob, state: state, game: game))
        var rows: [TradeRow] = []
        let disasters = activeDisasterDeltas(at: spob.id, state: state, game: game)
        for c in Commodity.allCases {
            let level = spob.priceLevel(c)
            guard level.isTraded else { continue }
            let base = game.commodityBasePrice(c)
            if let delta = disasters[c] {
                rows.append(TradeRow(cargoID: c.cargoID, level: level, price: max(5, base + delta), disaster: true))
                continue
            }
            let p = Commodity.prices(base: base, scale: scale)
            let price: Int
            switch level {
            case .low: price = p.low
            case .high: price = p.high
            default: price = p.medium
            }
            rows.append(TradeRow(cargoID: c.cargoID, level: level, price: price, disaster: false))
        }
        var boughtHere: JunkRes?, soldHere: JunkRes?
        for j in game.junks().sorted(by: { $0.id < $1.id }) {
            if j.highs.contains(spob.id), NCBTest(j.buyOn).evaluate(state) { boughtHere = j }
            if j.lows.contains(spob.id), NCBTest(j.sellOn).evaluate(state) { soldHere = j }
        }
        if let j = boughtHere {
            rows.append(TradeRow(cargoID: j.id, level: .high,
                                 price: Int((Float(j.basePrice) * scale).rounded(.towardZero)), disaster: false))
        }
        if let j = soldHere {
            rows.append(TradeRow(cargoID: j.id, level: .low,
                                 price: Int((Float(j.basePrice) / scale).rounded(.towardZero)), disaster: false))
        }
        return rows
    }

    /// The price delta of each active disaster at `spobID`, the highest-id one
    /// winning per commodity (the original's last match).
    static func activeDisasterDeltas(at spobID: Int, state: PlayerState, game: NovaGame) -> [Commodity: Int] {
        var out: [Commodity: Int] = [:]
        for id in (state.activeDisasters ?? [:]).keys.sorted() {
            guard let o = game.oops(id), let c = o.commodityEnum,
                  disasterStellar(o, state: state) == spobID else { continue }
            out[c] = o.priceDelta
        }
        return out
    }

    /// Names of the disasters active at `spobID`, for the trade center's
    /// banner (the `öops` name doubles as its label).
    public static func activeDisasterNames(at spobID: Int, state: PlayerState, game: NovaGame) -> [String] {
        (state.activeDisasters ?? [:]).keys.sorted().compactMap { game.oops($0) }
            .filter { disasterStellar($0, state: state) == spobID }
            .map(\.name)
    }

    /// The trade center's status strip (0x0048d6f0, DITL item 12): a summary
    /// of the mission cargo and the junk not on the two junk rows ("#363 N
    /// tons #391 #367 #392 #368"), a blank line, then the player ship's free
    /// space ("#364 [#365]: N ton(s)") and — with freighter escorts — the
    /// escorts' ("#364 #366: N ton(s)"). Junk on `junkRows` is left out.
    public static func tradeStatus(state: PlayerState, game: NovaGame, shipCapacity own: Int,
                                   fleetCapacity fleet: Int, junkRows: Set<Int>) -> String {
        let text = OriginalText(game: game)
        func tons(_ n: Int) -> String { text.misc(n == 1 ? 1 : 2) }
        var missions = 0, missionTons = 0
        for am in state.activeMissions where am.isCarryingCargo {
            let type = am.resolvedCargoType ?? game.mission(am.missionID)?.cargoType ?? -1
            let qty = am.resolvedCargoQty ?? game.mission(am.missionID).map { abs($0.cargoQty) } ?? 0
            guard type != -1, qty >= 0 else { continue }
            missions += 1
            missionTons += qty
        }
        var junks = 0, junkTons = 0
        for (id, n) in state.cargo where id >= 128 && n > 0 && !junkRows.contains(id) {
            junks += 1
            junkTons += n
        }
        var s = ""
        if missions + junks > 0 {
            s += text.misc(0x16b) + " "
            let total = missionTons + junkTons
            if total > 0 { s += "\(total) \(tons(total)) " + text.misc(0x187) + " " }
            if missions > 0 {
                s += text.misc(0x16f)
                if junks > 0 { s += " " + text.misc(0x188) + " " }
            }
            if junks > 0 { s += text.misc(0x170) }
            s += "\r\r"
        }
        let used = state.usedCargoSpace
        s += text.misc(0x16c)
        if own < fleet { s += " " + text.misc(0x16d) }
        s += ": "
        var ownUsed = used
        if own < fleet { ownUsed = max(0, used - missionTons - (fleet - own)) + missionTons }
        let ownFree = max(0, own - ownUsed)
        s += "\(ownFree) \(tons(ownFree))"
        if own < fleet {
            let escortFree = max(0, fleet - used)
            s += "\r" + text.misc(0x16c) + " " + text.misc(0x16e) + ": \(escortFree) \(tons(escortFree))"
        }
        return s
    }

    /// The trade center's disaster line (0x0048d6f0, DITL item 15): the first
    /// active disaster at this stellar — "<name> #192 #193|#194 #181
    /// <commodity>." (#194 when it lowers the price). nil when none.
    public static func tradeDisasterLine(at spobID: Int, state: PlayerState, game: NovaGame) -> String? {
        let text = OriginalText(game: game)
        guard let o = (state.activeDisasters ?? [:]).keys.sorted().compactMap({ game.oops($0) })
            .first(where: { disasterStellar($0, state: state) == spobID }) else { return nil }
        let commodity = Commodity(rawValue: o.commodity).map { game.commodityName($0) } ?? ""
        return o.name + " " + text.misc(0xc0) + " " + text.misc(o.priceDelta < 1 ? 0xc2 : 0xc1)
            + " " + text.misc(0xb5) + " " + commodity + "."
    }

    /// Whether the disaster at `spobID` raised (true) or lowered (false) the
    /// price of trade row `cargoID`; nil without one (STR# 2002 #204 / #205).
    public static func disasterRaised(cargoID: Int, at spobID: Int, state: PlayerState, game: NovaGame) -> Bool? {
        for (c, delta) in activeDisasterDeltas(at: spobID, state: state, game: game) where c.cargoID == cargoID {
            return delta > 0
        }
        return nil
    }

    /// The stellar an active disaster affects: its own `Stellar`, or for
    /// `Stellar = −1` the one picked when it activated.
    public static func disasterStellar(_ o: OopsRes, state: PlayerState) -> Int? {
        if o.stellar >= 128 { return o.stellar }
        if o.stellar == -1 { return state.disasterStellars?[o.id] }
        return nil
    }

    /// Tons one trade-center click moves (0x0048c730): a plain click moves at
    /// most 10; the quantity prompt is capped at 32000. Buying is also capped by
    /// `trunc(credits / price)` and the free hold.
    public static func tradeQuantity(buying: Bool, prompted: Int?, credits: Int, price: Int,
                                     cargoFree: Int, held: Int) -> Int {
        if buying {
            guard price > 0, cargoFree > 0 else { return 0 }
            let affordable = credits / price
            if let prompted { return max(0, min(prompted, affordable, cargoFree, 32000)) }
            return max(0, min(10, affordable, cargoFree))
        }
        let limit = min(held, 32000)
        if let prompted { return max(0, min(prompted, limit)) }
        return max(0, min(10, limit))
    }

    // MARK: Landing (EC-04, EC-05)

    /// The outcome of asking to land, in the original's order (0x00457580).
    public enum LandingClearance: Equatable, Sendable {
        case granted
        /// "Landing request denied." (STR# 2002 #81–83)
        case denied
        /// The landing fee is more than the player has (STR# 2002 #61 + #62–64).
        case cannotPayFee(Int)
    }

    /// Whether the player may land on `spob` (0x00457580):
    /// - a fee > 0 at a stellar that is not dominated, with fewer credits than
    ///   the fee, refuses outright;
    /// - otherwise landing is cleared when the system reputation meets
    ///   `MinStatus` (or `MinStatus` is −32767, and never when it is 32767), the
    ///   stellar is dominated or uninhabited, or a bribe was accepted;
    /// - a failed government `Require` mask then denies;
    /// - being an active mission's travel or return stellar, or holding an
    ///   AlwaysLand rank (`ränk` 0x0200) with the stellar's government or an
    ///   ally, clears it again.
    public static func landingClearance(spob: SpobRes, system: Int, state: PlayerState, game: NovaGame,
                                        diplomacy: Diplomacy?, contributedBits: UInt64,
                                        bribed: Bool = false) -> LandingClearance {
        if spob.landingFee > 0, !isDominated(spob, state), state.credits < spob.landingFee {
            return .cannotPayFee(spob.landingFee)
        }
        let minStatus = spob.minStatus
        let rep = systemReputation(state, system: system, game: game)
        var cleared = (rep >= minStatus || minStatus == -32767) && minStatus != 32767
        // An uninhabited stellar clears itself as the player approaches.
        if isDominated(spob, state) || bribed || spob.isUninhabited { cleared = true }
        if spob.government >= 128, let govt = game.govt(spob.government),
           govt.require != 0, contributedBits & govt.require != govt.require {
            cleared = false
        }
        if !cleared {
            cleared = state.activeMissions.contains {
                $0.travelSpobID == spob.id || $0.returnSpobID == spob.id
            }
        }
        if !cleared, spob.government >= 128 {
            cleared = state.activeRanks.contains { rid in
                guard let r = game.rank(rid), r.canAlwaysLand, r.govt >= 128 else { return false }
                return r.govt == spob.government || (diplomacy?.areAllied(r.govt, spob.government) ?? false)
            }
        }
        return cleared ? .granted : .denied
    }

    /// The landing fee actually charged on touchdown: the full `spöb` fee, or
    /// nothing at a dominated stellar (0x00457580). The balance is clamped at 0.
    public static func landingFee(spob: SpobRes, state: PlayerState) -> Int {
        guard spob.landingFee > 0, !isDominated(spob, state) else { return 0 }
        return spob.landingFee
    }

    /// The HUD line for a refused landing, from STR# 2002.
    public static func refusalMessage(_ clearance: LandingClearance, spob: SpobRes, game: NovaGame) -> String? {
        let list = game.stringList(2002)
        func s(_ i: Int, _ fallback: String) -> String { list?.string(at: i) ?? fallback }
        switch clearance {
        case .granted:
            return nil
        case .denied:
            if spob.isHypergate { return s(81, "Hypergate usage denied.") }
            return spob.isStation ? s(82, "Docking request denied.") : s(83, "Landing request denied.")
        case .cannotPayFee:
            let currency = s(33, "credits")
            let tail: String
            if spob.isHypergate { tail = s(62, "to pay the hypergate fee.") }
            else if spob.isStation { tail = s(63, "to pay the docking fee.") }
            else { tail = s(64, "to pay the landing fee.") }
            return "\(s(61, "You don't have enough")) \(currency) \(tail)"
        }
    }

    // MARK: Refuel (EC-23)

    /// Fuel units the Refuel button buys, and their cost (0x00491f30 item 4).
    /// Nothing at an uninhabited stellar. Fuel truncates to whole units first;
    /// at a dominated stellar the top-up is free, otherwise it costs 1 credit a
    /// unit and stops when the credits run out.
    public static func refuel(fuel: Double, capacity: Int, credits: Int,
                              dominated: Bool, uninhabited: Bool) -> (fuel: Double, cost: Int)? {
        guard !uninhabited else { return nil }
        let whole = Double(Int(fuel))
        var need = max(0, Int(Double(capacity) - whole))
        if !dominated { need = min(need, max(0, credits)) }
        return (whole + Double(need), dominated ? 0 : need)
    }

    // MARK: Shipyard pricing (EC-09, EC-10)

    /// The rank price scale at a stellar of government `govt` (0x00491f30): the
    /// product of `PriceMod × 0.01` over every active rank whose government is
    /// allied with (or is) the stellar's, kept in single precision like the
    /// original. `PriceMod < 1` loads as 100. 1 at an ungoverned stellar.
    public static func rankPriceScale(_ state: PlayerState, stellarGovt govt: Int, game: NovaGame,
                                      diplomacy: Diplomacy?) -> Float {
        guard govt >= 128 else { return 1 }
        var scale: Float = 1
        for rid in state.activeRanks.sorted() {
            guard let r = game.rank(rid), r.govt >= 128 else { continue }
            guard r.govt == govt || (diplomacy?.areAllied(govt, r.govt) ?? false) else { continue }
            let mod = r.priceModifier < 1 ? 100 : r.priceModifier
            scale = Float(Double(mod) * 0.01 * Double(scale))
        }
        return scale
    }

    /// `Outfit_ComputeScaledPurchasePrice` 0x0049d640, the shipyard's price:
    /// a tech markdown of 3 % a level (only when both techs are below 6, the
    /// item's is lower, and the base is over 99), then the rank scale, then
    /// prices over 100 truncated to a multiple of 10 (≤ 10,000), 100
    /// (≤ 100,000) or 1000, never below 1. The products run in double precision
    /// on a single-precision scale, which the oracle pins (14,000 × 0.9 → 12,500).
    public static func scaledPurchasePrice(_ base: Int, scale: Float, itemTech: Int, stellarTech: Int) -> Int {
        guard base > 0 else { return 0 }
        var price = base
        if itemTech < 6, stellarTech < 6, itemTech < stellarTech, base > 99 {
            price = Int(Double(base) * Double(100 - 3 * (stellarTech - itemTech)) * 0.01)
        }
        price = Int(Double(price) * Double(scale))
        if price > 100_000 { price = price / 1000 * 1000 }
        else if price > 10_000 { price = price / 100 * 100 }
        else if price > 100 { price = price / 10 * 10 }
        return max(1, price)
    }

    /// `Ship_ComputeTradeInValue` 0x00469100 before scaling: a quarter of the
    /// hull's cost, plus half the purchase price of every owned outfit that does
    /// not stay with the player (`oütf` Flags 0x0004), truncating at each step.
    public static func rawTradeInValue(_ state: PlayerState, game: NovaGame) -> Int {
        guard let hull = game.ship(state.shipType) else { return 0 }
        var total = Int(Double(hull.cost) * 0.25)
        for (id, count) in state.outfits.sorted(by: { $0.key < $1.key }) where count > 0 {
            guard let o = game.outfit(id), o.flags & 0x0004 == 0 else { continue }
            total = Int(Double(total) + Double(count * o.effectiveCost(shipMass: hull.mass)) * 0.5)
        }
        return max(0, total)
    }

    /// The shipyard's credit for the current ship: `rawTradeInValue` run through
    /// `scaledPurchasePrice` twice with the current hull's tech (0x00492f30).
    public static func tradeInValue(_ state: PlayerState, game: NovaGame, scale: Float, stellarTech: Int) -> Int {
        let tech = game.ship(state.shipType)?.techLevel ?? 0
        let once = scaledPurchasePrice(rawTradeInValue(state, game: game), scale: scale,
                                       itemTech: tech, stellarTech: stellarTech)
        return scaledPurchasePrice(once, scale: scale, itemTech: tech, stellarTech: stellarTech)
    }

    /// The shipyard price of `ship` at a stellar of tech `stellarTech`.
    public static func shipPrice(_ ship: ShipRes, scale: Float, stellarTech: Int) -> Int {
        scaledPurchasePrice(ship.cost, scale: scale, itemTech: ship.techLevel, stellarTech: stellarTech)
    }

    /// The bar's hire price: a tenth of the scaled shipyard price (0x00492f30).
    public static func hirePrice(_ ship: ShipRes, scale: Float, stellarTech: Int) -> Int {
        Int(Double(shipPrice(ship, scale: scale, stellarTech: stellarTech)) * 0.1)
    }

    // MARK: Planetary bribe (EC-25)

    /// The bribe a stellar asks when its comm window opens (0x00480030):
    /// `cost = Rand(max(1, trunc(credits × 1e-6))) × 1000 + 3000`, × 1.5
    /// (truncated) for government Flags 0x8000, capped at `trunc(credits × 0.333)`,
    /// floored to a multiple of 1000 and clamped to [1000, 900000]. `rand(n)`
    /// draws `0..<n`.
    public static func planetaryBribeCost(credits: Int, govtFlags: UInt16, rand: (Int) -> Int) -> Int {
        let n = max(1, Int(Double(credits) * 1e-6))
        var cost = rand(n) * 1000 + 3000
        if govtFlags & 0x8000 != 0 { cost = Int(Double(cost) * 1.5) }
        cost = min(cost, Int(Double(credits) * 0.333))
        cost = cost / 1000 * 1000
        return min(900_000, max(1000, cost))
    }

    /// Whether a stellar takes bribes at all: governments with Flags 0x8000
    /// always do; otherwise the per-jump latch roll must exceed 30 and the
    /// stellar be ungoverned or its government carry Flags 0x4000.
    public static func stellarTakesBribes(govt: GovtRes?, latchRoll: Int) -> Bool {
        if let govt, govt.flags1 & 0x8000 != 0 { return true }
        guard latchRoll > 30 else { return false }
        guard let govt else { return true }
        return govt.flags1 & 0x4000 != 0
    }

    // MARK: Bar gambling (EC-26)

    /// The bar's Galaxy Racing Network bet (`FUN_0047dc50`). The wager is
    /// `min(credits, 1000)`, or an amount the player types (at most
    /// `min(credits, 10000)`) with the modifier key. The race rolls `rand(4)`;
    /// when that matches the previous race's winner it re-rolls until it
    /// differs from both that winner and the player's pick, so the bet is lost.
    /// A win pays four times the wager (STR# 2002 #370).
    public struct RaceBet: Sendable, Equatable {
        /// The previous race's winner (0–3), −1 before the first race.
        public var lastWinner = -1

        public init() {}

        public static func standardWager(credits: Int) -> Int { min(max(0, credits), 1000) }
        public static func maxPromptedWager(credits: Int) -> Int { min(max(0, credits), 10000) }

        /// Runs one race on `pick` (0–3) with `wager` already validated; returns
        /// the winner and the credits paid back (0 on a loss).
        public mutating func race(pick: Int, wager: Int, rand: (Int) -> Int) -> (winner: Int, payout: Int) {
            var winner = rand(4)
            if winner == lastWinner {
                repeat { winner = rand(4) } while winner == lastWinner || winner == pick
            }
            lastWinner = winner
            return (winner, winner == pick ? wager * 4 : 0)
        }
    }
}
