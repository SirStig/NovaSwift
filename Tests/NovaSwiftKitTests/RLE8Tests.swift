import XCTest
import Foundation
@testable import NovaSwiftKit

final class RLE8Tests: XCTestCase {

    /// A sheet whose opaque pixels are exact palette colours (so quantising is lossless).
    private func makeSheet(fw: Int, fh: Int, frames: Int) -> (SpriteSheet, [UInt8]) {
        let pal = RLE8.macSystemPalette
        let columns = min(6, frames), rowsOfFrames = (frames + 5) / 6
        let sw = columns * fw, sh = rowsOfFrames * fh
        var rgba = [UInt8](repeating: 0, count: sw * sh * 4)
        var seed: UInt32 = 12345
        func next() -> Int { seed = seed &* 1664525 &+ 1013904223; return Int(seed >> 16) }
        for f in 0..<frames {
            let ox = (f % 6) * fw, oy = (f / 6) * fh
            for y in 0..<fh {
                for x in 0..<fw {
                    let o = ((oy + y) * sw + ox + x) * 4
                    let opaque: Bool
                    var index = 0
                    switch y % 5 {
                    case 0: opaque = false                                   // empty row
                    case 1: opaque = true; index = 7 + f                      // long flat run
                    case 2: opaque = x % 4 != 0; index = next() % 256          // noise with gaps
                    case 3: opaque = x >= 2 && x < fw - 3; index = 100        // edge transparency
                    default: opaque = true; index = (x / 3) % 2 == 0 ? 0 : 255 // short runs
                    }
                    if opaque {
                        rgba[o] = pal[index * 3]; rgba[o + 1] = pal[index * 3 + 1]; rgba[o + 2] = pal[index * 3 + 2]; rgba[o + 3] = 255
                    }
                }
            }
        }
        return (SpriteSheet(frameWidth: fw, frameHeight: fh, frameCount: frames, columns: columns, rows: rowsOfFrames,
                            surfaceWidth: sw, surfaceHeight: sh, rgba: rgba), rgba)
    }

    func testPaletteShape() {
        let p = RLE8.macSystemPalette
        XCTAssertEqual(p.count, 768)
        XCTAssertEqual(Array(p[0..<3]), [255, 255, 255])          // index 0 white
        XCTAssertEqual(Array(p[255 * 3..<256 * 3]), [0, 0, 0])    // index 255 black
        XCTAssertEqual(Array(p[215 * 3..<216 * 3]), [0xEE, 0, 0]) // first red ramp entry
        XCTAssertEqual(Array(p[245 * 3..<246 * 3]), [0xEE, 0xEE, 0xEE])
        // No duplicate colours (so quantising a decoded sheet is exact).
        var seen = Set<[UInt8]>()
        for i in 0..<256 { XCTAssertTrue(seen.insert(Array(p[i * 3..<i * 3 + 3])).inserted, "duplicate colour at \(i)") }
    }

    func testRoundTrip() throws {
        for (w, h, n) in [(7, 11, 1), (16, 16, 4), (13, 9, 14)] {
            let (sheet, rgba) = makeSheet(fw: w, fh: h, frames: n)
            let data = try RLE8Encoder.encode(sheet)
            let hd = try XCTUnwrap(RLE8.header(data))
            XCTAssertEqual(hd, RLE8.Header(width: w, height: h, depth: 8, paletteID: 0, frameCount: n))
            let back = try RLE8.decode(data)
            XCTAssertEqual(back.frameCount, n)
            XCTAssertEqual(back.surfaceWidth, sheet.surfaceWidth)
            XCTAssertEqual(back.surfaceHeight, sheet.surfaceHeight)
            XCTAssertTrue(back.rgba == rgba, "pixels differ for \(w)x\(h)x\(n)")
            // The stream is 4-byte aligned after the header.
            XCTAssertEqual((data.count - 16) % 4, 0)
        }
    }

    func testHandBuiltStream() throws {
        // 4x2, 1 frame: row 0 = skip 1, literal [5,6,7] (pad 1); row 1 = pattern run of 4.
        var b = [UInt8]()
        b.appendBE16(4); b.appendBE16(2); b.appendBE16(8); b.appendBE16(0); b.appendBE16(1)
        b.append(contentsOf: [0, 0, 0, 0, 0, 0])
        func tok(_ op: UInt8, _ c: Int) { b.append(contentsOf: [op, UInt8(c >> 16 & 255), UInt8(c >> 8 & 255), UInt8(c & 255)]) }
        tok(1, 12); tok(3, 1); tok(2, 3); b.append(contentsOf: [5, 6, 7, 0])
        tok(1, 8); tok(4, 4); b.append(contentsOf: [9, 9, 9, 9])
        tok(0, 0)
        let s = try RLE8.decode(Data(b))
        let pal = RLE8.macSystemPalette
        func px(_ x: Int, _ y: Int) -> [UInt8] { Array(s.rgba[(y * 4 + x) * 4..<(y * 4 + x) * 4 + 4]) }
        func col(_ i: Int) -> [UInt8] { [pal[i * 3], pal[i * 3 + 1], pal[i * 3 + 2], 255] }
        XCTAssertEqual(px(0, 0), [0, 0, 0, 0])
        XCTAssertEqual(px(1, 0), col(5)); XCTAssertEqual(px(2, 0), col(6)); XCTAssertEqual(px(3, 0), col(7))
        for x in 0..<4 { XCTAssertEqual(px(x, 1), col(9)) }
    }

    func testRejectsSixteenBitAndTruncated() {
        var b = [UInt8]()
        b.appendBE16(4); b.appendBE16(2); b.appendBE16(16); b.appendBE16(0); b.appendBE16(1)
        b.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertThrowsError(try RLE8.decode(Data(b)))
        XCTAssertThrowsError(try RLE8.decode(Data([0, 1, 2])))
        XCTAssertNil(RLE8.header(Data([0, 1, 2])))
    }

    func testCustomPaletteAndQuantising() throws {
        // A non-palette colour snaps to the nearest entry (pure red -> index 215-ish red or cube red).
        let sheet = SpriteSheet(frameWidth: 1, frameHeight: 1, frameCount: 1, columns: 1, rows: 1,
                                surfaceWidth: 1, surfaceHeight: 1, rgba: [250, 3, 2, 255])
        let back = try RLE8.decode(try RLE8Encoder.encode(sheet))
        XCTAssertEqual(Array(back.rgba[0..<3]), [0xFF, 0x00, 0x00])
        XCTAssertEqual(back.rgba[3], 255)
    }

    /// Real data: skip cleanly (the stock game and the bundled plug-ins ship no rlë8).
    func testRealRle8IfAny() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let dataDir = url.appendingPathComponent("data")
        guard let en = FileManager.default.enumerator(at: dataDir, includingPropertiesForKeys: nil) else {
            throw XCTSkip("no data/ directory")
        }
        var checked = 0
        for case let f as URL in en where ["rez", "ndat"].contains(f.pathExtension.lowercased()) {
            guard let c = try? ResourceFile.read(contentsOf: f) else { continue }
            for r in c.resources(of: NovaType.rle8) {
                let sheet = try RLE8.decode(r.data)
                XCTAssertGreaterThan(sheet.frameCount, 0)
                checked += 1
            }
            if checked >= 50 { break }
        }
        if checked == 0 { throw XCTSkip("no rlë8 resources in data/") }
    }
}
