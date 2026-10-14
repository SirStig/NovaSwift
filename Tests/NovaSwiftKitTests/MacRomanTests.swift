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

    /// Every type the importer's "missing essentials" check needs (the Linux "not a complete set" bug).
    func testEssentialTypeCodes() {
        XCTAssertEqual(NovaType.spob.bytes, [0x73, 0x70, 0x9A, 0x62])
        XCTAssertEqual(NovaType.outfit.bytes, [0x6F, 0x9F, 0x74, 0x66])
        XCTAssertEqual(NovaType.weapon.bytes, [0x77, 0x91, 0x61, 0x70])
        XCTAssertEqual(NovaType.rleD.bytes, [0x72, 0x6C, 0x91, 0x44])
    }

    #if canImport(Darwin)
    /// The table must match Apple's own Mac Roman converter byte for byte.
    func testMatchesFoundationOnDarwin() {
        for b in 0...255 {
            XCTAssertEqual(MacRoman.decode([UInt8(b)]), String(bytes: [UInt8(b)], encoding: .macOSRoman), "byte \(b)")
        }
    }
    #endif

    func testUnmappableReturnsNil() {
        XCTAssertNil(MacRoman.encode("日本"))
    }
}
