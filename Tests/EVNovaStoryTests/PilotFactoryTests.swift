import XCTest
import Foundation
import EVNovaKit
@testable import EVNovaStory

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

    func testGovtStandingApplied() {
        let game = makeGame([
            shipResource(id: 128, cargo: 10),
            charResource(id: 128, name: "S", cash: 0, ship: 128, systems: [128],
                         govtStatuses: [(200, 30)]),
        ])
        let ch = game.character(128)!
        let pilot = PilotFactory.make(name: "P", isMale: true, scenario: ch, game: game)
        XCTAssertEqual(pilot.legalRecord[200], 30)
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
