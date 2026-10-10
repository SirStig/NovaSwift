import XCTest
@testable import NovaSwiftKit

/// The per-system legal record (EC-02). Every expected value here comes from
/// running the original `Government_ProcessFactionCombatEvent` 0x00466fc0 →
/// 0x00467140 under the oracle (`~/Projects/evnova-re/audit/emulator_results.md`
/// §2, `crime_spread.py`).
final class SystemReputationTests: XCTestCase {

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }

    private func govt(_ id: Int, classes: [Int], allies: [Int] = [], enemies: [Int] = [],
                      flags: Int = 0, penalty: Int) -> GovtRes {
        var b = [UInt8](repeating: 0, count: 176)
        put16(&b, 2, flags)
        for off in [10, 12, 14, 16] { put16(&b, off, penalty) }   // smuggle, disable, board, kill
        for i in 0..<4 {
            put16(&b, 24 + i * 2, i < classes.count ? classes[i] : -1)
            put16(&b, 32 + i * 2, i < allies.count ? allies[i] : -1)
            put16(&b, 40 + i * 2, i < enemies.count ? enemies[i] : -1)
        }
        return GovtRes(Resource(type: NovaType.govt, id: id, name: "G\(id)", data: Data(b)))
    }

    /// The oracle's governments: G0 (128) the usual victim, allied with class 1
    /// and hostile to class 2; G1 (129) its ally; G2 (130) its enemy; G3 (131)
    /// neutral; G4 (132) a xenophobe.
    private var govts: [Int: GovtRes] {
        let list = [govt(128, classes: [0], allies: [1], enemies: [2], penalty: 100),
                    govt(129, classes: [1], penalty: 200),
                    govt(130, classes: [2], penalty: 300),
                    govt(131, classes: [3], penalty: 400),
                    govt(132, classes: [4], flags: 0x0001, penalty: 500)]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    private func system(_ id: Int, _ govt: Int, links: [Int]) -> ReputationMap.System {
        .init(id: id, govt: govt, x: id * 10, y: 0, links: links)
    }

    /// Crime in system 1000; its six neighbours (one hop, weight 0.65) belong
    /// to G0, G1, G2, G3, G4 and nobody.
    private func star(crimeSystemGovt: Int) -> ReputationMap {
        let owners = [128, 129, 130, 131, 132, -1]
        return ReputationMap(systems: [system(1000, crimeSystemGovt, links: Array(1001...1006))]
            + owners.enumerated().map { system(1001 + $0.offset, $0.element, links: [1000]) })
    }

    private func starRecords(victim: Int) -> [Int] {
        var rep: [Int: Int] = [:]
        SystemReputation.applyCrime(.smuggling, victim: victim, inSystem: 1000, to: &rep,
                                    govts: govts, map: star(crimeSystemGovt: victim))
        return (1000...1006).map { rep[$0] ?? 0 }
    }

    func testStarFixtureMatchesTheOracle() {
        XCTAssertEqual(starRecords(victim: 128), [-100, -65, -65, 97, 130, 162, -16])
        XCTAssertEqual(starRecords(victim: -1), [-50, 0, 0, 0, 0, 162, -32])
        XCTAssertEqual(starRecords(victim: 130), [-300, 32, 65, -195, 130, 162, -48])
        XCTAssertEqual(starRecords(victim: 132), [-500, 32, 65, 97, 130, -325, 162])
    }

    private func chain(_ count: Int, owner: (Int) -> Int = { _ in 128 }) -> ReputationMap {
        ReputationMap(systems: (0..<count).map { i in
            system(2000 + i, owner(i), links: [i > 0 ? 2000 + i - 1 : nil, i < count - 1 ? 2000 + i + 1 : nil].compactMap { $0 })
        })
    }

    private func chainRecords(_ map: ReputationMap, penalty: Int, start: [Int: Int] = [:]) -> [Int] {
        var g = govts
        g[128] = govt(128, classes: [0], allies: [1], enemies: [2], penalty: penalty)
        var rep = start
        SystemReputation.applyCrime(.kill, victim: 128, inSystem: 2000, to: &rep, govts: g, map: map)
        return map.ids.map { rep[$0] ?? 0 }
    }

    /// ×0.65 per hop, truncated toward zero, and no fixed radius: the flood
    /// stops once the change would be below 1.
    func testDecayAlongAChainHasNoFixedRadius() {
        XCTAssertEqual(chainRecords(chain(16), penalty: 100),
                       [-100, -65, -42, -27, -17, -11, -7, -4, -3, -2, -1, 0, 0, 0, 0, 0])
        XCTAssertEqual(chainRecords(chain(16), penalty: 1000),
                       [-1000, -650, -422, -274, -178, -116, -75, -49, -31, -20, -13, -8, -5, -3, -2, -1])
        XCTAssertEqual(Array(chainRecords(chain(16), penalty: -100).prefix(3)), [100, 65, 42])
    }

    /// Depth-first with visited-on-entry: a system adjacent to the crime can
    /// take 0.65² when the walk reached it through another neighbour first.
    func testTriangleWeightIsDepthFirstDepth() {
        let map = ReputationMap(systems: [system(2000, 128, links: [2001, 2002]),
                                          system(2001, 128, links: [2002, 2000]),
                                          system(2002, 128, links: [2000, 2001])])
        XCTAssertEqual(chainRecords(map, penalty: 100), [-100, -65, -42])
    }

    /// A non-allied system takes its bonus and the weight keeps compounding past it.
    func testSpreadPassesThroughANeutralSystem() {
        XCTAssertEqual(chainRecords(chain(3) { $0 == 1 ? 131 : 128 }, penalty: 100), [-100, 130, -42])
    }

    /// A system with no change stops the walk (an independent victim in a
    /// plain government's system).
    func testAZeroChangeSystemBlocks() {
        var rep: [Int: Int] = [:]
        let map = chain(3) { $0 == 1 ? 129 : -1 }
        SystemReputation.applyCrime(.kill, victim: -1, inSystem: 2000, to: &rep, govts: govts, map: map)
        XCTAssertEqual(rep, [2000: -50], "system 2001 changes nothing, so 2002 is never reached")
    }

    func testClampsAtThirtyTwoThousand() {
        XCTAssertEqual(chainRecords(chain(1), penalty: 30000, start: [2000: -10000]), [-32000])
    }

    /// Twins (same map position) change together.
    func testTwinGroupChangesTogether() {
        let map = ReputationMap(systems: [.init(id: 3000, govt: 128, x: 5, y: 5, links: []),
                                          .init(id: 3001, govt: 131, x: 5, y: 5, links: [])])
        var rep: [Int: Int] = [:]
        SystemReputation.applyCrime(.kill, victim: 128, inSystem: 3001, to: &rep, govts: govts, map: map)
        XCTAssertEqual(rep, [3000: -100, 3001: 200])
    }

    /// The old per-government record seeds each system from its owner's
    /// standing there; independent systems start clean (Q-EC-10 default).
    func testMigrationSeedsEachSystemFromItsOwner() {
        let map = ReputationMap(systems: [system(10, 128, links: []), system(11, 129, links: []),
                                          system(12, -1, links: []), system(13, 128, links: [])])
        let legacy: [Int: Int] = [128: -40, 129: 50000]
        let local: [Int: [Int: Int]] = [128: [13: -7]]
        let rep = SystemReputation.migrated(map: map) { g, s in (legacy[g] ?? 0) + (local[g]?[s] ?? 0) }
        XCTAssertEqual(rep, [10: -40, 11: 32000, 13: -47])
    }

    /// `Government_DoGovtsShareClass` 0x0046bff0 compares the raw class slots
    /// position by position and skips any negative slot; ally and enemy tests
    /// (0x0046bc90 / 0x0046bdf0) compare every slot with every slot.
    func testShareClassComparesRawSlotsPositionally() {
        func raw(_ id: Int, slots: [Int], allies: [Int] = []) -> GovtRes {
            var b = [UInt8](repeating: 0, count: 176)
            for i in 0..<4 {
                put16(&b, 24 + i * 2, slots[i])
                put16(&b, 32 + i * 2, i < allies.count ? allies[i] : -1)
                put16(&b, 40 + i * 2, -1)
            }
            return GovtRes(Resource(type: NovaType.govt, id: id, name: "G\(id)", data: Data(b)))
        }
        let a = raw(128, slots: [-1, 5, -1, -1])
        let b = raw(129, slots: [5, -1, -1, -1])          // same class, other slot
        let c = raw(130, slots: [7, 5, -1, -1])           // same class, same slot
        let d = raw(131, slots: [-2, -1, -1, -1], allies: [-2])
        let govts = Dictionary(uniqueKeysWithValues: [a, b, c, d].map { ($0.id, $0) })
        XCTAssertEqual(a.classes, [5])
        XCTAssertEqual(d.classes, [], "any negative slot is empty, not only -1")
        XCTAssertFalse(GovtRelations.shareClass(128, 129, govts: govts))
        XCTAssertTrue(GovtRelations.shareClass(128, 130, govts: govts))
        XCTAssertTrue(GovtRelations.shareClass(131, 131, govts: govts))
    }
}
