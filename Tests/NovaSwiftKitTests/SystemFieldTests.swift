import XCTest
@testable import NovaSwiftKit

/// Locks in the newly-decoded sÿst sensor/visual fields (Interference@108,
/// BkgndColor@142, Murk@146), whose offsets were confirmed empirically against
/// the shipped data.
final class SystemFieldTests: XCTestCase {
    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }

    func testInterferenceAndMurkDecode() {
        var b = [UInt8](repeating: 0, count: 428)
        put16(&b, 106, 8)     // asteroids
        put16(&b, 108, 75)    // Interference
        put16(&b, 146, 40)    // Murk
        let s = SystRes(Resource(type: NovaType.syst, id: 128, name: "Neb", data: Data(b)))
        XCTAssertEqual(s.interference, 75)
        XCTAssertEqual(s.murk, 40)
        XCTAssertEqual(s.backgroundColor, NovaColor(r: 0, g: 0, b: 0),
                       "zeroed BkgndColor is the Bible's \"pure black\"")
    }

    func testBackgroundColorDecode() {
        var b = [UInt8](repeating: 0, count: 428)
        // BkgndColor @142: 0x00RRGGBB — the murky Auroran red 0x0019090F.
        b[142] = 0x00; b[143] = 0x19; b[144] = 0x09; b[145] = 0x0F
        let s = SystRes(Resource(type: NovaType.syst, id: 128, name: "Neb", data: Data(b)))
        XCTAssertEqual(s.backgroundColor, NovaColor(r: 0x19, g: 0x09, b: 0x0F))
    }
}
