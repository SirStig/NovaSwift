import XCTest
@testable import NovaSwiftKit

final class ClassicIconTests: XCTestCase {
    private func px(_ s: SpriteSheet, _ x: Int, _ y: Int) -> [UInt8] {
        let o = (y * s.surfaceWidth + x) * 4
        return Array(s.rgba[o..<o + 4])
    }

    func testICNHashUsesMask() throws {
        // Image: top-left pixel set. Mask: only the first row set.
        var d = Data(count: 256)
        d[0] = 0x80
        for i in 0..<4 { d[128 + i] = 0xFF }
        let s = try ClassicIcon.decode(type: NovaSwiftKit.FourCharCode("ICN#")!, data: d)
        XCTAssertEqual(s.frameWidth, 32); XCTAssertEqual(s.frameHeight, 32)
        XCTAssertEqual(px(s, 0, 0), [0, 0, 0, 255])         // black, opaque
        XCTAssertEqual(px(s, 1, 0), [255, 255, 255, 255])   // white, opaque
        XCTAssertEqual(px(s, 0, 1)[3], 0)                   // outside mask
    }

    func testIcl8UsesSystemPaletteAndCompanionMask() throws {
        var d = Data(count: 1024)
        d[0] = 255                                          // black in 'clut' 8
        var mask = Data(count: 256)
        mask[128] = 0x80                                    // only (0,0) visible
        let s = try ClassicIcon.decode(type: NovaSwiftKit.FourCharCode("icl8")!, data: d, mask: mask)
        XCTAssertEqual(px(s, 0, 0), [0, 0, 0, 255])
        XCTAssertEqual(px(s, 1, 0), [255, 255, 255, 0])     // index 0 = white, masked out
        XCTAssertEqual(ClassicIcon.maskType(for: NovaSwiftKit.FourCharCode("icl8")!), NovaSwiftKit.FourCharCode("ICN#"))
    }

    func testIcl4NibblesAndPatternList() throws {
        var d = Data(count: 512)
        d[0] = 0x0F                                         // (0,0)=white, (1,0)=black
        let s = try ClassicIcon.decode(type: NovaSwiftKit.FourCharCode("icl4")!, data: d)
        XCTAssertEqual(px(s, 0, 0), [255, 255, 255, 255])
        XCTAssertEqual(px(s, 1, 0), [0, 0, 0, 255])

        let pats = Data([0, 2] + [UInt8](repeating: 0xFF, count: 8) + [UInt8](repeating: 0, count: 8))
        let p = try ClassicIcon.decode(type: NovaSwiftKit.FourCharCode("PAT#")!, data: pats)
        XCTAssertEqual(p.frameCount, 2)
        XCTAssertEqual(px(p, 0, 0), [0, 0, 0, 255])
        XCTAssertEqual(px(p, 8, 0), [255, 255, 255, 255])
    }

    func testTruncatedIsRejected() {
        XCTAssertThrowsError(try ClassicIcon.decode(type: NovaSwiftKit.FourCharCode("ICN#")!, data: Data(count: 100)))
    }

    func testEditorKinds() {
        XCTAssertEqual(ResourceSchemas.editorKind(for: GraphicsEnhancementType.blob), .graphic)
        XCTAssertEqual(ResourceSchemas.editorKind(for: NovaSwiftKit.FourCharCode("TEXT")!), .text)
        XCTAssertEqual(ResourceSchemas.editorKind(for: NovaSwiftKit.FourCharCode("icl8")!), .graphic)
    }
}
