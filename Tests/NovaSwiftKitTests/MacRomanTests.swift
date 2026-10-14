import XCTest
@testable import NovaSwiftKit

final class MacRomanTests: XCTestCase {
    func testNovaTypeCodesUseRawMacRomanBytes() {
        XCTAssertEqual(NovaType.ship.bytes, [0x73, 0x68, 0x95, 0x70])
        XCTAssertEqual(NovaType.syst.bytes, [0x73, 0xD8, 0x73, 0x74])
        XCTAssertEqual(NovaType.ship.stringValue, "shïp")
    }

    func testRoundTripAllBytes() {
        let all = (0...255).map { UInt8($0) }
        XCTAssertEqual(MacRoman.encode(MacRoman.decode(all)), all)
    }

    func testUnmappableReturnsNil() {
        XCTAssertNil(MacRoman.encode("日本"))
    }
}
