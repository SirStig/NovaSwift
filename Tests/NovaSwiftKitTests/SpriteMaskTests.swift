import XCTest
@testable import NovaSwiftKit

/// WP-17: collision masks built straight from the `rlëD` opcode stream.
final class SpriteMaskTests: XCTestCase {

    /// A 3×2, two-frame sprite. Frame 0: row 0 = transparent, opaque, opaque;
    /// row 1 = opaque (run). Frame 1: one opaque pixel at (2, 1).
    private func sampleRLE() -> Data {
        var d = Data()
        func u16(_ v: UInt16) { d.append(UInt8(v >> 8)); d.append(UInt8(v & 0xff)) }
        func u32(_ v: UInt32) { u16(UInt16(v >> 16)); u16(UInt16(v & 0xffff)) }
        func op(_ code: UInt32, _ count: Int) { u32(code << 24 | UInt32(count)) }
        u16(3); u16(2); u16(16); u16(0); u16(2); d.append(contentsOf: [UInt8](repeating: 0, count: 6))
        // Frame 0
        op(1, 0); op(3, 2); op(2, 4); u16(0x7fff); u16(0x7fff)
        op(1, 0); op(4, 2); u32(0x7c00_7c00)
        op(0, 0)
        // Frame 1
        op(1, 0)
        op(1, 0); op(3, 4); op(2, 2); u16(0x03e0); u16(0)
        op(0, 0)
        return d
    }

    func testMaskMatchesDecodedAlpha() throws {
        let data = sampleRLE()
        let mask = try RLED.decodeMasks(data)
        let sheet = try RLED.decode(data)
        XCTAssertEqual(mask.width, 3); XCTAssertEqual(mask.height, 2); XCTAssertEqual(mask.frameCount, 2)
        for f in 0..<2 { for y in 0..<2 { for x in 0..<3 {
            let col = f % SpriteSheet.framesPerRow
            let idx = (y * sheet.surfaceWidth + col * 3 + x) * 4 + 3
            XCTAssertEqual(mask.isOpaque(frame: f, x: x, y: y), sheet.rgba[idx] > 0, "f\(f) (\(x),\(y))")
        } } }
        XCTAssertFalse(mask.isOpaque(frame: 0, x: 0, y: 0))
        XCTAssertEqual(mask.opaqueCount(frame: 1), 1)
    }

    func testOverlapNeedsASharedOpaquePixel() throws {
        let mask = try RLED.decodeMasks(sampleRLE())
        // Frame 1's lone pixel (2,1) placed on frame 0's transparent (0,0): miss.
        XCTAssertFalse(mask.overlaps(frame: 0, left: 0, top: 0, mask, otherFrame: 1, otherLeft: -2, otherTop: -1))
        // ... and on frame 0's opaque (1,0): hit.
        XCTAssertTrue(mask.overlaps(frame: 0, left: 0, top: 0, mask, otherFrame: 1, otherLeft: -1, otherTop: -1))
        // Rectangles that only share an edge never overlap.
        XCTAssertFalse(mask.overlaps(frame: 0, left: 0, top: 0, mask, otherFrame: 0, otherLeft: 3, otherTop: 0))
    }

    /// Wide masks cross 64-bit word boundaries at arbitrary offsets.
    func testOverlapAcrossWordBoundaries() {
        let w = 150, h = 3
        let words = (w + 63) >> 6
        var a = [UInt64](repeating: 0, count: words * h)
        a[1 * words + 2] |= 1 << (130 - 128)       // A opaque at (130, 1)
        let ma = SpriteMaskSet(width: w, height: h, frameCount: 1, bits: a)
        var b = [UInt64](repeating: 0, count: words * h)
        b[0 * words + 1] |= 1 << (70 - 64)          // B opaque at (70, 0)
        let mb = SpriteMaskSet(width: w, height: h, frameCount: 1, bits: b)
        XCTAssertTrue(ma.overlaps(frame: 0, left: 0, top: 0, mb, otherFrame: 0, otherLeft: 60, otherTop: 1))
        // A's run ends where B's next one starts: the original's run walk
        // reports a hit for that order (oracle, 0x00472190), not for the reverse.
        XCTAssertTrue(ma.overlaps(frame: 0, left: 0, top: 0, mb, otherFrame: 0, otherLeft: 61, otherTop: 1))
        XCTAssertFalse(mb.overlaps(frame: 0, left: 61, top: 1, ma, otherFrame: 0, otherLeft: 0, otherTop: 0))
        XCTAssertFalse(ma.overlaps(frame: 0, left: 0, top: 0, mb, otherFrame: 0, otherLeft: 62, otherTop: 1))
        XCTAssertTrue(mb.overlaps(frame: 0, left: 60, top: 1, ma, otherFrame: 0, otherLeft: 0, otherTop: 0))
    }

    /// Every stock `rlëD`: the mask is exactly the decoded sheet's alpha.
    func testStockMasksMatchDecodedSheets() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = GameLibrary.discoverResourceFiles(in: repo.appendingPathComponent("data/base"))
        guard !files.isEmpty else { throw XCTSkip("No stock data under data/base") }
        let game = NovaGame(try GameLibrary.merge(baseFiles: files))
        var checked = 0
        for res in game.resources.resources(of: NovaType.rleD).prefix(40) {
            guard let sheet = try? RLED.decode(res.data) else { continue }
            let mask = try RLED.decodeMasks(res.data)
            XCTAssertEqual(mask.frameCount, sheet.frameCount)
            for f in Swift.stride(from: 0, to: sheet.frameCount, by: max(1, sheet.frameCount / 4)) {
                let col = f % SpriteSheet.framesPerRow, row = f / SpriteSheet.framesPerRow
                for y in 0..<sheet.frameHeight { for x in 0..<sheet.frameWidth {
                    let idx = ((row * sheet.frameHeight + y) * sheet.surfaceWidth + col * sheet.frameWidth + x) * 4 + 3
                    if mask.isOpaque(frame: f, x: x, y: y) != (sheet.rgba[idx] > 0) {
                        return XCTFail("rlëD \(res.id) frame \(f) differs at (\(x),\(y))")
                    }
                } }
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 10)
    }
}
