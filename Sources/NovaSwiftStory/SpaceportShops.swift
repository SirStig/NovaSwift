import Foundation
import NovaSwiftKit
import NovaSwiftEngine

/// What the Outfitter and Shipyard list and whether each entry can be bought —
/// the decisions both frontends (the Apple SwiftUI spaceport and the Godot one)
/// must agree on. Lifted out of `OutfitterView`/`ShipyardView`
/// (app/NovaSwift/Spaceport/SpaceportScreens.swift) so neither reimplements
/// them; the Apple views are now thin callers. Pricing and the transactions
/// themselves stay in `PilotEconomy` / `LandedServices`.
public enum SpaceportShops {

    // MARK: Outfitter

    /// The outfitter's list as 0x0046a220 builds it: tech-eligible,
    /// `BuyRandom`-rolled stock for today, with Availability / Require hiding
    /// (Flags 0x4000 / 0x0100) applied only to what the player doesn't own,
    /// owned outfits the port buys back merged in (spöb Flags2 0x0400, oütf
    /// Flags 0x0800), then Flags 0x1000 suppression and the DispWeight sort.
    /// `owned` is normally `state.outfits`; pass `[:]` for the for-sale-only list.
    public static func outfitList(game: NovaGame, spob: SpobRes, state: PlayerState,
                                  diplomacy: Diplomacy, owned: [Int: Int]) -> [OutfRes] {
        game.outfitList(at: spob, day: state.date.julianDay, owned: owned,
                        availabilityPasses: { game.outfitAvailabilityPasses($0, pilot: state) },
                        requirePasses: { game.outfitRequirePasses($0, pilot: state, at: spob,
                                                                  diplomacy: diplomacy) })
    }

    /// Outfits listed for sell-back only — they can be sold here but never bought.
    public static func outfitSellOnlyIDs(game: NovaGame, spob: SpobRes, state: PlayerState,
                                         diplomacy: Diplomacy) -> Set<Int> {
        let forSale = Set(outfitList(game: game, spob: spob, state: state, diplomacy: diplomacy, owned: [:]).map(\.id))
        let listed = Set(outfitList(game: game, spob: spob, state: state, diplomacy: diplomacy,
                                    owned: state.outfits).map(\.id))
        return listed.subtracting(forSale)
    }

    /// The Buy button's enabled state: not a sell-only listing, passes every
    /// `PilotEconomy.canBuyOutfit` rule (credits, mass, max-installed, ammo cap,
    /// mounts, mass-expansion rules) and is not locked behind Availability/Require.
    public static func canBuyOutfit(_ o: OutfRes, game: NovaGame, galaxy: Galaxy, spob: SpobRes,
                                    state: PlayerState, diplomacy: Diplomacy, sellOnly: Set<Int>) -> Bool {
        !sellOnly.contains(o.id)
            && PilotEconomy.canBuyOutfit(state, o, galaxy: galaxy)
            && game.lockState(for: o, pilot: state, at: spob, diplomacy: diplomacy) == .available
    }

    // MARK: Shipyard

    /// Tech-level-eligible stock on today's galaxy-wide `BuyRandom` roll (a
    /// purchase redraws its class), with any hulls that opt into full hiding
    /// (Bible `shïp.Flags3` 0x0100/0x0200) dropped when the player doesn't meet
    /// their Availability/Require and doesn't already fly one.
    public static func shipyardList(game: NovaGame, spob: SpobRes, state: PlayerState) -> [ShipRes] {
        let day = state.date.julianDay
        guard spob.hasShipyard else { return [] }
        return game.shipyardList(
            at: spob, hire: false,
            stocked: { s in
                NovaGame.stocked(buyRandom: s.buyRandom,
                                 roll: NovaGame.dailyStockRoll(day: day, itemID: s.id, salt: 1,
                                                               redraw: state.stockRerollCount(shipType: s.id, hire: false, day: day)))
            },
            availabilityPasses: { NCBTest($0.availBits).evaluate(state) },
            requirePasses: { ($0.require & game.contributedBits(pilot: state)) == $0.require })
    }

    /// The rank price scale at `spob` (ships, trade-ins and hires; EC-10).
    public static func rankPriceScale(_ state: PlayerState, at spob: SpobRes, galaxy: Galaxy) -> Float {
        LandedServices.rankPriceScale(state, stellarGovt: spob.government, game: galaxy.game,
                                      diplomacy: galaxy.makeDiplomacy())
    }

    /// The credit the shipyard gives for the current ship here (EC-09).
    public static func tradeInValue(_ state: PlayerState, at spob: SpobRes, galaxy: Galaxy) -> Int {
        PilotEconomy.tradeInValue(state, game: galaxy.game,
                                  scale: rankPriceScale(state, at: spob, galaxy: galaxy), stellarTech: spob.techLevel)
    }

    /// The net price of `ship` here: its price after the tech markdown, rank
    /// scale and rounding, less the trade-in.
    public static func netPrice(_ state: PlayerState, of ship: ShipRes, at spob: SpobRes, galaxy: Galaxy) -> Int {
        PilotEconomy.netPrice(state, of: ship, game: galaxy.game,
                              scale: rankPriceScale(state, at: spob, galaxy: galaxy), stellarTech: spob.techLevel)
    }

    /// Buy `ship` here (0x00492f30) — `PilotEconomy.buyShip` at this port's rank
    /// scale and tech level.
    @discardableResult
    public static func buyShip(_ state: inout PlayerState, _ ship: ShipRes, at spob: SpobRes, galaxy: Galaxy,
                                rolled: Bool = false) -> Bool {
        PilotEconomy.buyShip(&state, ship, game: galaxy.game,
                             scale: rankPriceScale(state, at: spob, galaxy: galaxy), stellarTech: spob.techLevel,
                             rolled: rolled)
    }

    /// Buy Ship's enabled state: not the hull already flown, affordable at the
    /// net price, not locked behind Availability/Require.
    public static func canBuyShip(_ ship: ShipRes, game: NovaGame, galaxy: Galaxy, spob: SpobRes,
                                  state: PlayerState) -> Bool {
        ship.id != state.shipType
            && state.credits >= netPrice(state, of: ship, at: spob, galaxy: galaxy)
            && game.lockState(for: ship, pilot: state) == .available
    }

    /// Ship class descriptions live at `dësc` 13000–13767, one per hull, indexed
    /// from the first ship id (the second-hand hulls explain themselves there).
    public static func classDescription(_ ship: ShipRes, game: NovaGame) -> String {
        game.descText(13000 + ship.id - 128)
    }

    /// The hull's built-in armament, "N × name" per weapon (a lone unit is just
    /// the name), ordered by id.
    public static func standardWeapons(_ ship: ShipRes, game: NovaGame) -> [String] {
        aggregate(ship.weapons.map { (id: $0.id, count: $0.count) }) { game.weapon($0)?.name.novaDisplayName }
    }

    /// The hull's preinstalled outfits, formatted like `standardWeapons`.
    public static func standardOutfits(_ ship: ShipRes, game: NovaGame) -> [String] {
        aggregate(ship.outfits.map { (id: $0.id, count: $0.count) }) { game.outfit($0)?.displayName }
    }

    private static func aggregate(_ items: [(id: Int, count: Int)], name: (Int) -> String?) -> [String] {
        var counts: [Int: Int] = [:]
        for item in items where item.count > 0 { counts[item.id, default: 0] += item.count }
        return counts.sorted { $0.key < $1.key }.map { id, n in
            let label = name(id) ?? "#\(id)"
            return n > 1 ? "\(n) × \(label)" : label
        }
    }

    // MARK: Refuel (EC-23)

    /// The tank's capacity; nil when the hull has no loadout.
    public static func maxFuel(_ state: PlayerState, galaxy: Galaxy) -> Double? {
        PilotEconomy.loadout(state, galaxy: galaxy)?.maxFuel
    }

    /// Current fuel; a nil saved level (new pilot / never spent) reads as full.
    public static func currentFuel(_ state: PlayerState, galaxy: Galaxy) -> Double {
        state.fuel ?? (maxFuel(state, galaxy: galaxy) ?? 0)
    }

    /// The Recharge button shows only at an inhabited port, and only when the
    /// tank has room.
    public static func needsRecharge(_ state: PlayerState, spob: SpobRes, galaxy: Galaxy) -> Bool {
        guard !spob.isUninhabited, let maxFuel = maxFuel(state, galaxy: galaxy) else { return false }
        return currentFuel(state, galaxy: galaxy) < maxFuel - 0.5
    }

    /// The Recharge button (0x00491f30 item 4): whole fuel units at 1 credit
    /// each, as many as the credits cover, or a free top-up at a dominated
    /// stellar. Returns the credits spent, or nil when nothing was done.
    @discardableResult
    public static func recharge(_ state: inout PlayerState, spob: SpobRes, galaxy: Galaxy) -> Int? {
        guard let maxFuel = maxFuel(state, galaxy: galaxy),
              let fill = LandedServices.refuel(fuel: currentFuel(state, galaxy: galaxy), capacity: Int(maxFuel),
                                               credits: state.credits, dominated: state.hasDominated(spob.id),
                                               uninhabited: spob.isUninhabited) else { return nil }
        state.credits -= fill.cost
        state.fuel = fill.fuel
        return fill.cost
    }

    /// The auto-refueller (`oütf` ModType 19; `Player_RefuelShipWithCredits`
    /// 0x004250f0), run on docking: the same 1 credit a unit as the button,
    /// buying as many whole units as the credits cover, no dominated waiver.
    /// Skipped at an uninhabited stellar. Returns the credits spent, or nil.
    @discardableResult
    public static func autoRecharge(_ state: inout PlayerState, spob: SpobRes, galaxy: Galaxy) -> Int? {
        guard !spob.isUninhabited,
              PilotEconomy.loadout(state, galaxy: galaxy)?.hasAutoRefuel == true,
              let maxFuel = maxFuel(state, galaxy: galaxy) else { return nil }
        let current = currentFuel(state, galaxy: galaxy)
        guard let fill = LandedServices.refuel(fuel: current, capacity: Int(maxFuel), credits: state.credits,
                                               dominated: false, uninhabited: false),
              fill.fuel > current else { return nil }
        state.credits -= fill.cost
        state.fuel = fill.fuel
        return fill.cost
    }
}
