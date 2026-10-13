import XCTest
import Foundation
import NovaSwiftKit
import NovaSwiftEngine
@testable import NovaSwiftStory

/// FIDELITY_PLAN.md EC-07, EC-09, EC-11, EC-26, EC-27, EC-28 and MS-19: the
/// outfitter's sell refusals, the weapon bank, the shipyard roll, the bar's race
/// memory, cargo overflow, the visit-long latches and the random cargo quantity.
final class ShopVisitFidelityTests: XCTestCase {

    // MARK: Builders

    /// An `oütf` with up to four modifiers (type, value), a Max and Flags.
    private func outfit(_ id: Int, mass: Int = 0, cost: Int = 0, max: Int = 0, flags: Int = 0,
                        mods: [(Int, Int)] = []) -> Resource {
        var b = [UInt8](repeating: 0, count: 1012)
        Bytes.i16(&b, 2, mass)
        Bytes.i16(&b, 10, max)
        Bytes.i16(&b, 12, flags)
        Bytes.i32(&b, 14, cost)
        let slots = [6, 18, 22, 26]
        for p in slots { Bytes.i16(&b, p, -1) }
        for (i, m) in mods.prefix(4).enumerated() {
            Bytes.i16(&b, slots[i], m.0)
            Bytes.i16(&b, slots[i] + 2, m.1)
        }
        return Resource(type: NovaType.outfit, id: id, name: "Outfit \(id)", data: Data(b))
    }

    private func launcher(_ id: Int, maxAmmo: Int, ammoType: Int) -> Resource {
        var b = [UInt8](weaponResource(id: id, name: "Launcher").data)
        Bytes.i16(&b, 12, ammoType)
        Bytes.i16(&b, 108, maxAmmo)
        return Resource(type: NovaType.weapon, id: id, name: "Launcher", data: Data(b))
    }

    // MARK: MS-19

    func testRandomCargoQuantityUsesFloorOfHalf() {
        let game = makeGame([shipResource(id: 128, cargo: 100)])
        let eng = StoryEngine(game: game, player: PlayerState(shipType: 128, currentSystem: 128), seed: 7)
        var seen5 = Set<Int>(), seen10 = Set<Int>()
        for _ in 0..<600 { seen5.insert(eng.specialCount(-5)); seen10.insert(eng.specialCount(-10)) }
        XCTAssertEqual(seen5.min(), 2); XCTAssertEqual(seen5.max(), 6, "CargoQty -5 is 2...6")
        XCTAssertEqual(seen10.min(), 5); XCTAssertEqual(seen10.max(), 14, "CargoQty -10 is still 5...14")
        XCTAssertEqual(eng.specialCount(-1), 0)
        XCTAssertEqual(eng.specialCount(9), 9)
    }

    // MARK: EC-09 · the weapon bank

    private func bankGame() -> NovaGame {
        makeGame([
            shipResource(id: 128, cargo: 10, freeMass: 20, stockWeapons: [(id: 300, count: 1, ammo: 0)], maxGuns: 2),
            shipResource(id: 129, cargo: 5, freeMass: 40, defaultItems: [(id: 210, count: 1)],
                         stockWeapons: [(id: 301, count: 1, ammo: 0)], maxGuns: 2),
            weaponResource(id: 300, name: "Blaster"), weaponResource(id: 301, name: "Cannon"),
            outfitResource(id: 200, name: "Blaster", mass: 3, cost: 5000, installsWeapon: 300, isFixedGun: true),
            outfitResource(id: 201, name: "Cannon", mass: 3, cost: 8000, installsWeapon: 301, isFixedGun: true),
            outfitResource(id: 210, name: "Booster", mass: 4, cost: 9000),
        ])
    }

    func testStockWeaponIsBankedNotOwnedUntilTheOutfitterOpens() {
        let game = bankGame()
        var p = PlayerState(shipType: 128, currentSystem: 128)
        PilotEconomy.grantHullFittings(&p, ship: game.ship(128)!, game: game)
        XCTAssertEqual(p.outfits[200], 1, "it still flies (the loadout reads outfits)")
        XCTAssertEqual(p.stockBank?[200], 1)
        XCTAssertEqual(PilotEconomy.owned(p, outfit: 200), 0, "but it is not an owned outfit")
        XCTAssertFalse(PilotEconomy.canSellOutfit(p, game.outfit(200)!))
        XCTAssertEqual(LandedServices.rawTradeInValue(p, game: game), 0, "no 50 % trade-in credit yet")
        PilotEconomy.openOutfitter(&p)
        XCTAssertNil(p.stockBank)
        XCTAssertEqual(PilotEconomy.owned(p, outfit: 200), 1)
        XCTAssertEqual(LandedServices.rawTradeInValue(p, game: game), 2500)
    }

    func testDefaultItemsAreOwnedAtOnceAndAPurchaseRebanksTheNewHull() {
        let game = bankGame()
        var p = PlayerState(shipType: 128, credits: 1_000_000, currentSystem: 128)
        PilotEconomy.grantHullFittings(&p, ship: game.ship(128)!, game: game)
        XCTAssertTrue(PilotEconomy.buyShip(&p, game.ship(129)!, game: game))
        XCTAssertEqual(PilotEconomy.owned(p, outfit: 210), 1, "DefaultItems are owned immediately")
        XCTAssertEqual(PilotEconomy.owned(p, outfit: 201), 0)
        XCTAssertEqual(p.stockBank, [201: 1])
        XCTAssertNil(p.outfits[200], "the old hull's blaster went with the trade-in")
    }

    func testPilotsSavedBeforeTheBankStillOwnEverything() throws {
        var old = PlayerState(shipType: 128)
        old.outfits = [200: 1]
        var dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        dict.removeValue(forKey: "stockBank")
        let decoded = try JSONDecoder().decode(PlayerState.self, from: JSONSerialization.data(withJSONObject: dict))
        XCTAssertNil(decoded.stockBank)
        XCTAssertEqual(decoded.ownedCount(200), 1)
        var fresh = decoded
        fresh.stockBank = [200: 1]
        let back = try JSONDecoder().decode(PlayerState.self, from: JSONEncoder().encode(fresh))
        XCTAssertEqual(back.stockBank, [200: 1], "the bank round-trips")
    }

    // MARK: EC-07 · sell refusals

    func testSellingTheLastExpanderWhileTheTargetIsOverTheNewCapIsRefused() {
        let game = makeGame([
            shipResource(id: 128, cargo: 10, freeMass: 100),
            outfit(600, cost: 100, mods: [(27, 601)]), outfit(601, cost: 100, max: 2),
        ])
        let galaxy = Galaxy(game: game)
        var p = PlayerState(shipType: 128)
        p.outfits = [600: 1, 601: 1]
        XCTAssertFalse(PilotEconomy.sellOutfit(&p, game.outfit(600)!, galaxy: galaxy), "1 > 0 x Max")
        p.outfits = [600: 2, 601: 2]
        XCTAssertTrue(PilotEconomy.sellOutfit(&p, game.outfit(600)!, galaxy: galaxy), "2 <= 1 x 2")
        XCTAssertFalse(PilotEconomy.sellOutfit(&p, game.outfit(600)!, galaxy: galaxy), "2 > 0 x 2")
    }

    func testNegativeMassOutfitCannotBeSoldFromAnOverMassShip() {
        let game = makeGame([
            shipResource(id: 128, cargo: 10, freeMass: 20),
            outfit(610, mass: -5, cost: 100), outfit(611, mass: 30, cost: 100),
        ])
        let galaxy = Galaxy(game: game)
        var p = PlayerState(shipType: 128)
        p.outfits = [610: 1, 611: 1]                 // 20 + 5 - 30 = -5: over mass
        XCTAssertFalse(PilotEconomy.sellOutfit(&p, game.outfit(610)!, galaxy: galaxy))
        p.outfits = [610: 1]                          // free mass 25: 25 - 5 stays >= 0
        XCTAssertTrue(PilotEconomy.sellOutfit(&p, game.outfit(610)!, galaxy: galaxy))
    }

    func testLauncherSaleThatLeavesTooManyRoundsIsRefused() {
        let game = makeGame([
            shipResource(id: 128, cargo: 10, freeMass: 100),
            launcher(400, maxAmmo: 4, ammoType: 5),
            outfit(620, cost: 100, mods: [(1, 400)]), outfit(621, cost: 10, mods: [(3, 133)]),
        ])
        let galaxy = Galaxy(game: game)
        var p = PlayerState(shipType: 128)
        p.outfits = [620: 1, 621: 3]
        XCTAssertFalse(PilotEconomy.sellOutfit(&p, game.outfit(620)!, galaxy: galaxy), "3 rounds, 0 launchers left")
        p.outfits = [620: 2, 621: 4]
        XCTAssertTrue(PilotEconomy.sellOutfit(&p, game.outfit(620)!, galaxy: galaxy), "4 rounds <= 1 x MaxAmmo 4")
    }

    // MARK: EC-11 · a cancelled ship purchase still redraws the roll

    func testStartingAShipPurchaseRedrawsTheClassRollEvenIfItFails() {
        let game = bankGame()
        var p = PlayerState(shipType: 128, credits: 0, currentSystem: 128)
        let ship = game.ship(129)!
        let day = p.date.julianDay
        XCTAssertEqual(p.stockRerollCount(shipType: 129, hire: false, day: day), 0)
        PilotEconomy.beginShipPurchase(&p, ship)
        XCTAssertEqual(p.stockRerollCount(shipType: 129, hire: false, day: day), 1)
        // The confirm is cancelled: nothing else changes, the redraw stands.
        XCTAssertEqual(p.shipType, 128)
        p.credits = 1_000_000
        XCTAssertTrue(PilotEconomy.buyShip(&p, ship, game: game, rolled: true))
        XCTAssertEqual(p.stockRerollCount(shipType: 129, hire: false, day: day), 1, "one write per purchase")
    }

    // MARK: EC-26 · the race memory resets with the window

    func testFreshRaceBetDoesNotExcludeThePreviousWinner() {
        var bet = LandedServices.RaceBet()
        _ = bet.race(pick: 0, wager: 10) { _ in 2 }
        XCTAssertEqual(bet.lastWinner, 2)
        var rolls = [2, 3]                               // 2 repeats the winner, so 3
        let inVisit = bet.race(pick: 0, wager: 10) { _ in rolls.removeFirst() }
        XCTAssertEqual(inVisit.winner, 3, "inside the visit a repeat of the last winner re-rolls")
        var reopened = LandedServices.RaceBet()          // the bar window opened again
        let again = reopened.race(pick: 0, wager: 10) { _ in 3 }
        XCTAssertEqual(again.winner, 3, "after re-entering, the same colour can win")
    }

    // MARK: EC-27 · cargo overflow

    func testOverflowShrinksOrdinaryBinsButNotJunk() {
        let game = makeGame([shipResource(id: 128, cargo: 10, freeMass: 20)])
        let galaxy = Galaxy(game: game)
        var p = PlayerState(shipType: 128)
        p.cargo = [0: 20, 128: 10]
        XCTAssertTrue(PilotEconomy.shrinkCargoToCapacity(&p, galaxy: galaxy))
        XCTAssertEqual(p.cargo[0], 6, "trunc(20 x 10/30)")
        XCTAssertEqual(p.cargo[128], 10, "junk is in the denominator and never reduced")
    }

    func testSellingAHoldExpansionShrinksTheBins() {
        let game = makeGame([shipResource(id: 128, cargo: 10, freeMass: 20), outfit(630, cost: 100, mods: [(2, 20)])])
        let galaxy = Galaxy(game: game)
        var p = PlayerState(shipType: 128)
        p.outfits = [630: 1]
        p.cargo = [0: 30]
        XCTAssertTrue(PilotEconomy.sellOutfit(&p, game.outfit(630)!, galaxy: galaxy))
        XCTAssertEqual(p.cargo[0], 10)
    }

    // MARK: EC-28 · the visit latches

    func testChartAndAmnestyLatchForTheVisitAndFlaggedItemsLeaveOnExit() {
        let game = makeGame([
            shipResource(id: 128, cargo: 10, freeMass: 20),
            outfit(640, cost: 10, max: 1, mods: [(16, 1)]),
            outfit(641, cost: 10, mods: [(21, -1)]),
            outfit(642, cost: 10, flags: 0x0010),
        ])
        let galaxy = Galaxy(game: game)
        var p = PlayerState(credits: 1000, currentSystem: 128)
        XCTAssertTrue(PilotEconomy.buyOutfit(&p, game.outfit(641)!, galaxy: galaxy))
        XCTAssertFalse(PilotEconomy.canBuyOutfit(p, game.outfit(641)!, galaxy: galaxy), "clean record fires once a visit")
        XCTAssertTrue(PilotEconomy.buyOutfit(&p, game.outfit(642)!, galaxy: galaxy))
        XCTAssertEqual(p.outfits[642], 1, "a Flags 0x0010 item stays through the visit")
        PilotEconomy.closeOutfitter(&p, game: game)
        XCTAssertNil(p.outfits[642])
        PilotEconomy.beginVisit(&p)
        XCTAssertTrue(PilotEconomy.canBuyOutfit(p, game.outfit(641)!, galaxy: galaxy))
    }

    func testAShipPurchaseClearsPaintEvenWhenItStaysWithYou() {
        let game = makeGame([
            shipResource(id: 128, cargo: 10, freeMass: 20), shipResource(id: 129, cargo: 10, freeMass: 20),
            outfit(650, flags: 0x0004, mods: [(43, 0x1F)]), outfit(651, flags: 0x0004),
        ])
        var p = PlayerState(shipType: 128, credits: 1_000_000)
        p.outfits = [650: 1, 651: 1]
        XCTAssertTrue(PilotEconomy.buyShip(&p, game.ship(129)!, game: game))
        XCTAssertNil(p.outfits[650], "paint is a global colour a purchase clears")
        XCTAssertEqual(p.outfits[651], 1, "a persistent outfit still stays")
    }
}
