import XCTest
import Foundation
@testable import NovaSwiftKit

final class RLEDTests: XCTestCase {

    /// Hand-assemble a minimal but valid 2×2, single-frame rlëD sprite and assert
    /// the decoder produces the exact RGBA we encoded — locking down the header
    /// layout, opcode handling, and 1-5-5-5 colour unpacking with no game data.
    func testDecodeMinimalSprite() throws {
        // 1-5-5-5 colours (top bit unused).
        let red: [UInt8]   = [0x7C, 0x00] // r=31
        let blue: [UInt8]  = [0x00, 0x1F] // b=31
        let green: [UInt8] = [0x03, 0xE0] // g=31
        let white: [UInt8] = [0x7F, 0xFF] // r=g=b=31

        var bytes: [UInt8] = []
        func be16(_ v: Int) { bytes += [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func token(_ op: UInt8, _ count: Int) {
            bytes += [op, UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]
        }

        // Header: width, height, bpp, palette, frameCount, 6 reserved.
        be16(2); be16(2); be16(16); be16(0); be16(1)
        bytes += [UInt8](repeating: 0, count: 6)

        // Row 0: two pixels (red, blue).
        token(0x01, 0)      // line start
        token(0x02, 4)      // pixel data, 4 bytes
        bytes += red + blue
        // Row 1: two pixels (green, white).
        token(0x01, 0)
        token(0x02, 4)
        bytes += green + white
        token(0x00, 0)      // end of frame

        let sheet = try RLED.decode(Data(bytes))

        XCTAssertEqual(sheet.frameWidth, 2)
        XCTAssertEqual(sheet.frameHeight, 2)
        XCTAssertEqual(sheet.frameCount, 1)
        XCTAssertEqual(sheet.surfaceWidth, 2)
        XCTAssertEqual(sheet.surfaceHeight, 2)

        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let i = (y * sheet.surfaceWidth + x) * 4
            return Array(sheet.rgba[i..<i + 4])
        }
        XCTAssertEqual(pixel(0, 0), [255, 0, 0, 255])       // red
        XCTAssertEqual(pixel(1, 0), [0, 0, 255, 255])       // blue
        XCTAssertEqual(pixel(0, 1), [0, 255, 0, 255])       // green
        XCTAssertEqual(pixel(1, 1), [255, 255, 255, 255])   // white
    }

    func testTransparentRunLeavesPixelsClear() throws {
        var bytes: [UInt8] = []
        func be16(_ v: Int) { bytes += [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func token(_ op: UInt8, _ count: Int) {
            bytes += [op, UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]
        }
        // 2×1 frame: transparent pixel then a red pixel.
        be16(2); be16(1); be16(16); be16(0); be16(1)
        bytes += [UInt8](repeating: 0, count: 6)
        token(0x01, 0)      // line start
        token(0x03, 2)      // transparent run: 2 bytes -> skip 1 pixel
        token(0x02, 2)      // pixel data: 1 pixel
        bytes += [0x7C, 0x00] // red
        token(0x00, 0)

        let sheet = try RLED.decode(Data(bytes))
        XCTAssertEqual(Array(sheet.rgba[0..<4]), [0, 0, 0, 0])       // transparent
        XCTAssertEqual(Array(sheet.rgba[4..<8]), [255, 0, 0, 255])   // red
    }

    func testRejectsNon16BitDepth() {
        var bytes: [UInt8] = []
        func be16(_ v: Int) { bytes += [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        be16(2); be16(2); be16(8); be16(0); be16(1) // bpp = 8 (unsupported)
        bytes += [UInt8](repeating: 0, count: 6)
        XCTAssertThrowsError(try RLED.decode(Data(bytes)))
    }
}
