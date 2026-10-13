import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

/// `GameSession.makeWorld(configure:)` runs BEFORE the initial population, so
/// pilot-dependent spawn gates (përs `ActiveOn`, shïp `AppearOn`) already govern
/// the very first fill of a system — not just later respawns.
final class MakeWorldConfigureTests: XCTestCase {

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }

    private func hull(_ id: Int, appearOn: String = "") -> Resource {
        var b = [UInt8](repeating: 0, count: 2000)
        put16(&b, 12, 40); put16(&b, 14, 120)
        for (i, c) in Array(appearOn.utf8).prefix(255).enumerated() { b[363 + i] = c }
        return Resource(type: NovaType.ship, id: id, name: "Hull\(id)", data: Data(b))
    }

    private func dude(_ id: Int, ships: [(Int, Int)]) -> Resource {
        var b = [UInt8](repeating: 0, count: 88)
        put16(&b, 0, 1); put16(&b, 2, -1)
        for (i, s) in ships.prefix(16).enumerated() { put16(&b, 8 + i * 2, s.0); put16(&b, 40 + i * 2, s.1) }
        return Resource(type: NovaType.dude, id: id, name: "Dude\(id)", data: Data(b))
    }

    private func pers(_ id: Int, shipType: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 400)
        put16(&b, 0, -1); put16(&b, 2, -1); put16(&b, 4, 1); put16(&b, 10, shipType)
        return Resource(type: NovaType.pers, id: id, name: "Pers\(id)", data: Data(b))
    }

    private func landableSpob(_ id: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 40)
        b[9] = 0x01                      // Flags 0x0001 — landable
        put16(&b, 20, -1); put16(&b, 24, 1000)
        return Resource(type: NovaType.spob, id: id, name: "Spob\(id)", data: Data(b))
    }

    private func system(_ id: Int, dudeID: Int, pinned: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 500)
        for i in 0..<16 { put16(&b, 4 + i * 2, -1); put16(&b, 36 + i * 2, i == 0 ? 128 : -1) }
        for i in 0..<8 { put16(&b, 68 + i * 2, -1); put16(&b, 84 + i * 2, 0) }
        put16(&b, 68, dudeID); put16(&b, 84, 100)
        put16(&b, 100, 8)              // average ships
        put16(&b, 102, -1)
        for i in 0..<8 {
            put16(&b, 110 + i * 2, i == 0 ? pinned : -1)
            put16(&b, 126 + i * 2, i == 0 ? 100 : 0)     // appearance chance
        }
        return Resource(type: NovaType.syst, id: id, name: "Sys\(id)", data: Data(b))
    }

    private func build(configure: ((World) -> Void)?) -> World {
        var col = ResourceCollection()
        col.add(hull(128))                         // the pinned përs' hull
        col.add(hull(129, appearOn: "b5"))         // gated traffic hull
        col.add(dude(128, ships: [(129, 100)]))
        col.add(pers(128, shipType: 128))
        col.add(landableSpob(128))
        col.add(system(128, dudeID: 128, pinned: 128))
        let game = NovaGame(col)
        let player = Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        return GameSession.makeWorld(game: game, systemID: 128, player: player, configure: configure).world
    }

    func testConfigureHookGatesInitialPopulation() {
        // Baseline: ungated, the pinned përs and the AppearOn hull both populate.
        let open = build(configure: nil)
        XCTAssertTrue(open.npcs.contains { $0.personID == 128 }, "pinned përs spawns when eligible")
        XCTAssertTrue(open.npcs.contains { $0.shipTypeID == 129 }, "AppearOn hull spawns when eligible")

        // The hook closes both gates before the first fill.
        let gated = build(configure: { w in
            w.persSpawnEligible = { _ in false }
            w.shipSpawnEligible = { _ in false }
        })
        XCTAssertFalse(gated.npcs.contains { $0.personID == 128 }, "gated përs must not be in the first population")
        XCTAssertFalse(gated.npcs.contains { $0.shipTypeID == 129 }, "gated AppearOn hull must not be in the first population")
    }
}
