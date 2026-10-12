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
