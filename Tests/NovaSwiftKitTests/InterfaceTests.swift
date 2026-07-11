import XCTest
import Foundation
@testable import NovaSwiftKit

final class InterfaceTests: XCTestCase {

    /// Build a synthetic 166-byte ïntf and assert the decoder reads every field
    /// at the reverse-engineered offsets (colors 0x00RRGGBB, rects top,left,bottom,right).
    func testIntfDecode() throws {
        var b = [UInt8](repeating: 0, count: 166)
        func color(_ off: Int, _ r: UInt8, _ g: UInt8, _ bl: UInt8) {
            b[off] = 0; b[off+1] = r; b[off+2] = g; b[off+3] = bl
        }
        func rect(_ off: Int, _ t: Int, _ l: Int, _ bo: Int, _ ri: Int) {
            for (i, v) in [t, l, bo, ri].enumerated() {
                b[off + i*2] = UInt8((v >> 8) & 0xFF); b[off + i*2 + 1] = UInt8(v & 0xFF)
            }
        }
        color(0, 0xFF, 0xFF, 0xFF)     // brightText white
        color(4, 0x88, 0x88, 0x88)     // dimText gray
        rect(8, 8, 8, 184, 184)         // radar
        color(16, 0xFF, 0xFF, 0xFF)
        color(20, 0x80, 0x80, 0x80)
        rect(24, 199, 35, 206, 184)     // shield
        color(32, 0x00, 0x00, 0xFF)     // shield blue
        rect(36, 216, 35, 223, 184)     // armor
        color(44, 0xA6, 0xA6, 0xA6)
        rect(48, 234, 35, 241, 184)     // fuel
        rect(64, 254, 8, 286, 184)      // nav
        rect(88, 458, 8, 552, 184)      // cargo
        for (i, c) in Array("Geneva".utf8).enumerated() { b[96 + i] = c }
        b[160] = 0; b[161] = 12         // font size
        b[164] = 0x02; b[165] = 0xBC    // bgPICT 700

        let res = Resource(type: NovaType.intf, id: 128, name: "Default status bar", data: Data(b))
        let intf = IntfRes(res)

        XCTAssertEqual(intf.brightText, NovaColor(r: 255, g: 255, b: 255))
        XCTAssertEqual(intf.dimText, NovaColor(r: 0x88, g: 0x88, b: 0x88))
        XCTAssertEqual(intf.radarArea, NovaRect(top: 8, left: 8, bottom: 184, right: 184))
        XCTAssertEqual(intf.radarArea.width, 176)
        XCTAssertEqual(intf.shieldColor, NovaColor(r: 0, g: 0, b: 255))
        XCTAssertEqual(intf.armorArea, NovaRect(top: 216, left: 35, bottom: 223, right: 184))
        XCTAssertEqual(intf.cargoArea, NovaRect(top: 458, left: 8, bottom: 552, right: 184))
        XCTAssertEqual(intf.statusFont, "Geneva")
        XCTAssertEqual(intf.statusFontSize, 12)
        XCTAssertEqual(intf.backgroundPictID, 700)
    }
}
