import Foundation
import NovaSwiftKit
import NovaSwiftEngine

/// The spaceport bar's **Hire Escort** browser as plain logic — the list, price
/// and hire gate the Apple `HireEscortView` computes inline, extracted so the
/// Godot frontend (and any other) shows exactly the same ships at the same price.
///
/// Which hulls are on offer today is the shipyard list in hire mode (0x00469e90):
/// tech and SpecialTech, the day's `HireRandom` roll (one galaxy-wide roll per
/// class per day, redrawn when that class is hired), the Flags3 hides, then
/// DispWeight order — at any stellar with a bar, shipyard or not. Hiring charges
/// a tenth of the scaled shipyard price (EC-09) and then a recurring daily fee.
public enum EscortHire {

    /// Ships offered for hire at `spob` today (`state.date.julianDay`).
    public static func stock(game: NovaGame, spob: SpobRes, state: PlayerState) -> [ShipRes] {
        let day = state.date.julianDay
        return game.shipyardList(
            at: spob, hire: true,
            stocked: { PilotEconomy.escortAvailableToday(state, $0, day: day) },
            availabilityPasses: { NCBTest($0.availBits).evaluate(state) },
            requirePasses: { ($0.require & game.contributedBits(pilot: state)) == $0.require })
    }

    /// The hire price at `spob` for this pilot's rank (the shipyard's price scale).
    public static func price(_ ship: ShipRes, state: PlayerState, spob: SpobRes, galaxy: Galaxy) -> Int {
        PilotEconomy.escortHirePrice(ship, scale: SpaceportShops.rankPriceScale(state, at: spob, galaxy: galaxy),
                                     stellarTech: spob.techLevel)
    }

    /// Whether the Hire button is live: the credits and the Availability test
    /// only (Require gates buying, not hiring, 0x00498dc0) and room in the wing.
    public static func canHire(_ ship: ShipRes, state: PlayerState, spob: SpobRes, galaxy: Galaxy) -> Bool {
        state.credits >= price(ship, state: state, spob: spob, galaxy: galaxy)
            && NCBTest(ship.availBits).evaluate(state)
            && PilotEconomy.canAddEscort(state)
    }

    /// Hire `ship`: charge the price, register a `.hired` escort that joins on
    /// takeoff, redraw the class's roll. False if not on offer, wing full or
    /// unaffordable.
    @discardableResult
    public static func hire(_ state: inout PlayerState, _ ship: ShipRes, spob: SpobRes, galaxy: Galaxy) -> Bool {
        guard canHire(ship, state: state, spob: spob, galaxy: galaxy) else { return false }
        return PilotEconomy.hireEscort(&state, ship, day: state.date.julianDay,
                                       scale: SpaceportShops.rankPriceScale(state, at: spob, galaxy: galaxy),
                                       stellarTech: spob.techLevel)
    }

    public static func categoryLabel(_ category: Int) -> String {
        switch category {
        case 0: return "Fighter"
        case 1: return "Medium Ship"
        case 2: return "Warship"
        case 3: return "Freighter"
        default: return "Escort"
        }
    }

    /// The ship's pilot description (`dësc` 14000-range, "shown in the
    /// hire-escort dialog"), falling back to the class description (13000-range).
    public static func pilotDescription(_ ship: ShipRes, game: NovaGame) -> String {
        let pilot = game.descText(14000 + ship.id - 128)
        return pilot.isEmpty ? game.descText(13000 + ship.id - 128) : pilot
    }
}
