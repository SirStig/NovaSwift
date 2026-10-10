import XCTest
@testable import NovaSwiftEngine

/// UI-05: the original star map has no pathfinding.
final class StarMapRouteTests: XCTestCase {

    /// A line of systems 1 – 2 – 3 – … – 40.
    private func linked(_ a: Int, _ b: Int) -> Bool { abs(a - b) == 1 }

    func testPlainClickArmsOnlyALinkedSystem() {
        var route = StarMapRoute()
        XCTAssertFalse(route.click(3, current: 1, linked: linked), "two jumps away arms nothing")
        XCTAssertNil(route.armedSystem)
        XCTAssertTrue(route.click(2, current: 1, linked: linked))
        XCTAssertEqual(route.hops, [2])
        XCTAssertEqual(route.armedSystem, 2)
        route.click(9, current: 1, linked: linked)
        XCTAssertNil(route.armedSystem, "a click elsewhere disarms")
    }

    func testShiftClickBuildsTheRouteHopByHop() {
        var route = StarMapRoute()
        XCTAssertFalse(route.shiftClick(3, current: 1, linked: linked), "not linked to the tail")
        XCTAssertTrue(route.shiftClick(2, current: 1, linked: linked))
        XCTAssertTrue(route.shiftClick(3, current: 1, linked: linked))
        XCTAssertEqual(route.hops, [2, 3])
        XCTAssertEqual(route.armedSystem, 2)
        // Shift+click on a plotted hop truncates after it; on the current system it clears.
        route.shiftClick(4, current: 1, linked: linked)
        route.shiftClick(2, current: 1, linked: linked)
        XCTAssertEqual(route.hops, [2])
        route.shiftClick(1, current: 1, linked: linked)
        XCTAssertEqual(route.hops, [])
    }

    func testTheThirtySecondHopIsRefused() {
        var route = StarMapRoute()
        for s in 2...32 { XCTAssertTrue(route.shiftClick(s, current: 1, linked: linked)) }
        XCTAssertEqual(route.hops.count, 31)
        XCTAssertFalse(route.shiftClick(33, current: 1, linked: linked))
        XCTAssertEqual(route.hops.count, 31)
    }

    func testArrivalPopsTheHeadAndRearms() {
        var route = StarMapRoute(hops: [2, 3, 4], armed: true)
        route.arrive(at: 2)
        XCTAssertEqual(route.hops, [3, 4])
        XCTAssertEqual(route.armedSystem, 3)
        route.arrive(at: 9, linked: linked)
        XCTAssertEqual(route.hops, [3, 4], "an arrival off the route keeps it (0x004a7fc0)")
        XCTAssertNil(route.armedSystem, "its head is not linked to system 9, so nothing is armed")
    }

    /// S-2: the 0x004a8080 sync arms only a head linked to the current
    /// system, and otherwise changes nothing.
    func testSyncArmsOnlyALinkedHead() {
        var route = StarMapRoute()
        route.shiftClick(2, current: 1, linked: linked)
        route.shiftClick(3, current: 1, linked: linked)
        route.click(20, current: 1, linked: linked)          // an unlinked click disarms, keeps the route
        XCTAssertEqual(route.hops, [2, 3])
        XCTAssertNil(route.armedSystem)
        XCTAssertTrue(route.sync(current: 1, linked: linked), "closing the map re-arms Y")
        XCTAssertEqual(route.armedSystem, 2)
        route.disarm()
        XCTAssertFalse(route.sync(current: 7, linked: linked), "head not linked from 7: stays disarmed")
        XCTAssertNil(route.armedSystem)
    }

    /// S-2: a gate arrival keeps an off-route plan and re-arms its head only
    /// when the head is linked from the arrival system.
    func testGateArrivalKeepsTheRoute() {
        var route = StarMapRoute(hops: [5, 6], armed: true)
        route.arriveViaGate(at: 30, linked: linked)
        XCTAssertEqual(route.hops, [5, 6])
        XCTAssertNil(route.armedSystem)
        route.arriveViaGate(at: 4, linked: linked)
        XCTAssertEqual(route.armedSystem, 5)
    }

    /// D-1: a hop that goes hidden is swapped for its visible twin, or cuts
    /// the route there (0x00432470).
    func testRevalidateSwapsHiddenHopsOrCutsTheRoute() {
        var route = StarMapRoute(hops: [2, 3, 4], armed: true)
        let hidden: Set<Int> = [3]
        route.revalidate(isVisible: { !hidden.contains($0) }, resolveVisible: { $0 == 3 ? 103 : nil })
        XCTAssertEqual(route.hops, [2, 103, 4])
        route.revalidate(isVisible: { $0 != 103 }, resolveVisible: { _ in nil })
        XCTAssertEqual(route.hops, [2], "no visible twin: the route ends before the hidden hop")
        route.revalidate(isVisible: { $0 != 2 }, resolveVisible: { _ in nil })
        XCTAssertEqual(route.hops, [])
        XCTAssertNil(route.armedSystem)
    }
}
