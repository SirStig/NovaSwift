import XCTest
@testable import NovaSwiftKit

/// Pins the generic dësc dialog rules of `Ui_RunTravelSelectionDialog` 0x004982a0.
final class DescDialogLayoutTests: XCTestCase {

    func testPictureSelection() {
        XCTAssertFalse(DescDialogLayout.usesPicture(graphicID: nil))
        XCTAssertFalse(DescDialogLayout.usesPicture(graphicID: 127))
        XCTAssertTrue(DescDialogLayout.usesPicture(graphicID: 128))
    }

    /// DITL 3003's text item is 262 px tall.
    func testShrink() {
        // Short text is treated as at least 0x30 px tall.
        XCTAssertEqual(DescDialogLayout.shrink(textHeight: 20, textItemHeight: 262), 262 - 48 - 16)
        XCTAssertEqual(DescDialogLayout.shrink(textHeight: 100, textItemHeight: 262), 146)
        // Text that fills the item: no change.
        XCTAssertEqual(DescDialogLayout.shrink(textHeight: 262, textItemHeight: 262), 0)
        XCTAssertEqual(DescDialogLayout.shrink(textHeight: 400, textItemHeight: 262), 0)
        // Within 16 px of the item: the original's formula grows the dialog.
        XCTAssertEqual(DescDialogLayout.shrink(textHeight: 255, textItemHeight: 262), -9)
    }
}
