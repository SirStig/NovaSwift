import XCTest
@testable import NovaSwiftKit

/// Pins `NovaUi_RedrawProgressBar` 0x004ab3d0 / `FUN_004ab1b0`.
final class LoadingProgressBarTests: XCTestCase {

    func testFillUsesTheConstant198() {
        // A 300-wide rect still fills only 198 px at completion.
        XCTAssertEqual(LoadingProgressBar.fillRight(left: 0, right: 300, done: 1, total: 1), 199)
        XCTAssertEqual(LoadingProgressBar.fillRight(left: 10, right: 300, done: 0, total: 50), 11)
        // Floor, not round: 1/3 of 198 = 66.
        XCTAssertEqual(LoadingProgressBar.fillRight(left: 0, right: 300, done: 1, total: 3), 67)
        XCTAssertEqual(LoadingProgressBar.fillRight(left: 0, right: 300, done: 0.999, total: 1), 198)
    }

    func testFillCappedInsideTheRect() {
        XCTAssertEqual(LoadingProgressBar.fillRight(left: 0, right: 150, done: 1, total: 1), 149)
    }

    func testOpeningGrowsFromTheMiddle() {
        XCTAssertEqual(LoadingProgressBar.openingExtent(top: 0, bottom: 10, step: 0)?.top, 5)
        XCTAssertEqual(LoadingProgressBar.openingExtent(top: 0, bottom: 10, step: 3)?.bottom, 8)
        XCTAssertNil(LoadingProgressBar.openingExtent(top: 0, bottom: 10, step: 5))
    }
}
