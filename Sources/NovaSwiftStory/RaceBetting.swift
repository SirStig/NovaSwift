import Foundation
import NovaSwiftKit

/// The bar's Gambling screen as plain logic: the "Galaxy Racing Network" holovid
/// race (`FUN_0047dc50`, EC-26) the Apple `GamblingView` drives. The odds live in
/// `LandedServices.RaceBet`; this adds the four contestant colours, their art
/// ids and the session that remembers the previous winner (the original keeps it
/// in a global that is not saved) so every frontend plays the same game.
public enum RaceColor: Int, CaseIterable, Sendable {
    case blue = 1, green = 2, yellow = 3, red = 4

    /// 0-based pick/winner index as `RaceBet` uses it (blue 0 … red 3).
    public var index: Int { rawValue - 1 }
    public init?(index: Int) { self.init(rawValue: index + 1) }

    public var name: String {
        switch self {
        case .blue: return "Blue"
        case .green: return "Green"
        case .yellow: return "Yellow"
        case .red: return "Red"
        }
    }

    /// The colour button's PICT: 8530+ idle, 8540+ chosen (also the pick echo on
    /// the result), 8550+ "<Color> Wins", 8560+ disabled.
    public var idlePictID: Int { 8530 + index }
    public var chosenPictID: Int { 8540 + index }
    public var winPictID: Int { 8550 + index }
    public var losePictID: Int { 8560 + index }

    /// The chooser backdrop ("You're tuned to GRN …").
    public static let chooserPictID = 8529
    /// The holovid clip for a race the colour wins: `Race <n>.mov`.
    public var clipName: String { "Race \(rawValue).mov" }
}

/// One session of bets. Value-type state plus a stake/payout ledger so a front
/// end can charge on the bet and pay on the finish the way the Apple view does.
public struct RaceSession: Sendable, Equatable {
    public var bet = LandedServices.RaceBet()

    public init() {}

    public struct Outcome: Sendable, Equatable {
        public var pick: RaceColor
        public var winner: RaceColor
        public var stake: Int
        /// Credits paid back: four times the stake on a win, else 0.
        public var payout: Int
        public var won: Bool { payout > 0 }
        /// Net credits change for the player (payout − stake).
        public var net: Int { payout - stake }
    }

    /// Whether a wager of `amount` may be placed with `credits` in hand.
    public static func canBet(amount: Int, credits: Int) -> Bool { amount > 0 && credits >= amount }

    /// Place a bet on `pick` for `amount`: the stake leaves `credits` and the
    /// race result (and its winnings) is returned and applied, so the player's
    /// balance is `credits − stake + payout` when this returns. nil when the bet
    /// isn't allowed (nothing is charged). `rand` is `Int.random(in: 0..<n)` in play.
    @discardableResult
    public mutating func place(pick: RaceColor, amount: Int, credits: inout Int,
                               rand: (Int) -> Int) -> Outcome? {
        guard Self.canBet(amount: amount, credits: credits) else { return nil }
        credits -= amount
        let race = bet.race(pick: pick.index, wager: amount, rand: rand)
        credits += race.payout
        return Outcome(pick: pick, winner: RaceColor(index: race.winner) ?? .blue, stake: amount, payout: race.payout)
    }
}
