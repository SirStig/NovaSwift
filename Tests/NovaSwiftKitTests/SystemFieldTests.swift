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

    /// Hyperspace links are bidirectional (Bible: "the player can make hyperspace
    /// jumps **back and forth** between them"), so the data declares each pair
    /// from whichever end it likes. This is the exact shape that stranded testers:
    /// HJG-1034 (#145) lists only the first Tuatha variant (#185), while the
    /// bit-gated replacements #762-#764 list #145 and are listed by nobody. Read
    /// one-way, New Ireland vanished from the map the moment the storyline swapped
    /// the variant in.
    func testSystemNeighborsClosesOneWayLinksBothWays() {
        func syst(_ id: Int, name: String, links: [Int]) -> Resource {
            var b = [UInt8](repeating: 0, count: 428)
            for i in 0..<16 { put16(&b, 4 + i * 2, -1) }
            for (i, l) in links.prefix(16).enumerated() { put16(&b, 4 + i * 2, l) }
            return Resource(type: NovaType.syst, id: id, name: name, data: Data(b))
        }
        var col = ResourceCollection()
        col.add(syst(145, name: "HJG-1034", links: [185]))
        col.add(syst(185, name: "Tuatha", links: [145]))
        col.add(syst(762, name: "Tuatha", links: [145]))     // declared from this end only
        let game = NovaGame(col)

        XCTAssertEqual(game.systemNeighbors(145), [185, 762],
                       "a link declared only by #762 still lets you jump *into* it from #145")
        XCTAssertEqual(game.systemNeighbors(762), [145])
        XCTAssertEqual(game.systemNeighbors(185), [145])
        XCTAssertEqual(game.systemNeighbors(999), [], "an unknown system has no neighbours")
    }

    func testSystemNeighborsDropsSelfLinksAndDeduplicates() {
        var b = [UInt8](repeating: 0, count: 428)
        for i in 0..<16 { put16(&b, 4 + i * 2, -1) }
        put16(&b, 4, 128)          // self-link
        put16(&b, 6, 129)
        put16(&b, 8, 129)          // duplicate
        var col = ResourceCollection()
        col.add(Resource(type: NovaType.syst, id: 128, name: "A", data: Data(b)))
        XCTAssertEqual(NovaGame(col).systemNeighbors(128), [129])
    }

    func testBackgroundColorDecode() {
        var b = [UInt8](repeating: 0, count: 428)
        // BkgndColor @142: 0x00RRGGBB — the murky Auroran red 0x0019090F.
        b[142] = 0x00; b[143] = 0x19; b[144] = 0x09; b[145] = 0x0F
        let s = SystRes(Resource(type: NovaType.syst, id: 128, name: "Neb", data: Data(b)))
        XCTAssertEqual(s.backgroundColor, NovaColor(r: 0x19, g: 0x09, b: 0x0F))
    }
}
