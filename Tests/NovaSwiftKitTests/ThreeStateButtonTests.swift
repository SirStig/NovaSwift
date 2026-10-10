import XCTest
@testable import NovaSwiftKit

/// Pins `NovaUi_InitThreeStateButtonArt` 0x004a2f50 / `NovaUi_DrawThreeStateButton`
/// 0x004a3340.
final class ThreeStateButtonTests: XCTestCase {

    func testResourceIDs() {
        XCTAssertEqual(ThreeStateButton.artID(state: .normal, slice: 0), 7500)
        XCTAssertEqual(ThreeStateButton.artID(state: .pressed, slice: 1), 7504)
        XCTAssertEqual(ThreeStateButton.artID(state: .grey, slice: 2), 7508)
        XCTAssertEqual(ThreeStateButton.maskID(state: .grey, slice: 0), 7606)
    }

    func testVisibilityFromParam4() {
        XCTAssertEqual(ThreeStateButton.visibility(param4: 0), .art)
        XCTAssertEqual(ThreeStateButton.visibility(param4: -1), .art)
        XCTAssertEqual(ThreeStateButton.visibility(param4: -3), .customPict)
        XCTAssertEqual(ThreeStateButton.visibility(param4: 1), .hidden)
        XCTAssertEqual(ThreeStateButton.visibility(param4: -2), .hidden)
    }

    /// Caps keep their own widths; a missing cap PICT is a 12-wide slot; the
    /// middle fills what is left.
    func testLayoutUsesCapWidths() {
        let l = ThreeStateButton.layout(width: 146, leftCapWidth: 13, rightCapWidth: 13)
        XCTAssertEqual(l.leftCapWidth, 13)
        XCTAssertEqual(l.rightCapX, 133)
        XCTAssertEqual(l.middleX, 13)
        XCTAssertEqual(l.middleWidth, 120)
        let m = ThreeStateButton.layout(width: 100, leftCapWidth: nil, rightCapWidth: 20)
        XCTAssertEqual(m.leftCapWidth, 12)
        XCTAssertEqual(m.rightCapX, 80)
        XCTAssertEqual(m.middleWidth, 68)
        // A 25-px icon button: the caps overlap and there is no middle.
        XCTAssertEqual(ThreeStateButton.layout(width: 25, leftCapWidth: 13, rightCapWidth: 13).middleWidth, 0)
    }

    func testGlyphs() {
        // 25×25 button: centre (12, 12); arrows use h/10 = 2.
        XCTAssertEqual(ThreeStateButton.glyph("^", width: 25, height: 25),
                       [.init(12, 10, 8, 14), .init(12, 10, 16, 14)])
        XCTAssertEqual(ThreeStateButton.glyph("&", width: 25, height: 25),
                       [.init(12, 14, 8, 10), .init(12, 14, 16, 10)])
        // plus h/8 = 3, minus h/9 = 2.
        XCTAssertEqual(ThreeStateButton.glyph("+", width: 25, height: 25),
                       [.init(9, 12, 15, 12), .init(12, 9, 12, 15)])
        XCTAssertEqual(ThreeStateButton.glyph("-", width: 25, height: 25), [.init(10, 12, 14, 12)])
        XCTAssertNil(ThreeStateButton.glyph("Buy", width: 60, height: 25))
        XCTAssertNil(ThreeStateButton.glyph("x", width: 25, height: 25))
    }

    func testLabelOrigin() {
        let o = ThreeStateButton.labelOrigin(buttonWidth: 100, buttonHeight: 25, textWidth: 31)
        XCTAssertEqual(o.x, 35)
        XCTAssertEqual(o.baseline, 17)
    }

    /// The stock mask 7600 is a black pill on white: black lets the art through.
    func testMaskPolarity() {
        XCTAssertTrue(ThreeStateButton.maskOpaque(r: 0, g: 0, b: 0))
        XCTAssertFalse(ThreeStateButton.maskOpaque(r: 255, g: 255, b: 255))
    }
}
