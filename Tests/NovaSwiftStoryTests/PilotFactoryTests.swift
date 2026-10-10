import XCTest
import Foundation
import NovaSwiftKit
@testable import NovaSwiftStory

final class PilotFactoryTests: XCTestCase {

    /// Build a synthetic `chär` resource for the factory to consume.
    private func charResource(id: Int, name: String, cash: Int, ship: Int,
                              systems: [Int], kills: Int = 0,
                              govtStatuses: [(Int, Int)] = [],
                              onStart: String = "",
                              day: Int = 23, month: Int = 6, year: Int = 1177) -> Resource {
        var b = [UInt8](repeating: 0, count: 362)
        Bytes.i32(&b, 0, cash)
        Bytes.i16(&b, 4, ship)
        for (i, s) in systems.prefix(4).enumerated() { Bytes.i16(&b, 6 + i * 2, s) }
        for i in systems.count..<4 { Bytes.i16(&b, 6 + i * 2, -1) }
        for i in 0..<4 { Bytes.i16(&b, 14 + i * 2, -1) }     // default: no govts
        for (i, gs) in govtStatuses.prefix(4).enumerated() {
            Bytes.i16(&b, 14 + i * 2, gs.0)
            Bytes.i16(&b, 22 + i * 2, gs.1)
        }
        Bytes.i16(&b, 30, kills)
        for i in 0..<4 { Bytes.i16(&b, 32 + i * 2, -1) }     // no intro picts
        Bytes.i16(&b, 48, -1)                                // no intro text
        Bytes.cstr(&b, 50, onStart)
        Bytes.i16(&b, 308, day); Bytes.i16(&b, 310, month); Bytes.i16(&b, 312, year)
        return Resource(type: NovaType.char, id: id, name: name, data: Data(b))
    }

    func testMakeSeedsCoreFields() {
        let game = makeGame([
            shipResource(id: 128, cargo: 10),
            charResource(id: 128, name: ".Trader", cash: 25000, ship: 128,
                         systems: [128, 136, 170, 184], kills: 0),
        ])
        let ch = game.character(128)!
        let pilot = PilotFactory.make(name: "Ripley", isMale: false, scenario: ch, game: game, seed: 7)

        XCTAssertEqual(pilot.pilotName, "Ripley")
        XCTAssertFalse(pilot.isMale)
        XCTAssertEqual(pilot.credits, 25000)
        XCTAssertEqual(pilot.shipType, 128)
        XCTAssertEqual(pilot.shipName, "Ship 128")
        XCTAssertEqual(pilot.date, GameDate(day: 23, month: 6, year: 1177))
        XCTAssertTrue([128, 136, 170, 184].contains(pilot.currentSystem))
        XCTAssertTrue(pilot.exploredSystems.contains(pilot.currentSystem))
    }

    func testRandomStartSystemIsDeterministicPerSeed() {
        let game = makeGame([
            shipResource(id: 128, cargo: 10),
            charResource(id: 128, name: "S", cash: 0, ship: 128, systems: [128, 136, 170, 184]),
        ])
        let ch = game.character(128)!
        let a = PilotFactory.make(name: "A", isMale: true, scenario: ch, game: game, seed: 42).currentSystem
        let b = PilotFactory.make(name: "B", isMale: true, scenario: ch, game: game, seed: 42).currentSystem
        XCTAssertEqual(a, b, "same seed → same start system")
    }

    func testDefaultSeedRollsVariedStartSystems() {
        // Regression: with a fixed default seed, every new pilot started in the
        // *same* candidate system (index 2 → Porto Rillia for the base .Trader),
        // which is neither the usual start nor a well-connected one. A nil seed
        // must roll genuinely per pilot, so across many creations we see more
        // than one of the scenario's candidates. (P(all identical over 40 rolls
        // of a 4-way choice) ≈ (1/4)^39 — effectively zero, so this is not flaky.)
        let game = makeGame([
            shipResource(id: 128, cargo: 10),
            charResource(id: 128, name: ".Trader", cash: 0, ship: 128,
                         systems: [128, 136, 170, 184]),
        ])
        let ch = game.character(128)!
        var seen: Set<Int> = []
        for _ in 0..<40 {
            seen.insert(PilotFactory.make(name: "P", isMale: true, scenario: ch, game: game).currentSystem)
        }
        XCTAssertTrue(seen.isSubset(of: [128, 136, 170, 184]),
                      "start system must always be one of the scenario candidates")
        XCTAssertGreaterThan(seen.count, 1,
                             "new pilots must not all start in the same system")
    }

    func testOnStartControlBitsApply() {
        let game = makeGame([
            shipResource(id: 128, cargo: 10),
            charResource(id: 128, name: "S", cash: 100, ship: 128, systems: [128],
                         onStart: "b100 b250"),
        ])
        let ch = game.character(128)!
        let pilot = PilotFactory.make(name: "P", isMale: true, scenario: ch, game: game)
        XCTAssertTrue(pilot.setBits.contains(100))
        XCTAssertTrue(pilot.setBits.contains(250))
    }

    /// `chär` statuses overwrite the reputation of every system whose owner is
    /// allied with the named government, and set `−status` where the owner is
    /// hostile to it (0x004cd4b0); other systems start at their owner's
    /// InitialRec, never below 0 (0x004b4220).
    func testGovtStandingApplied() {
        func govt(_ id: Int, classes: [Int], allies: [Int] = [], enemies: [Int] = [], initialRec: Int = 0) -> Resource {
            var b = [UInt8](repeating: 0, count: 176)
            Bytes.i16(&b, 20, initialRec)
            for i in 0..<4 { Bytes.i16(&b, 24 + i * 2, i < classes.count ? classes[i] : -1) }
            for i in 0..<4 { Bytes.i16(&b, 32 + i * 2, i < allies.count ? allies[i] : -1) }
            for i in 0..<4 { Bytes.i16(&b, 40 + i * 2, i < enemies.count ? enemies[i] : -1) }
            return Resource(type: NovaType.govt, id: id, name: "G\(id)", data: Data(b))
        }
        let game = makeGame([
            shipResource(id: 128, cargo: 10),
            govt(200, classes: [1], allies: [2], enemies: [3]),
            govt(201, classes: [2]),                     // ally of 200
            govt(202, classes: [3], initialRec: 40),     // enemy of 200
            govt(203, classes: [4], initialRec: 25),     // unrelated
            govt(204, classes: [5], initialRec: -25),    // unrelated, negative InitialRec
            ownedSystemResource(id: 128, govt: 200), ownedSystemResource(id: 129, govt: 201),
            ownedSystemResource(id: 130, govt: 202), ownedSystemResource(id: 131, govt: 203),
            ownedSystemResource(id: 132, govt: 204), ownedSystemResource(id: 133, govt: -1),
            charResource(id: 128, name: "S", cash: 0, ship: 128, systems: [128],
                         govtStatuses: [(200, 30)]),
        ])
        let ch = game.character(128)!
        let pilot = PilotFactory.make(name: "P", isMale: true, scenario: ch, game: game)
        XCTAssertEqual(pilot.systemReputation, [128: 30, 129: 30, 130: -30, 131: 25])
    }

    func testNewPilotCreditsClampAndNoFreeIFF() {
        let game = makeGame([
            shipResource(id: 128, cargo: 10),
            charResource(id: 128, name: "S", cash: -500, ship: 128, systems: [128]),
            iffOutfit(id: 300),
        ])
        let ch = game.character(128)!
        let pilot = PilotFactory.make(name: "P", isMale: true, scenario: ch, game: game)
        XCTAssertEqual(pilot.credits, 0, "credits clamp at 0")
        XCTAssertNil(pilot.outfits[300], "the original grants no IFF")
    }

    func testNewPilotHasTheStartSystemsNeighboursExplored() {
        // UI-04: the start system and every visible system one jump away.
        let game = makeGame([
            shipResource(id: 128, cargo: 10),
            charResource(id: 128, name: "S", cash: 0, ship: 128, systems: [300]),
            systemResource(id: 300, links: [301, 302]), systemResource(id: 301),
            systemResource(id: 302, visibility: "b9"), systemResource(id: 303, links: [300]),
        ])
        let pilot = PilotFactory.make(name: "P", isMale: true, scenario: game.character(128)!, game: game)
        XCTAssertEqual(pilot.exploredSystems, [300, 301], "hidden 302 and the one-way 303 stay unknown")
    }

    func testMakeDefaultUsesLowestScenario() {
        let game = makeGame([
            shipResource(id: 128, cargo: 10),
            charResource(id: 128, name: ".Trader", cash: 25000, ship: 128, systems: [128]),
        ])
        let pilot = PilotFactory.makeDefault(name: "Cap", isMale: true, game: game)
        XCTAssertEqual(pilot.credits, 25000)
        XCTAssertEqual(pilot.currentSystem, 128)
    }
}
