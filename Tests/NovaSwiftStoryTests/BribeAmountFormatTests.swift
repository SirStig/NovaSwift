import XCTest
@testable import NovaSwiftStory

final class BribeAmountFormatTests: XCTestCase {
    func testCommAmountFormat() {
        XCTAssertEqual(PaymentWindow.formatAmount(950), "950")
        XCTAssertEqual(PaymentWindow.formatAmount(12345), "12,345")
        XCTAssertEqual(PaymentWindow.formatAmount(1_230_000), "1.23M")
        XCTAssertEqual(PaymentWindow.formatAmount(2_005_000), "2.00M")
    }
}
