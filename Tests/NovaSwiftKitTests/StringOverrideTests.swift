import XCTest
import Foundation
@testable import NovaSwiftKit

/// `STR ` display-name patches, EVNova.ini overrides and the l33t easter egg
/// (loading_unknown R3-R5). Synthetic data only.
final class StringOverrideTests: XCTestCase {
    private func pstr(_ s: String) -> Data { Data([UInt8(s.utf8.count)]) + Data(s.utf8) }

    private func strList(_ id: Int, _ items: [String]) -> Resource {
        var d = Data([UInt8(items.count >> 8), UInt8(items.count & 0xff)])
        for i in items { d += pstr(i) }
        return Resource(type: NovaType.strList, id: id, data: d)
    }

    private func game(_ extra: [Resource]) -> NovaGame {
        var c = ResourceCollection()
        for r in extra { c.add(r) }
        return NovaGame(c)
    }

    func testStrOverridesWinOverStrListAndEmptyCounts() {
        let g = game([
            strList(4001, ["a", "b"]),
            Resource(type: FourCharCode("STR ")!, id: 9101, data: pstr("X")),
            strList(4002, ["short0", "short1"]),
            Resource(type: FourCharCode("STR ")!, id: 9200, data: Data()),   // present but empty
            strList(4003, ["f0", "f1"]),
            strList(4000, ["Food", "Industrial"]),
            Resource(type: FourCharCode("STR ")!, id: 9000, data: pstr("Rations")),
        ])
        XCTAssertEqual(g.cargoTypeName(0), "a")
        XCTAssertEqual(g.cargoTypeName(1), "X")
        XCTAssertEqual(g.cargoShortName(0), "", "an empty STR  is still an override")
        XCTAssertEqual(g.cargoShortName(1), "short1")
        XCTAssertEqual(g.cargoAbbreviation(1), "f1")
        XCTAssertNil(g.cargoAbbreviation(6), "only 6 abbreviations")
        XCTAssertEqual(g.commodityName(.food), "Rations")
        XCTAssertEqual(g.commodityName(.industrial), "Industrial")
        XCTAssertNil(g.cargoTypeName(5))
    }

    func testIniOverridesApplyBeforeLookup() {
        var g = game([strList(137, ["one", "two", "three"])])
        let ini = "; comment\r\n[137]\r\nS2 = \"dos\"\r\nS5=\"cinco\"\r\n[999]\r\nS1=\"\"\r\n"
        g.iniStringOverrides = IniStringOverrides.parse(Data(ini.utf8))
        XCTAssertEqual(g.stringList(137)?.string(at: 1), "one")
        XCTAssertEqual(g.stringList(137)?.string(at: 2), "dos")
        XCTAssertEqual(g.stringList(137)?.string(at: 5), "cinco")
        XCTAssertNil(g.stringList(999), "no override creates a list that doesn't exist")
        XCTAssertNil(IniStringOverrides.parse(Data(ini.utf8))[999], "empty values don't override")
    }

    func testLeetSpeak() {
        XCTAssertEqual(NovaDescFormatter.leetSpeak("You are here") { 0 }, "j00 4r3 h3r3")
        XCTAssertEqual(NovaDescFormatter.leetSpeak("You are here") { 2 }, "j00 are here")
        XCTAssertEqual(NovaDescFormatter.leetSpeak("see you", roll: { 2 }), "see you", "'you' within the last 4 characters stays")
        XCTAssertEqual(NovaDescFormatter.leetSpeak("<OSN> Ai", roll: { 0 }), "<OSN> 41", "tags are left alone")
    }
}
