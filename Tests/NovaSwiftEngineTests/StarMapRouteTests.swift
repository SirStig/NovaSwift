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
        route.arrive(at: 9)
        XCTAssertEqual(route.hops, [], "an arrival off the route drops it")
    }
}
