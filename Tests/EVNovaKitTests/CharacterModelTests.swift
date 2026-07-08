import XCTest
import Foundation
@testable import EVNovaKit

/// Decodes a synthetic `chär` laid out exactly like the real base-game #128
/// ".Trader" (362 bytes), so the test proves the field offsets without shipping
/// any copyrighted data.
final class CharacterModelTests: XCTestCase {

    private func word(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = v < 0 ? v + 0x10000 : v
        b[off] = UInt8((u >> 8) & 0xFF); b[off + 1] = UInt8(u & 0xFF)
    }
    private func long(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt32(bitPattern: Int32(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 24); b[off + 1] = UInt8((u >> 16) & 0xFF)
        b[off + 2] = UInt8((u >> 8) & 0xFF); b[off + 3] = UInt8(u & 0xFF)
    }
    private func str(_ b: inout [UInt8], _ off: Int, _ s: String) {
        for (i, c) in Array(s.utf8).enumerated() { b[off + i] = c }
    }

    /// The real #128 ".Trader" layout.
    private func traderChar() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 362)
        long(&b, 0, 25000)                 // cash
        word(&b, 4, 128)                   // ship
        for (i, s) in [128, 136, 170, 184].enumerated() { word(&b, 6 + i * 2, s) }
        for i in 0..<4 { word(&b, 14 + i * 2, -1) }   // govts (unused)
        for i in 0..<4 { word(&b, 22 + i * 2, -1) }   // statuses
        word(&b, 30, 0)                    // kills
        for (i, p) in [8200, 8201, 8202, -1].enumerated() { word(&b, 32 + i * 2, p) }
        for (i, d) in [45, 45, 45, -1].enumerated() { word(&b, 40 + i * 2, d) }
        word(&b, 48, -1)                   // intro text (none)
        word(&b, 306, 1)                   // flags: default character
        word(&b, 308, 23); word(&b, 310, 6); word(&b, 312, 1177)
        str(&b, 330, " NC")                // date suffix
        return b
    }

    func testTraderScenarioDecodes() throws {
        let fork = ClassicForkBuilder.build(type: "chär", resources: [
            (id: 128, name: ".Trader", payload: Data(traderChar())),
        ])
        let game = NovaGame(try ResourceFile.read(fork))
        let ch = try XCTUnwrap(game.character(128))

        XCTAssertEqual(ch.cash, 25000)
        XCTAssertEqual(ch.startingCredits, 25000)           // legacy accessor
        XCTAssertEqual(ch.shipID, 128)
        XCTAssertEqual(ch.startingShip, 128)                // legacy accessor
        XCTAssertEqual(ch.startSystems, [128, 136, 170, 184])
        XCTAssertEqual(ch.startingSystem, 128)              // legacy accessor
        XCTAssertEqual(ch.kills, 0)
        XCTAssertEqual(ch.introSlides.map(\.pictID), [8200, 8201, 8202])
        XCTAssertEqual(ch.introSlides.map(\.delaySeconds), [45, 45, 45])
        XCTAssertNil(ch.introTextID)
        XCTAssertTrue(ch.govtStatuses.isEmpty)
        XCTAssertEqual(ch.startDay, 23)
        XCTAssertEqual(ch.startMonth, 6)
        XCTAssertEqual(ch.startYear, 1177)
        XCTAssertEqual(ch.dateSuffix, " NC")
        XCTAssertTrue(ch.isDefault)
        XCTAssertTrue(ch.isHidden)                          // name starts "."
        XCTAssertEqual(ch.displayName, "Trader")
    }

    func testSelectableFallsBackToHiddenWhenOnlyOne() throws {
        // Only a "."-hidden scenario exists → it's still selectable (else empty picker).
        let fork = ClassicForkBuilder.build(type: "chär", resources: [
            (id: 128, name: ".Trader", payload: Data(traderChar())),
        ])
        let game = NovaGame(try ResourceFile.read(fork))
        XCTAssertEqual(game.selectableScenarios().map(\.id), [128])
    }

    func testVisibleScenariosHideDottedOnes() throws {
        var visible = traderChar(); word(&visible, 306, 0)
        let fork = ClassicForkBuilder.build(type: "chär", resources: [
            (id: 128, name: ".Trader", payload: Data(traderChar())),
            (id: 129, name: "Warrior", payload: Data(visible)),
        ])
        let game = NovaGame(try ResourceFile.read(fork))
        // With a visible scenario present, the "."-hidden one drops out of the picker.
        XCTAssertEqual(game.selectableScenarios().map(\.displayName), ["Warrior"])
    }
}
