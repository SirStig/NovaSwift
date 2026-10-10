import XCTest
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif
@testable import NovaSwiftKit

/// Pins the Windows build's PICT reader (0x004fd0a0 / 0x004fcc00 / 0x004fcac0):
/// indexed PixMaps and BitMaps, the default palette, the 32-bit alpha plane,
/// opcode skipping, the frame/clip rule, v1 pictures and QuickTime JPEG.
final class PICTDecoderTests: XCTestCase {

    // MARK: Builders

    private struct W {
        var d = Data()
        mutating func u8(_ v: Int) { d.append(UInt8(truncatingIfNeeded: v)) }
        mutating func u16(_ v: Int) { u8(v >> 8); u8(v) }
        mutating func u32(_ v: Int) { u16(v >> 16); u16(v) }
        mutating func rect(_ t: Int, _ l: Int, _ b: Int, _ r: Int) { u16(t); u16(l); u16(b); u16(r) }
        mutating func bytes(_ b: [UInt8]) { d.append(contentsOf: b) }
        mutating func align() { if d.count & 1 != 0 { u8(0) } }
    }

    /// v2 header: size, frame, 0x0011 0x02FF, 0x0C00 + 24-byte header.
    private func v2(w: Int, h: Int) -> W {
        var p = W()
        p.u16(0); p.rect(0, 0, h, w)
        p.u16(0x0011); p.u16(0x02FF)
        p.u16(0x0C00); p.bytes([UInt8](repeating: 0, count: 24))
        return p
    }

    private func pixMapFields(_ p: inout W, pixelSize: Int, cmpCount: Int, packType: Int = 0) {
        p.u16(0)                 // pmVersion
        p.u16(packType)
        p.u32(0); p.u32(0x480000); p.u32(0x480000)
        p.u16(pixelSize == 16 || pixelSize == 32 ? 16 : 0) // pixelType
        p.u16(pixelSize); p.u16(cmpCount); p.u16(pixelSize >= 16 ? 8 : pixelSize)
        p.u32(0); p.u32(0); p.u32(0)
    }

    private func srcDstMode(_ p: inout W, w: Int, h: Int) {
        p.rect(0, 0, h, w); p.rect(0, 0, h, w); p.u16(0)
    }

    private func rgb(_ s: SpriteSheet, _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * s.surfaceWidth + x) * 4
        return Array(s.rgba[i..<i + 4])
    }

    /// An 8-bit 0x98 PICT, 2x1, unpacked rows, with a 3-entry clut.
    private func indexed8(ctFlags: Int, entries: [(Int, Int, Int, Int)], pixels: [UInt8]) -> Data {
        let w = pixels.count
        var p = v2(w: w, h: 1)
        p.u16(0x0098)
        p.u16(0x8000 | w)          // rowBytes (< 8 → unpacked)
        p.rect(0, 0, 1, w)
        pixMapFields(&p, pixelSize: 8, cmpCount: 1)
        p.u32(0); p.u16(ctFlags); p.u16(entries.count - 1)
        for e in entries { p.u16(e.0); p.u16(e.1); p.u16(e.2); p.u16(e.3) }
        srcDstMode(&p, w: w, h: 1)
        p.bytes(pixels)
        p.align(); p.u16(0x00FF)
        return p.d
    }

    // MARK: Indexed

    func testEightBitClutWithExplicitIndices() throws {
        let data = indexed8(ctFlags: 0,
                            entries: [(2, 0xFF00, 0, 0), (5, 0, 0x8000, 0), (300, 0xFFFF, 0xFFFF, 0)],
                            pixels: [2, 5, 0, 7])
        let s = try PICT.decode(data)
        XCTAssertEqual(rgb(s, 0, 0), [0xFF, 0, 0, 255])        // high byte of each component
        XCTAssertEqual(rgb(s, 1, 0), [0, 0x80, 0, 255])
        XCTAssertEqual(rgb(s, 2, 0), [255, 255, 255, 255])     // default palette: 0 = white
        XCTAssertEqual(rgb(s, 3, 0), [0, 0, 0, 255])           // … everything else black
    }

    func testEightBitSequentialClutIgnoresValueField() throws {
        let data = indexed8(ctFlags: 0x8000,
                            entries: [(9, 0, 0, 0xFF00), (9, 0xFF00, 0, 0), (9, 0, 0xFF00, 0)],
                            pixels: [0, 1, 2])
        let s = try PICT.decode(data)
        XCTAssertEqual(rgb(s, 0, 0), [0, 0, 0xFF, 255])
        XCTAssertEqual(rgb(s, 1, 0), [0xFF, 0, 0, 255])
        XCTAssertEqual(rgb(s, 2, 0), [0, 0xFF, 0, 255])
    }

    func testFourBitPackedPixMap() throws {
        // 16 px wide, 4 bpp → rowBytes 8 → packed with a 1-byte count.
        var p = v2(w: 16, h: 1)
        p.u16(0x0098); p.u16(0x8000 | 8); p.rect(0, 0, 1, 16)
        pixMapFields(&p, pixelSize: 4, cmpCount: 1)
        p.u32(0); p.u16(0); p.u16(1)
        p.u16(0); p.u16(0); p.u16(0); p.u16(0)                 // 0 → black
        p.u16(3); p.u16(0); p.u16(0); p.u16(0xFFFF)            // 3 → blue
        srcDstMode(&p, w: 16, h: 1)
        // PackBits: repeat 0x30 eight times (flag 0xF9 = 257-0xF9 = 8 copies).
        p.u8(2); p.u8(0xF9); p.u8(0x30)
        p.align(); p.u16(0x00FF)
        let s = try PICT.decode(p.d)
        for x in stride(from: 0, to: 16, by: 2) {
            XCTAssertEqual(rgb(s, x, 0), [0, 0, 0xFF, 255])
            XCTAssertEqual(rgb(s, x + 1, 0), [0, 0, 0, 255])
        }
    }

    func testOneBitBitMapIsWhiteOnZeroBlackOnOne() throws {
        var p = v2(w: 8, h: 2)
        p.u16(0x0090); p.u16(1)                                 // BitMap (bit 15 clear), rowBytes 1
        p.rect(0, 0, 2, 8)
        srcDstMode(&p, w: 8, h: 2)
        p.u8(0b1010_0000); p.u8(0xFF)
        p.align(); p.u16(0x00FF)
        let s = try PICT.decode(p.d)
        XCTAssertEqual(rgb(s, 0, 0), [0, 0, 0, 255])
        XCTAssertEqual(rgb(s, 1, 0), [255, 255, 255, 255])
        XCTAssertEqual(rgb(s, 2, 0), [0, 0, 0, 255])
        XCTAssertEqual(rgb(s, 7, 1), [0, 0, 0, 255])
    }

    func testRegionVariantSkipsMaskRegion() throws {
        var p = v2(w: 8, h: 1)
        p.u16(0x0091); p.u16(1); p.rect(0, 0, 1, 8)
        srcDstMode(&p, w: 8, h: 1)
        p.u16(10); p.rect(0, 0, 1, 8)                           // mask region
        p.u8(0x0F)
        p.align(); p.u16(0x00FF)
        let s = try PICT.decode(p.d)
        XCTAssertEqual(rgb(s, 3, 0), [255, 255, 255, 255])
        XCTAssertEqual(rgb(s, 4, 0), [0, 0, 0, 255])
    }

    // MARK: Direct

    func testThirtyTwoBitSkipsTheAlphaPlaneAndIsOpaque() throws {
        // 4 px, cmpCount 4, planes A R G B, packed (rowBytes 16), one repeat run
        // per plane. (A packed row longer than 4·width bytes overruns the exe's
        // buffer, so incompressible literals can't be used here.)
        var p = v2(w: 4, h: 1)
        p.u16(0x009A); p.u32(0xFF); p.u16(0x8000 | 16); p.rect(0, 0, 1, 4)
        pixMapFields(&p, pixelSize: 32, cmpCount: 4, packType: 4)
        srcDstMode(&p, w: 4, h: 1)
        p.u8(8); p.bytes([0xFD, 0x00, 0xFD, 0xA0, 0xFD, 0xB0, 0xFD, 0xC0])
        p.align(); p.u16(0x00FF)
        let s = try PICT.decode(p.d)
        XCTAssertEqual(rgb(s, 0, 0), [0xA0, 0xB0, 0xC0, 255])
        XCTAssertEqual(rgb(s, 3, 0), [0xA0, 0xB0, 0xC0, 255])
    }

    func testPackedRowLongerThanFourTimesWidthFails() {
        var p = v2(w: 2, h: 1)
        p.u16(0x009A); p.u32(0xFF); p.u16(0x8000 | 8); p.rect(0, 0, 1, 2)
        pixMapFields(&p, pixelSize: 32, cmpCount: 4, packType: 4)
        srcDstMode(&p, w: 2, h: 1)
        p.u8(9); p.u8(7); p.bytes([0, 0, 1, 1, 2, 2, 3, 3])
        XCTAssertThrowsError(try PICT.decode(p.d))
    }

    func testSixteenBitUnpackedSlice() throws {
        var p = v2(w: 2, h: 1)
        p.u16(0x009A); p.u32(0xFF); p.u16(0x8000 | 4); p.rect(0, 0, 1, 2)
        pixMapFields(&p, pixelSize: 16, cmpCount: 3, packType: 3)
        srcDstMode(&p, w: 2, h: 1)
        p.u16(0x7C00); p.u16(0x001F)
        p.align(); p.u16(0x00FF)
        let s = try PICT.decode(p.d)
        XCTAssertEqual(rgb(s, 0, 0), [255, 0, 0, 255])
        XCTAssertEqual(rgb(s, 1, 0), [0, 0, 255, 255])
    }

    // MARK: Opcodes, frame, version

    func testUnusedOpcodesAreSkipped() throws {
        var p = v2(w: 8, h: 1)
        p.u16(0x001E)                                           // defHilite
        p.u16(0x000E); p.u32(0)                                 // fgColor
        p.u16(0x0002); p.bytes([UInt8](repeating: 0, count: 8)) // bkPat
        p.u16(0x00A1); p.u16(100); p.u16(3); p.bytes([1, 2, 3]) // long comment
        p.align()
        p.u16(0x0090); p.u16(1); p.rect(0, 0, 1, 8)
        srcDstMode(&p, w: 8, h: 1)
        p.u8(0x80)
        p.align(); p.u16(0x00FF)
        let s = try PICT.decode(p.d)
        XCTAssertEqual(rgb(s, 0, 0), [0, 0, 0, 255])
        XCTAssertEqual(rgb(s, 1, 0), [255, 255, 255, 255])
    }

    func testPatternOpcodeFails() {
        var p = v2(w: 8, h: 1)
        p.u16(0x0012)
        XCTAssertThrowsError(try PICT.decode(p.d))
    }

    func testEndWithoutImageFails() {
        var p = v2(w: 8, h: 1)
        p.u16(0x00FF)
        XCTAssertThrowsError(try PICT.decode(p.d))
    }

    func testFrameComesFromPicFrameNotExtendedHeader() throws {
        // A 144-dpi style ext header whose srcRect is twice the frame.
        var p = W()
        p.u16(0); p.rect(0, 0, 1, 8)
        p.u16(0x0011); p.u16(0x02FF)
        p.u16(0x0C00); p.u32(0xFFFE0000); p.u32(0); p.u32(0)
        p.rect(0, 0, 2, 16); p.u32(0)
        p.u16(0x0090); p.u16(1); p.rect(0, 0, 1, 8)
        srcDstMode(&p, w: 8, h: 1)
        p.u8(0)
        p.align(); p.u16(0x00FF)
        let s = try PICT.decode(p.d)
        XCTAssertEqual(s.surfaceWidth, 8)
        XCTAssertEqual(s.surfaceHeight, 1)
    }

    func testTenByteClipRegionOverridesFrame() throws {
        var p = v2(w: 16, h: 4)
        p.u16(0x0001); p.u16(10); p.rect(0, 0, 1, 8)
        p.u16(0x0090); p.u16(1); p.rect(0, 0, 1, 8)
        srcDstMode(&p, w: 8, h: 1)
        p.u8(0)
        p.align(); p.u16(0x00FF)
        let s = try PICT.decode(p.d)
        XCTAssertEqual(s.surfaceWidth, 8)
        XCTAssertEqual(s.surfaceHeight, 1)
    }

    func testVersionOneBitsRect() throws {
        var p = W()
        p.u16(0); p.rect(0, 0, 1, 8)
        p.u8(0x11); p.u8(0x01)                                  // v1
        p.u8(0x90); p.u16(1); p.rect(0, 0, 1, 8)               // byte opcodes, no alignment
        srcDstMode(&p, w: 8, h: 1)
        p.u8(0xF0)
        p.u8(0xFF)
        let s = try PICT.decode(p.d)
        XCTAssertEqual(rgb(s, 0, 0), [0, 0, 0, 255])
        XCTAssertEqual(rgb(s, 4, 0), [255, 255, 255, 255])
    }

    #if canImport(ImageIO)
    func testQuickTimeJPEGPict() throws {
        // Encode a 4x2 solid red JPEG with ImageIO.
        let w = 4, h = 2
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { px[i * 4] = 255; px[i * 4 + 3] = 255 }
        let ctx = try XCTUnwrap(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let img = try XCTUnwrap(ctx.makeImage())
        let jpeg = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        var p = v2(w: w, h: h)
        p.u16(0x8200)
        var body = W()
        body.u16(0)                                             // version
        body.bytes([UInt8](repeating: 0, count: 36))           // matrix
        body.u32(0)                                             // matteSize
        body.rect(0, 0, 0, 0)                                   // matteRect
        body.u16(0); body.rect(0, 0, h, w); body.u32(0)         // mode, srcRect, accuracy
        body.u32(0)                                             // maskSize
        // ImageDescription (0x56 bytes)
        var desc = W()
        desc.u32(0x56); desc.bytes(Array("jpeg".utf8)); desc.u32(0); desc.u16(0); desc.u16(0)
        desc.u16(0); desc.u16(0); desc.u32(0); desc.u32(0); desc.u32(0)
        desc.u16(w); desc.u16(h); desc.u32(0x480000); desc.u32(0x480000)
        desc.u32(jpeg.length); desc.u16(1); desc.bytes([UInt8](repeating: 0, count: 32))
        desc.u16(24); desc.u16(0xFFFF)
        XCTAssertEqual(desc.d.count, 0x56)
        body.bytes([UInt8](desc.d)); body.bytes([UInt8](jpeg as Data))
        p.u32(body.d.count); p.bytes([UInt8](body.d))
        p.align(); p.u16(0x00FF)

        let s = try PICT.decode(p.d)
        let c = rgb(s, 1, 1)
        XCTAssertGreaterThan(c[0], 230); XCTAssertLessThan(c[1], 30); XCTAssertEqual(c[3], 255)
    }
    #endif

    func testUnpackExpandsMSBFirst() {
        XCTAssertEqual(PICT.unpack([0b1011_0001], depth: 2), [2, 3, 0, 1])
        XCTAssertEqual(PICT.unpack([0xA5], depth: 4), [0xA, 0x5])
        XCTAssertEqual(PICT.unpack([0x81], depth: 1), [1, 0, 0, 0, 0, 0, 0, 1])
    }
}
