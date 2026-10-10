import Foundation
import NovaSwiftKit
import NovaSwiftEngine

/// One stellar comm window (`NovaUi_RunTravelDestinationInteractionWindow`
/// 0x00480030, UI-09): its opening line, status, the Greetings / Offer Bribe
/// button (EC-25) and what Demand Tribute / Release say (EC-16). The frontend
/// owns the dialog; this is the original's state and text for it.
public struct StellarComm: Sendable {
    public let spobID: Int
    /// Landing would be refused: `MinStatus` 32767, or the system reputation
    /// below `MinStatus` (unless it is −32767), cleared by an AlwaysLand rank
    /// with the stellar's government or an ally.
    public let denied: Bool
    /// The stellar takes a bribe this time (see `LandedServices.stellarTakesBribes`).
    public var bribable: Bool
    /// The price asked, rolled when the window opened (and raised 1000 by a
    /// refusal).
    public var bribePrice: Int
    /// The original picks one of five phrasings per window (`rand(5)`).
    public let variant: Int
    /// Demand Tribute was pressed in this window — only the first press can
    /// win a stellar with nothing left to fight.
    public var tributePressed = false

    /// The window for `spob`, or nil when hailing it gets no window — an
    /// uninhabited stellar (Flags 0x20) or a gate just beeps "No response."
    /// `bribeLatch` is the per-jump `Rand(100)` latch (−1 until rolled).
    public static func open(spob: SpobRes, system: Int, state: PlayerState, game: NovaGame,
                            diplomacy: Diplomacy?, bribeLatch: inout Int, rand: (Int) -> Int) -> StellarComm? {
        guard !spob.isUninhabited, !spob.isGate else { return nil }
        let variant = rand(5)
        let govt = spob.government >= 128 ? game.govt(spob.government) : nil
        let price = LandedServices.planetaryBribeCost(credits: state.credits, govtFlags: govt?.flags1 ?? 0, rand: rand)
        let rep = LandedServices.systemReputation(state, system: system, game: game)
        var denied = spob.minStatus == 32767 || (rep < spob.minStatus && spob.minStatus != -32767)
        if denied, spob.government >= 128 {
            let alwaysLand = state.activeRanks.contains { rid in
                guard let r = game.rank(rid), r.canAlwaysLand, r.govt >= 128 else { return false }
                return r.govt == spob.government || (diplomacy?.areAllied(r.govt, spob.government) ?? false)
            }
            if alwaysLand { denied = false }
        }
        if bribeLatch < 0 { bribeLatch = rand(100) }
        return StellarComm(spobID: spob.id, denied: denied,
                           bribable: LandedServices.stellarTakesBribes(govt: govt, latchRoll: bribeLatch),
                           bribePrice: price, variant: variant)
    }

    /// STR# 3002 entry `prompt × 5 + variant + 1`.
    func stellarLine(_ prompt: Int, _ game: NovaGame) -> String {
        game.stringList(3002)?.string(at: prompt * 5 + variant + 1) ?? ""
    }

    /// STR# 3000 entry `prompt × 5 + variant + 1`.
    func shipLine(_ prompt: Int, _ game: NovaGame) -> String {
        game.stringList(3000)?.string(at: prompt * 5 + variant + 1) ?? ""
    }

    /// The opening line: "Communications channel open to <name>." when
    /// landing is open or the stellar is ours, else a curt "What do you want?".
    public func openingText(spob: SpobRes, state: PlayerState, game: NovaGame) -> String {
        if !denied || state.hasDominated(spob.id) { return stellarLine(0, game) + spob.name + "." }
        return shipLine(2, game)
    }

    /// The status line under the name: "Status: Dominated/Owned" for a world
    /// the player holds, "Status: Hostile" (red, negative reputation) or
    /// "Forbidden" when landing is refused, nothing otherwise.
    public func status(spob: SpobRes, system: Int, state: PlayerState, game: NovaGame) -> (text: String, hostile: Bool)? {
        let list = game.stringList(2002)
        let label = list?.string(at: 196) ?? "Status:"
        if state.hasDominated(spob.id) {
            let word = spob.startsDominated ? (list?.string(at: 171) ?? "Owned") : (list?.string(at: 172) ?? "Dominated")
            return ("\(label) \(word)", false)
        }
        guard denied else { return nil }
        if LandedServices.systemReputation(state, system: system, game: game) < 0 {
            return ("\(label) \(list?.string(at: 174) ?? "Hostile")", true)
        }
        return ("\(label) \(list?.string(at: 173) ?? "Forbidden")", false)
    }

    /// The stellar's class blurb (`STR ` 7000 + graphic, else STR# 1100 entry
    /// graphic + 1), shown under its name.
    public static func classFragment(spob: SpobRes, game: NovaGame) -> String {
        guard let data = game.resources.resource(NovaType.spob, spob.id)?.data, data.count >= 6 else { return "" }
        let graphic = Int(Int16(bitPattern: UInt16(data[data.startIndex + 4]) << 8 | UInt16(data[data.startIndex + 5])))
        return game.singleString(graphic + 7000) ?? game.stringList(1100)?.string(at: graphic + 1) ?? ""
    }

    /// What pressing the top button does.
    public enum GreetingsAction: Equatable, Sendable {
        /// A reply line and nothing else.
        case reply(String)
        /// "We'll let you slip by…": open the payment window at this price.
        case offerBribe(prompt: String, price: Int)
    }

    /// Greetings (landing open) or Offer Bribe (landing refused).
    public func greetings(spob: SpobRes, state: PlayerState, game: NovaGame) -> GreetingsAction {
        if !denied { return .reply(shipLine(9, game)) }
        if state.hasDominated(spob.id) { return .reply(stellarLine(4, game)) }
        guard bribable else { return .reply(stellarLine(9, game)) }
        return .offerBribe(prompt: stellarLine(8, game), price: bribePrice)
    }

    /// The bribe's outcome after the payment window closes. Too few credits
    /// for the (possibly haggled) price answers "Stop wasting our time" and
    /// changes nothing; a payment grants landing; a refusal or a failed haggle
    /// ends bribes until the next jump (the latch drops to 0) and raises this
    /// window's price by 1000.
    public enum BribeOutcome: Equatable, Sendable {
        case cannotAfford(String)
        case paid(price: Int, hudLine: String)
        case refused(String)
    }

    public mutating func settleBribe(paid: Bool, price: Int, spob: SpobRes, state: inout PlayerState,
                                     game: NovaGame, bribeLatch: inout Int) -> BribeOutcome {
        if state.credits < price { return .cannotAfford(stellarLine(4, game)) }
        bribable = false
        if paid {
            state.credits -= price
            let list = game.stringList(2002)
            let cleared = spob.isStation ? (list?.string(at: 95) ?? "you're cleared to dock.")
                                         : (list?.string(at: 98) ?? "you're cleared to land.")
            let tail = list?.string(at: 100) ?? "Commence final approach."
            return .paid(price: price, hudLine: "\(state.pilotName), \(cleared) \(tail)")
        }
        bribeLatch = 0
        bribePrice += 1000
        return .refused(stellarLine(6, game))
    }

    /// The reply to Demand Tribute, from the engine's outcome.
    public func tributeReply(_ outcome: TributeOutcome, spob: SpobRes, game: NovaGame) -> String {
        switch outcome {
        case .refused(.combatRatingTooLow):
            return stellarLine(1, game)
        case .dominated:
            return game.stringList(3002)?.string(at: spob.isStation ? 27 : 26) ?? ""
        case .defending, .stillDefending:
            return stellarLine(2, game)
        case .refused:
            return ""
        }
    }

    /// The line shown on Release.
    public static func releaseReply(spob: SpobRes, game: NovaGame) -> String {
        game.stringList(3002)?.string(at: spob.isStation ? 37 : 36) ?? ""
    }
}

/// The payment window shared by planetary bribes, ship bribes and Request
/// Assistance (`FUN_00482280`, DLOG 1008). When it opens it rolls whether a
/// haggle will work (`Rand(100) ≤ 35`). Paying accepts the price; haggling
/// once, if the roll allowed it, lowers the price to `trunc(price × 0.75)`
/// rounded down to the hundred and keeps the window open — any other haggle
/// press ends the deal.
public struct PaymentWindow: Sendable, Equatable {
    public private(set) var price: Int
    public private(set) var haggleWorks: Bool

    public enum Press: Equatable, Sendable { case pay, haggle }
    public enum Result: Equatable, Sendable { case open, paid, refused }

    public init(price: Int, rand: (Int) -> Int) {
        self.price = price
        haggleWorks = rand(100) <= 35
    }

    /// The original's line: "Pay us <price> credits."
    public static func prompt(price: Int, game: NovaGame) -> String {
        let list = game.stringList(2002)
        let unit = price < 2 ? (list?.string(at: 32) ?? "credit") : (list?.string(at: 33) ?? "credits")
        return "\(list?.string(at: 188) ?? "Pay us") \(price) \(unit)."
    }

    public mutating func press(_ press: Press) -> Result {
        switch press {
        case .pay:
            return .paid
        case .haggle:
            guard haggleWorks else { return .refused }
            price = Int(Double(Int(Double(price) * 0.75)) * 0.01) * 100
            haggleWorks = false
            return .open
        }
    }
}
