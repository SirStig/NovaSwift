import XCTest
@testable import NovaSwiftKit

final class ControlBitIndexTests: XCTestCase {

    private func mission(_ id: Int, _ name: String = "", avail: String = "", accept: String = "", success: String = "") -> Resource {
        let s = ResourceSchemas.schema(for: NovaType.mission)!
        var d = s.makeDefault()
        s.write(.string(avail), key: "availBits", into: &d)
        s.write(.string(accept), key: "onAccept", into: &d)
        s.write(.string(success), key: "onSuccess", into: &d)
        return Resource(type: NovaType.mission, id: id, name: name, data: d)
    }

    func testScannersAndRoles() {
        XCTAssertEqual(ControlBitIndex.testBits(in: "b10 & !b11 | (b2)").map(\.bit), [10, 11, 2])
        XCTAssertEqual(ControlBitIndex.testBits(in: "b10 & !b11").map(\.negated), [false, true])
        XCTAssertEqual(ControlBitIndex.descBits(in: "Hi {b12 \"a\" \"b\"} and {!b13 \"c\"}").map(\.bit), [12, 13])
        XCTAssertEqual(ControlBitIndex.storylineKey(ofMissionName: "Return to Earth; Vellos3"), "Vellos")
        XCTAssertNil(ControlBitIndex.storylineKey(ofMissionName: "Plain"))
    }

    func testTestersSettersStatusAndReachability() {
        var c = ResourceCollection()
        c.add(mission(128, "A; Foo1", success: "b100 !b101 ^b102"))
        c.add(mission(129, "B; Foo2", avail: "b100"))
        c.add(mission(130, "C; Foo3", avail: "b200"))
        c.add(mission(131, "D", avail: "b300", success: "b300 b400"))
        let idx = ControlBitIndex(c)
        XCTAssertEqual(idx.status(of: 100), .ok)
        XCTAssertEqual(idx.testers(of: 100).map(\.key.id), [129])
        XCTAssertEqual(idx.writers(of: 100).first?.role, .set)
        XCTAssertEqual(idx.writers(of: 101).first?.role, .clear)
        XCTAssertEqual(idx.writers(of: 102).first?.role, .toggle)
        XCTAssertEqual(idx.status(of: 101), .setNeverTested)
        XCTAssertEqual(idx.status(of: 200), .testedNeverSet)
        XCTAssertEqual(idx.status(of: 300), .onlySetByUnreachable)
        XCTAssertTrue(idx.unreachable.contains(ResourceKey(NovaType.mission, 130)))
        XCTAssertTrue(idx.unreachable.contains(ResourceKey(NovaType.mission, 131)))
        XCTAssertFalse(idx.unreachable.contains(ResourceKey(NovaType.mission, 129)))
    }

    func testReachabilityHonoursBooleanStructure() {
        var c = ResourceCollection()
        c.add(mission(128, "Src", success: "b100"))                 // makes b100 live
        c.add(mission(129, "OrOk", avail: "b100 | b200"))            // b100 live -> reachable
        c.add(mission(130, "AndDead", avail: "b100 & b200"))         // b200 never set -> dead
        c.add(mission(131, "NotOk", avail: "!b200"))                 // never set, so clear -> reachable
        c.add(mission(132, "Contradiction", avail: "b100 & !b100"))  // unsatisfiable
        c.add(mission(133, "ParenOk", avail: "(b100 | b200) & b100"))
        c.add(mission(134, "ParenDead", avail: "(b200 | b201) & b100"))
        c.add(mission(135, "NotGroupOk", avail: "!(b200 | b201)"))   // both clear -> true
        c.add(mission(136, "NotGroupDead", avail: "!(b100 | b200) & b100"))
        c.add(mission(137, "FreeAtom", avail: "o128 & b100"))        // outfit operand can be either
        c.add(mission(138, "Chain", avail: "b129"))                  // b129 only raised by an unreachable mission
        c.add(mission(139, "Raiser", avail: "b200", success: "b129"))
        let idx = ControlBitIndex(c)
        func dead(_ id: Int) -> Bool { idx.unreachable.contains(ResourceKey(NovaType.mission, id)) }
        XCTAssertFalse(dead(129))
        XCTAssertTrue(dead(130))
        XCTAssertFalse(dead(131))
        XCTAssertTrue(dead(132))
        XCTAssertFalse(dead(133))
        XCTAssertTrue(dead(134))
        XCTAssertFalse(dead(135))
        XCTAssertTrue(dead(136))
        XCTAssertFalse(dead(137))
        XCTAssertTrue(dead(139))
        XCTAssertTrue(dead(138), "gated only by a bit that an unreachable mission raises")
    }

    func testProbeMatchesInterpreterOnSimpleShapes() {
        func sat(_ s: String, set: Set<Int>) -> Bool { NCBProbe(s).isSatisfiable(canBeSet: { set.contains($0) }) }
        XCTAssertTrue(sat("", set: []))
        XCTAssertTrue(sat("!b5", set: []))
        XCTAssertFalse(sat("b5", set: []))
        XCTAssertTrue(sat("b5", set: [5]))
        XCTAssertTrue(sat("b5 | b6", set: [6]))
        XCTAssertFalse(sat("b5 & b6", set: [6]))
        XCTAssertFalse(sat(" b5", set: [5]), "a leading space fails the original's start check")
        XCTAssertEqual(NCBProbe("b5 & (b6 | !b7) & o3").atoms.count, 4)
    }

    func testFreeRunsAndGraph() {
        var c = ResourceCollection()
        c.add(mission(128, "A; Foo1", success: "b0 b1 b3"))
        c.add(mission(129, "B; Foo2", avail: "b1", accept: "b5"))
        c.add(mission(130, "C; Foo3", avail: "b5"))
        let idx = ControlBitIndex(c)
        XCTAssertEqual(idx.freeRuns(count: 2, limit: 2), [6, 8])
        let g = StoryGraph(collection: c, index: idx, touched: [])
        XCTAssertEqual(g.nodes.count, 3)
        XCTAssertEqual(g.edges.count, 2)
        let a = g.nodes[g.indexByKey[ResourceKey(NovaType.mission, 128)]!]
        let z = g.nodes[g.indexByKey[ResourceKey(NovaType.mission, 130)]!]
        XCTAssertLessThan(a.x, z.x)
        XCTAssertEqual(a.storyline, "Foo")
    }

    func testBitNotesRoundTrip() {
        var n = BitNotes(); n[12] = .init(name: "Met Vellos", note: "set in M5")
        XCTAssertEqual(BitNotes(data: n.encoded())[12].name, "Met Vellos")
        n[12] = .init(); XCTAssertTrue(n.bits.isEmpty)
    }

    func testRealData() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = GameLibrary.discoverResourceFiles(in: repo.appendingPathComponent("data/base"))
        guard !files.isEmpty else { throw XCTSkip("No stock data under data/base") }
        let c = try GameLibrary.merge(baseFiles: files)
        let t0 = Date()
        let idx = ControlBitIndex(c)
        let t1 = Date()
        let g = StoryGraph(collection: c, index: idx, touched: [])
        let t2 = Date()
        print("REAL: \(idx.usedBits.count) bits, \(g.nodes.count) nodes, \(g.edges.count) edges, \(g.hubBits.count) hubs, \(idx.unreachable.count) unreachable, index \(t1.timeIntervalSince(t0))s graph \(t2.timeIntervalSince(t1))s")
        XCTAssertGreaterThan(idx.usedBits.count, 100)
        XCTAssertGreaterThan(g.edges.count, 100)
        XCTAssertLessThan(t2.timeIntervalSince(t0), 5)
        XCTAssertFalse(g.nodes.contains { $0.x.isNaN || $0.y.isNaN })
    }
}
