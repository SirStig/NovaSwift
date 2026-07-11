import XCTest
@testable import NovaSwiftKit

/// Byte-level decode test for the nebula (`nëbu`) resource. The layout was
/// reverse-engineered from the base data (Nova Data 5, ids 128–131): four
/// leading big-endian int16s — x, y, width, height — a top-left box in the
/// `sÿst` coordinate space. These assertions pin the real values so the layout
/// can't silently regress.
final class NebulaModelTests: XCTestCase {

    private func put16(_ buf: inout [UInt8], _ off: Int, _ val: Int) {
        let v = UInt16(bitPattern: Int16(truncatingIfNeeded: val))
        buf[off] = UInt8(v >> 8); buf[off + 1] = UInt8(v & 0xff)
    }

    /// Holpa Nebula (id 128): real bytes 01 ae 00 2d 00 fb 01 2a.
    func testHolpaNebulaDecodes() {
        var b = [UInt8](repeating: 0, count: 534)
        put16(&b, 0, 430); put16(&b, 2, 45); put16(&b, 4, 251); put16(&b, 6, 298)
        let n = NebuRes(Resource(type: NovaType.nebula, id: 128, name: "Holpa Nebula", data: Data(b)))
        XCTAssertEqual(n.x, 430)
        XCTAssertEqual(n.y, 45)
        XCTAssertEqual(n.width, 251)
        XCTAssertEqual(n.height, 298)
        XCTAssertEqual(n.name, "Holpa Nebula")
    }

    /// L-1551 (id 131): real bytes ff 76 ff 1e 00 92 00 47 — negative origin,
    /// so the decode must be signed.
    func testNegativeOriginNebulaDecodes() {
        var b = [UInt8](repeating: 0, count: 534)
        put16(&b, 0, -138); put16(&b, 2, -226); put16(&b, 4, 146); put16(&b, 6, 71)
        let n = NebuRes(Resource(type: NovaType.nebula, id: 131, name: "L-1551", data: Data(b)))
        XCTAssertEqual(n.x, -138)
        XCTAssertEqual(n.y, -226)
        XCTAssertEqual(n.width, 146)
        XCTAssertEqual(n.height, 71)
    }

    /// The highest-res PICT id for each nebula's 7-slot zoom block.
    func testNebulaImageIDConvention() {
        let game = NovaGame(ResourceCollection())
        XCTAssertEqual(game.nebulaImageID(index: 0), 9502)  // Holpa
        XCTAssertEqual(game.nebulaImageID(index: 1), 9509)  // Obatta
        XCTAssertEqual(game.nebulaImageID(index: 2), 9516)  // Rochak
        XCTAssertEqual(game.nebulaImageID(index: 3), 9523)  // L-1551
    }
}
