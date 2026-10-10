import XCTest
@testable import NovaSwiftKit

/// The PICT + mask sprite fallback (0x00474ab0) and the spïn indirection the
/// original uses for every stellar (Graphic + 1000, 0x004b0a30).
final class PICTSpriteSheetTests: XCTestCase {

    /// A w×h RGBA sheet where pixel (x, y) is (x, y, 7) — easy to locate.
    private func coordImage(_ w: Int, _ h: Int) -> SpriteSheet {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let i = (y * w + x) * 4; px[i] = UInt8(x); px[i + 1] = UInt8(y); px[i + 2] = 7 } }
        return SpriteSheet(frameWidth: w, frameHeight: h, frameCount: 1, columns: 1, rows: 1,
                           surfaceWidth: w, surfaceHeight: h, rgba: px)
    }

    private func solid(_ w: Int, _ h: Int, _ v: UInt8) -> SpriteSheet {
        var px = [UInt8](repeating: v, count: w * h * 4)
        for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
        return SpriteSheet(frameWidth: w, frameHeight: h, frameCount: 1, columns: 1, rows: 1,
                           surfaceWidth: w, surfaceHeight: h, rgba: px)
    }

    private func pixel(_ s: SpriteSheet, frame: Int, _ x: Int, _ y: Int) -> [UInt8] {
        let ox = (frame % s.columns) * s.frameWidth, oy = (frame / s.columns) * s.frameHeight
        let i = ((oy + y) * s.surfaceWidth + ox + x) * 4
        return Array(s.rgba[i..<i + 4])
    }

    func testThreeByTwoGridDefaultsToSixFramesRowMajor() throws {
        let sheet = try PICTSpriteSheet.slice(image: coordImage(30, 16), mask: solid(30, 16, 255),
                                              frameWidth: 10, frameHeight: 8, frameCount: 0)
        XCTAssertEqual(sheet.frameCount, 6)
        // Frame 4 starts at (10, 8) in the PICT.
        XCTAssertEqual(pixel(sheet, frame: 4, 0, 0), [10, 8, 7, 255])
        XCTAssertEqual(pixel(sheet, frame: 2, 3, 1), [23, 1, 7, 255])
    }

    func testMaskWhiteIsOpaqueBlackAndGreyAreClear() throws {
        var mask = solid(2, 1, 0)
        var px = mask.rgba
        px[0] = 255; px[1] = 255; px[2] = 255                  // (0,0) white
        px[4] = 0xF0; px[5] = 0xF0; px[6] = 0xF0               // (1,0) light grey
        mask = SpriteSheet(frameWidth: 2, frameHeight: 1, frameCount: 1, columns: 1, rows: 1,
                           surfaceWidth: 2, surfaceHeight: 1, rgba: px)
        let sheet = try PICTSpriteSheet.slice(image: coordImage(2, 1), mask: mask,
                                              frameWidth: 2, frameHeight: 1, frameCount: 1)
        XCTAssertEqual(pixel(sheet, frame: 0, 0, 0)[3], 255)
        XCTAssertEqual(pixel(sheet, frame: 0, 1, 0)[3], 0)
        // 248 quantises to 31 at 5 bits, so it still counts as white.
        XCTAssertTrue(PICTSpriteSheet.maskIsOpaque(248, 248, 248))
        XCTAssertFalse(PICTSpriteSheet.maskIsOpaque(247, 255, 255))
    }

    func testFrameCountPastTheImageEdgeFails() {
        XCTAssertThrowsError(try PICTSpriteSheet.slice(image: coordImage(30, 16), mask: solid(30, 16, 255),
                                                       frameWidth: 10, frameHeight: 8, frameCount: 7))
    }

    func testGapsShiftFrameOrigins() throws {
        let sheet = try PICTSpriteSheet.slice(image: coordImage(22, 18), mask: solid(22, 18, 255),
                                              frameWidth: 10, frameHeight: 8, frameCount: 4, gapX: 2, gapY: 2)
        XCTAssertEqual(pixel(sheet, frame: 1, 0, 0), [12, 0, 7, 255])
        XCTAssertEqual(pixel(sheet, frame: 2, 0, 0), [0, 10, 7, 255])
    }

    func testCollisionMasksFollowAlpha() throws {
        let sheet = try PICTSpriteSheet.slice(image: coordImage(20, 8), mask: solid(20, 8, 255),
                                              frameWidth: 10, frameHeight: 8, frameCount: 0)
        let masks = PICTSpriteSheet.masks(of: sheet)
        XCTAssertEqual(masks.frameCount, 2)
        XCTAssertEqual(masks.opaqueCount(frame: 1), 80)
    }

    // MARK: Stock data

    private func stockGame() throws -> NovaGame {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = GameLibrary.discoverResourceFiles(in: repo.appendingPathComponent("data/base"))
        guard !files.isEmpty else { throw XCTSkip("No stock data under data/base") }
        return NovaGame(try GameLibrary.merge(baseFiles: files))
    }

    /// Every stock stellar goes through spïn Graphic + 1000 to an existing
    /// rlëD. The port's old stock-only shortcut (rlëD 2000 + g, −1 above 2058)
    /// drew the wrong art for 25 of them: Graphic 59 is spïn 1059 → rlëD 2300,
    /// not 2058, and spöb 472's spïn points at rlëD 2000.
    func testStockStellarsResolveThroughSpinPlusThousand() throws {
        let game = try stockGame()
        var checked = 0
        for spob in game.spobs() {
            let spin = try XCTUnwrap(game.spin(spob.graphicSpinID), "spöb \(spob.id)")
            XCTAssertNotNil(game.resources.resource(NovaType.rleD, spin.spriteID), "spöb \(spob.id)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 100)
        XCTAssertEqual(game.spin(1059)?.spriteID, 2300)
        XCTAssertEqual(game.spob(472).map { game.spin($0.graphicSpinID)?.spriteID }, 2000)
    }

    func testStockMenuButtonsAreSpin600Through605() throws {
        let game = try stockGame()
        for i in 0..<6 {
            XCTAssertEqual(game.spin(600 + i)?.spriteID, 8050 + i)
            XCTAssertNotNil(game.spinSheet(600 + i))
        }
    }
}
