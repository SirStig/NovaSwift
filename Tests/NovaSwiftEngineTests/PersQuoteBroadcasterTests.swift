import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

/// The përs HailQuote broadcast rate (0x00433050): 1-in-140 per raw call,
/// idle overlay only, 45 s per ship, 0x0400 gate.
final class PersQuoteBroadcasterTests: XCTestCase {
    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }

    private func setup(persFlags: Int, ships: Int) -> (World, NovaGame) {
        var col = ResourceCollection()
        var b = [UInt8](repeating: 0, count: 400)
        put16(&b, 46, 1)          // HailQuote 1
        put16(&b, 2, -1)
        put16(&b, 50, persFlags)   // Flags
        col.add(Resource(type: NovaType.pers, id: 500, name: "Captain", data: Data(b)))
        let str: [UInt8] = [0, 1, 5] + Array("hello".utf8)
        col.add(Resource(type: NovaType.strList, id: 7101, name: "q", data: Data(str)))
        let game = NovaGame(col)
        let w = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        for i in 0..<ships {
            let s = Ship(name: "N\(i)", stats: ShipStats(maxSpeed: 100, acceleration: 50, turnRate: 1))
            s.personID = 500
            s.position = Vec2(Double(100 * i), 50)
            w.addNPC(s)
        }
        return (w, game)
    }

    func testRateMatchesOriginalAndNeverOverlaps() {
        let (w, game) = setup(persFlags: 0, ships: 4)
        let caster = PersQuoteBroadcaster()
        var rng = SplitMix(seed: 7)
        let dt = 1.0 / 30
        var quotes = 0
        for _ in 0..<(30 * 600) {            // ten minutes
            let busyBefore = w.overlayTicks >= 1
            let n = caster.step(world: w, game: game, elapsed: dt, barBusy: false,
                                grudge: { _ in false }, hostile: { _ in false },
                                missionAvailable: { _ in true }, roll: { rng.next() }).count
            if busyBefore { XCTAssertEqual(n, 0, "a quote fired over a live overlay message") }
            quotes += n
            if w.overlayTicks > -1 { w.overlayTicks = max(-1, w.overlayTicks - 1) }
        }
        // Each ship: ≥ 45 s apart → ≤ 14 per ship in 600 s, 4 ships.
        XCTAssertGreaterThan(quotes, 0)
        XCTAssertLessThanOrEqual(quotes, 4 * 14)
    }

    func testLinkMissionGateSilencesQuoteWhenUnavailable() {
        let (w, game) = setup(persFlags: 0x0400, ships: 3)
        let caster = PersQuoteBroadcaster()
        var available = false
        var quotes = 0
        for _ in 0..<(30 * 120) {
            quotes += caster.step(world: w, game: game, elapsed: 1.0 / 30, barBusy: false,
                                  grudge: { _ in false }, hostile: { _ in false },
                                  missionAvailable: { _ in available }, roll: { 0 }).count
            if w.overlayTicks > -1 { w.overlayTicks = max(-1, w.overlayTicks - 1) }
        }
        XCTAssertEqual(quotes, 0)
        available = true
        quotes += caster.step(world: w, game: game, elapsed: 1.0 / 30, barBusy: false,
                              grudge: { _ in false }, hostile: { _ in false },
                              missionAvailable: { _ in available }, roll: { 0 }).count
        XCTAssertGreaterThan(quotes, 0)
    }

    struct SplitMix {
        var s: UInt64
        init(seed: UInt64) { s = seed }
        mutating func next() -> Double {
            s &+= 0x9E3779B97F4A7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double(z ^ (z >> 31)) / Double(UInt64.max)
        }
    }
}
