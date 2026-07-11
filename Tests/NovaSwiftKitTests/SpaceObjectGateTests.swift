import XCTest
@testable import NovaSwiftKit

/// Byte-level decode tests for the `spöb` hypergate/wormhole fields, reverse-
/// engineered and verified against the base data: Flags2 (@30) carries `0x1000`
/// for hypergates and `0x2000` for wormholes, and HyperLink1-8 (@38, eight
/// int16s) hold the connected gates' spöb ids. Real reference: HG-V01 (#1400)
/// has Flags2 `0x1200` and links to 1401 and 1411.
final class SpaceObjectGateTests: XCTestCase {

    private func put16(_ buf: inout [UInt8], _ off: Int, _ val: Int) {
        let v = UInt16(bitPattern: Int16(truncatingIfNeeded: val))
        buf[off] = UInt8(v >> 8); buf[off + 1] = UInt8(v & 0xff)
    }
    private func put32(_ buf: inout [UInt8], _ off: Int, _ val: UInt32) {
        buf[off] = UInt8((val >> 24) & 0xff); buf[off + 1] = UInt8((val >> 16) & 0xff)
        buf[off + 2] = UInt8((val >> 8) & 0xff); buf[off + 3] = UInt8(val & 0xff)
    }

    /// HG-V01: Flags2 0x1200 (hypergate), HyperLinks 1401 & 1411, rest −1.
    func testHypergateDecodesLinks() {
        var b = [UInt8](repeating: 0, count: 1118)
        put32(&b, 30, 0x0000_1200)
        put16(&b, 38, 1401); put16(&b, 40, 1411)
        for i in 2..<8 { put16(&b, 38 + i * 2, -1) }
        let s = SpobRes(Resource(type: NovaType.spob, id: 1400, name: "HG-V01", data: Data(b)))
        XCTAssertTrue(s.isHypergate)
        XCTAssertFalse(s.isWormhole)
        XCTAssertTrue(s.isGate)
        XCTAssertEqual(s.hyperLinks, [1401, 1411])
    }

    /// A base-data wormhole: Flags2 0x2000, all HyperLinks −1 (random connect).
    func testWormholeRandomHasNoLinks() {
        var b = [UInt8](repeating: 0, count: 1118)
        put32(&b, 30, 0x0000_2000)
        for i in 0..<8 { put16(&b, 38 + i * 2, -1) }
        let s = SpobRes(Resource(type: NovaType.spob, id: 465, name: "Wormhole", data: Data(b)))
        XCTAssertTrue(s.isWormhole)
        XCTAssertFalse(s.isHypergate)
        XCTAssertEqual(s.hyperLinks, [])
    }
}
