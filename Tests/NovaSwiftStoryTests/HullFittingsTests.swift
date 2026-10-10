import XCTest
import Foundation
import NovaSwiftKit
import NovaSwiftEngine
@testable import NovaSwiftStory

/// What a hull hands its new owner belongs to the *player*, not to the hull.
///
/// The Bible says so of both halves: `DefaultItems` are "up to eight default
/// items with which to equip this ship when the player buys or captures one",
/// and the `WeapType`/`WeapCount`/`AmmoLoad` block is introduced as "which stock
/// weapons to put on your ship when you first buy it". So `PlayerState.outfits`
/// records both, `PilotEconomy.loadout` re-adds neither, and everything a hull
/// arrived with is visible, mass-counted, mount-counted and sellable.
///
/// The weapon half is the one that matters in practice: the stock Shuttle has
/// **no** `DefaultItems` at all — its Light Blaster is purely a `WeapType` — so
/// an implementation covering only `DefaultItems` left the single most-reported
/// case ("I can't see or sell the blaster my ship came with") still broken.
final class HullFittingsTests: XCTestCase {

    /// A Shuttle-shaped hull: 10t hold, 20t free mass, two gun mounts, no
    /// `DefaultItems`, and one stock Light Blaster — exactly the real #128's
    /// shape. Plus a second hull that comes with a launcher and ammo.
    private func makeGameData() -> NovaGame {
        makeGame([
            shipResource(id: 128, cargo: 10, freeMass: 20,
                         stockWeapons: [(id: 300, count: 1, ammo: 0)], maxGuns: 2),
            shipResource(id: 129, cargo: 20, freeMass: 40,
                         defaultItems: [(id: 210, count: 1)],
                         stockWeapons: [(id: 301, count: 1, ammo: 12)], maxGuns: 2),
            weaponResource(id: 300, name: "Light Blaster"),
            weaponResource(id: 301, name: "Missile Launcher"),
            outfitResource(id: 200, name: "Light Blaster", mass: 3, cost: 5000,
                           installsWeapon: 300, isFixedGun: true),
            outfitResource(id: 201, name: "Missile Launcher", mass: 5, cost: 20000,
                           installsWeapon: 301, isFixedGun: true),
            outfitResource(id: 202, name: "Missile", mass: 0, cost: 750, ammoFor: 301),
            outfitResource(id: 210, name: "Shield Booster", mass: 4, cost: 9000),
        ])
    }

    private func charFor(ship: Int, cash: Int) -> CharRes {
        var b = [UInt8](repeating: 0, count: 362)
        Bytes.i32(&b, 0, cash)
        Bytes.i16(&b, 4, ship)
        Bytes.i16(&b, 6, 128)
        for i in 1..<4 { Bytes.i16(&b, 6 + i * 2, -1) }
        for i in 0..<4 { Bytes.i16(&b, 14 + i * 2, -1) }
        for i in 0..<4 { Bytes.i16(&b, 32 + i * 2, -1) }
        Bytes.i16(&b, 48, -1)
        Bytes.i16(&b, 308, 1); Bytes.i16(&b, 310, 1); Bytes.i16(&b, 312, 1177)
        return CharRes(Resource(type: NovaType.char, id: 128, name: ".Trader", data: Data(b)))
    }

    // MARK: A new pilot owns their hull's stock weapon

    /// The report this exists for, twice over: a brand-new pilot in the standard
    /// Shuttle could not see, count or sell its Light Blaster. Fixing only
    /// `DefaultItems` did nothing here, because the Shuttle has none.
    func testNewPilotOwnsTheStartingHullsStockWeapon() {
        let game = makeGameData()
        let pilot = PilotFactory.make(name: "P", isMale: true,
                                      scenario: charFor(ship: 128, cash: 1000),
                                      game: game, seed: 1)
        XCTAssertEqual(pilot.outfits[200], 1,
                       "the Shuttle's stock blaster is owned as the outfit that installs it")
        XCTAssertEqual(pilot.hullFittingsGranted, true)
    }

    func testStockAmmoAndDefaultItemsArriveTogether() {
        let game = makeGameData()
        var pilot = PilotFactory.make(name: "P", isMale: true,
                                      scenario: charFor(ship: 128, cash: 10_000_000),
                                      game: game, seed: 1)
        XCTAssertTrue(PilotEconomy.buyShip(&pilot, game.ship(129)!, game: game))
        XCTAssertEqual(pilot.outfits[201], 1, "the launcher")
        XCTAssertEqual(pilot.outfits[202], 12, "…its 12 rounds of AmmoLoad")
        XCTAssertEqual(pilot.outfits[210], 1, "…and the hull's DefaultItems")
        XCTAssertNil(pilot.outfits[200], "the old hull's blaster went with the trade-in")
    }

    // MARK: …exactly once

    func testStockWeaponIsMountedOnceNotTwice() {
        let game = makeGameData()
        let galaxy = Galaxy(game: game)
        let pilot = PilotFactory.make(name: "P", isMale: true,
                                      scenario: charFor(ship: 128, cash: 1000),
                                      game: game, seed: 1)
        let lo = PilotEconomy.loadout(pilot, galaxy: galaxy)
        // The bug this guards: `outfits` installs weapon 300 and the aggregator
        // used to add the hull's own copy on top, so a stock Shuttle flew two
        // blasters and burned none of its mass budget doing it.
        XCTAssertEqual(lo?.weapons.first(where: { $0.id == 300 })?.count, 1)
        XCTAssertEqual(lo?.weapons.count, 1)
        // EC-08: the loader adds the stock blaster's 3t to the class FreeMass,
        // so the owned blaster leaves the stock hull at exactly its FreeMass.
        XCTAssertEqual(PilotEconomy.freeMass(pilot, galaxy: galaxy), 20,
                       "a stock hull shows exactly its resource FreeMass")
        XCTAssertEqual(lo?.massCapacity, 23)
        XCTAssertEqual(lo?.freeGunSlots, 1,
                       "…and consumes one of the hull's two gun mounts")
    }

    /// An NPC flying the same hull must still be armed: the Bible's "AI ships
    /// ignore DefaultItems" applies to *items*, never to the stock weapons that
    /// are the only thing arming them.
    func testNPCsStillGetTheirHullWeapons() {
        let galaxy = Galaxy(game: makeGameData())
        let npc = galaxy.loadout(shipID: 128, includeDefaultItems: false)
        XCTAssertEqual(npc?.weapons.first(where: { $0.id == 300 })?.count, 1)
    }

    /// A hull whose stock weapon no outfit installs (a plug-in's unique gun)
    /// keeps it inherent rather than silently losing it.
    func testUnsellableHullWeaponStaysWithTheHull() {
        let game = makeGame([
            shipResource(id: 128, cargo: 10, freeMass: 20,
                         stockWeapons: [(id: 400, count: 2, ammo: 0)]),
            weaponResource(id: 400, name: "Prototype Lance"),
        ])
        let galaxy = Galaxy(game: game)
        XCTAssertTrue(PilotEconomy.hullFittings(game.ship(128)!, game: game).isEmpty,
                      "nothing to materialise — no outfit installs weapon 400")
        var pilot = PlayerState(shipType: 128)
        pilot.hullFittingsGranted = true
        XCTAssertEqual(PilotEconomy.loadout(pilot, galaxy: galaxy)?
                        .weapons.first(where: { $0.id == 400 })?.count, 2,
                       "so the hull keeps carrying it")
    }

    // MARK: Old saves

    func testMigrationArmsAnOlderPilotAndIsIdempotent() {
        let game = makeGameData()
        // A save from before `outfits` recorded hull fittings — including one
        // written by the build that migrated only `DefaultItems`, which is why
        // this uses a fresh marker rather than reusing the old one.
        var pilot = PlayerState(pilotName: "Old", shipType: 128)
        XCTAssertNil(pilot.hullFittingsGranted)

        XCTAssertTrue(PilotEconomy.migrateHullFittings(&pilot, game: game))
        XCTAssertEqual(pilot.outfits[200], 1,
                       "without this the pilot would launch unarmed")
        XCTAssertEqual(pilot.hullFittingsGranted, true)

        XCTAssertFalse(PilotEconomy.migrateHullFittings(&pilot, game: game))
        XCTAssertEqual(pilot.outfits[200], 1, "a second pass hands out nothing more")
    }

    func testMigrationDoesNotDuplicateAPurchasedHullsFittings() {
        let game = makeGameData()
        // A pre-migration pilot already carrying hull 129's fittings: topping up
        // must add nothing.
        var pilot = PlayerState(pilotName: "Old", shipType: 129)
        pilot.outfits = [201: 1, 202: 12, 210: 1]

        XCTAssertTrue(PilotEconomy.migrateHullFittings(&pilot, game: game))
        XCTAssertEqual(pilot.outfits[201], 1)
        XCTAssertEqual(pilot.outfits[202], 12)
        XCTAssertEqual(pilot.outfits[210], 1)
    }

    // MARK: Mission hull swaps

    /// `C` (0x00449370) changes only the class: the player's own weapons and
    /// items carry over, and the new hull's stock armament and `DefaultItems`
    /// do not — only the E/H arm adds the class's stock banks (MS-18).
    func testMissionKeepOutfitsSwapChangesOnlyTheClass() {
        let game = makeGameData()
        var pilot = PlayerState(shipType: 128)
        pilot.outfits = [200: 1]
        let engine = StoryEngine(game: game, player: pilot)
        engine.apply(set: "C129")

        XCTAssertEqual(engine.player.shipType, 129)
        XCTAssertEqual(engine.player.outfits, [200: 1], "C keeps what the player brought and adds nothing")
    }

    /// E/H clamp every owned count to its limit after adding the fittings:
    /// here the new hull's launcher is the only one, so missiles beyond its
    /// MaxAmmo go.
    func testDefaultOutfitSwapClampsOwnedCounts() {
        var resources = [
            shipResource(id: 128, cargo: 10, freeMass: 20, maxGuns: 2),
            shipResource(id: 129, cargo: 20, freeMass: 40,
                         stockWeapons: [(id: 301, count: 1, ammo: 12)], maxGuns: 2),
            outfitResource(id: 201, name: "Missile Launcher", mass: 5, cost: 20000,
                           installsWeapon: 301, isFixedGun: true),
            outfitResource(id: 202, name: "Missile", mass: 0, cost: 750, ammoFor: 301),
        ]
        var launcher = [UInt8](weaponResource(id: 301, name: "Missile Launcher").data)
        Bytes.i16(&launcher, 108, 20)                      // MaxAmmo 20
        resources.append(Resource(type: NovaType.weapon, id: 301, name: "Missile Launcher", data: Data(launcher)))
        let game = makeGame(resources)
        var pilot = PlayerState(shipType: 128)
        pilot.outfits = [202: 30]
        let engine = StoryEngine(game: game, player: pilot)
        engine.apply(set: "E129")
        XCTAssertEqual(engine.player.outfits[201], 1)
        XCTAssertEqual(engine.player.outfits[202], 20, "30 + 12 missiles clamped to one launcher's 20")
    }
}
