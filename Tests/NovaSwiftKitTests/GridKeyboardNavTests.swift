import XCTest
@testable import NovaSwiftKit

/// Pins the shipyard grid's arrow-key rules (0x008722b0).
final class GridKeyboardNavTests: XCTestCase {
    typealias N = GridKeyboardNav

    func testNoSelectionStartsAtAnEnd() {
        XCTAssertEqual(N.step(slot: -1, offset: 0, count: 30, key: .right).slot, 0)
        XCTAssertEqual(N.step(slot: -1, offset: 0, count: 30, key: .down).slot, 0)
        XCTAssertEqual(N.step(slot: -1, offset: 0, count: 30, key: .up).slot, 19)
        // …pulled back onto the last real item.
        XCTAssertEqual(N.step(slot: -1, offset: 0, count: 7, key: .left).slot, 6)
    }

    func testMovesSelectionNotPage() {
        XCTAssertTrue(N.step(slot: 5, offset: 0, count: 30, key: .right) == (6, 0))
        XCTAssertTrue(N.step(slot: 5, offset: 0, count: 30, key: .down) == (9, 0))
        XCTAssertTrue(N.step(slot: 5, offset: 0, count: 30, key: .up) == (1, 0))
        XCTAssertTrue(N.step(slot: 5, offset: 0, count: 30, key: .left) == (4, 0))
    }

    func testScrollsAtTheEdges() {
        // Right from the last slot scrolls a row and lands on the next item.
        XCTAssertTrue(N.step(slot: 19, offset: 0, count: 30, key: .right) == (16, 4))
        // Down from the bottom row scrolls a row, keeping the slot.
        XCTAssertTrue(N.step(slot: 17, offset: 0, count: 30, key: .down) == (17, 4))
        // Up from the top row scrolls back.
        XCTAssertTrue(N.step(slot: 2, offset: 4, count: 30, key: .up) == (2, 0))
        // Left from slot 0 scrolls back to the end of the previous row.
        XCTAssertTrue(N.step(slot: 0, offset: 4, count: 30, key: .left) == (3, 0))
        // Nothing beyond the list: no scroll, no move.
        XCTAssertTrue(N.step(slot: 19, offset: 8, count: 28, key: .right) == (19, 8))
        XCTAssertTrue(N.step(slot: 2, offset: 0, count: 5, key: .down) == (2, 0))
    }
}
