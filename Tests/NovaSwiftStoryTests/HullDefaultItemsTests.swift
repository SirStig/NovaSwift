import XCTest
import Foundation
import NovaSwiftKit
import NovaSwiftEngine
@testable import NovaSwiftStory

/// `shïp.DefaultItems` belong to the *player*, not to the hull — the Bible calls
/// them "the default items with which to equip this ship when the player buys or
/// captures one", and notes AI ships ignore them entirely.
///
/// So `PlayerState.outfits` is the single record of what the player owns, hull
/// defaults included, and `PilotEconomy.loadout` builds their ship from that dict
/// alone. These tests pin both halves: the defaults *arrive* (a new pilot, a
/// purchase, an old save being migrated) and they are counted exactly *once*.
final class HullDefaultItemsTests: XCTestCase {

    /// A Shuttle-shaped hull (10t hold, 20t free mass) that ships with one
    /// blaster, plus that blaster and a second, buyable outfit.
    private func makeShuttleGame(defaults: [(id: Int, count: Int)] = [(id: 200, count: 1)]) -> NovaGame {
        makeGame([
            shipResource(id: 128, cargo: 10, freeMass: 20, defaultItems: defaults),
            shipResource(id: 129, cargo: 20, freeMass: 40, defaultItems: [(id: 201, count: 2)]),
            outfitResource(id: 200, name: "Light Blaster", mass: 3, cost: 5000),
            outfitResource(id: 201, name: "Medium Blaster", mass: 8, cost: 20000),
        ])
    }

    private func charFor(ship: Int, cash: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 362)
        Bytes.i32(&b, 0, cash)
        Bytes.i16(&b, 4, ship)
        Bytes.i16(&b, 6, 128)
        for i in 1..<4 { Bytes.i16(&b, 6 + i * 2, -1) }
        for i in 0..<4 { Bytes.i16(&b, 14 + i * 2, -1) }
        for i in 0..<4 { Bytes.i16(&b, 32 + i * 2, -1) }
        Bytes.i16(&b, 48, -1)
        Bytes.i16(&b, 308, 1); Bytes.i16(&b, 310, 1); Bytes.i16(&b, 312, 1177)
        return Resource(type: NovaType.char, id: 128, name: ".Trader", data: Data(b))
    }

    // MARK: A new pilot owns what their hull came with

    /// The tester report this exists for: a brand-new pilot in the standard
    /// Shuttle could not see, count or sell its Light Blaster, because the
    /// blaster lived only inside `Galaxy.loadout` and never in the inventory the
    /// outfitter reads. They could add outfits, never strip any.
    func testNewPilotOwnsTheStartingHullsDefaultItems() {
        let game = makeShuttleGame()
        let pilot = PilotFactory.make(name: "P", isMale: true,
                                      scenario: CharRes(charFor(ship: 128, cash: 1000)),
                                      game: game, seed: 1)
        XCTAssertEqual(pilot.outfits[200], 1, "the Shuttle's own blaster is owned, so it can be sold")
        XCTAssertEqual(pilot.hullDefaultsGranted, true)
    }

    // MARK: …and owns it exactly once

    func testDefaultItemsAreCountedOnceInTheFlownLoadout() {
        let game = makeShuttleGame(defaults: [(id: 200, count: 2)])
        let galaxy = Galaxy(game: game)
        let pilot = PilotFactory.make(name: "P", isMale: true,
                                      scenario: CharRes(charFor(ship: 128, cash: 1000)),
                                      game: game, seed: 1)
        XCTAssertEqual(pilot.outfits[200], 2)
        // The bug this guards: `outfits` says 2 and the aggregator used to add
        // the hull's own 2 on top, so the ship flew 4 blasters and burned 12t of
        // a 20t mass budget instead of 6t.
        XCTAssertEqual(PilotEconomy.loadout(pilot, galaxy: galaxy)?.outfits[200], 2)
        XCTAssertEqual(PilotEconomy.freeMass(pilot, galaxy: galaxy), 20 - 6)
    }

    func testBuyingAShipGrantsTheNewHullsDefaultsOnceAndDropsTheOldHulls() {
        let game = makeShuttleGame()
        let galaxy = Galaxy(game: game)
        var pilot = PilotFactory.make(name: "P", isMale: true,
                                      scenario: CharRes(charFor(ship: 128, cash: 1_000_000)),
                                      game: game, seed: 1)
        XCTAssertTrue(PilotEconomy.buyShip(&pilot, game.ship(129)!, game: game))

        XCTAssertNil(pilot.outfits[200], "the old hull and its non-persistent items are traded in")
        XCTAssertEqual(pilot.outfits[201], 2, "the new hull's two blasters are now owned")
        XCTAssertEqual(PilotEconomy.loadout(pilot, galaxy: galaxy)?.outfits[201], 2,
                       "and are fitted once, not twice")
    }

    // MARK: Old saves

    func testMigrationTopsUpAnOldSaveExactlyOnce() {
        let game = makeShuttleGame()
        // A save written before `outfits` recorded hull defaults: the pilot flies
        // the Shuttle but their inventory lists nothing.
        var pilot = PlayerState(pilotName: "Old", shipType: 128, credits: 0)
        XCTAssertNil(pilot.hullDefaultsGranted)

        XCTAssertTrue(PilotEconomy.migrateHullDefaults(&pilot, game: game))
        XCTAssertEqual(pilot.outfits[200], 1)
        XCTAssertEqual(pilot.hullDefaultsGranted, true)

        // Idempotent: a second pass (a later launch) must not hand out a second
        // blaster, and must not undo one the player has since sold.
        XCTAssertFalse(PilotEconomy.migrateHullDefaults(&pilot, game: game))
        XCTAssertEqual(pilot.outfits[200], 1)
    }

    func testMigrationDoesNotDuplicateAPurchasedHullsDefaults() {
        let game = makeShuttleGame()
        // A pre-migration pilot who *bought* hull 129: `buyShip` already granted
        // its two blasters, so topping up must add nothing.
        var pilot = PlayerState(pilotName: "Old", shipType: 129, credits: 0)
        pilot.outfits = [201: 2]
        pilot.hullDefaultsGranted = nil

        XCTAssertTrue(PilotEconomy.migrateHullDefaults(&pilot, game: game))
        XCTAssertEqual(pilot.outfits[201], 2, "already owned — not doubled")
    }
}
