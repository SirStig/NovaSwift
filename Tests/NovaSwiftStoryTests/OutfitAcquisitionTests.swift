import XCTest
import Foundation
import NovaSwiftKit
@testable import NovaSwiftStory

/// Acquisition-time outfit effects on the pilot: map reveal (ModType 16) into
/// the charted set, legal-record clearing (ModType 21), and the save-format
/// compatibility of the new `chartedSystems` field.
final class OutfitAcquisitionTests: XCTestCase {

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }
    private func outfit(_ id: Int, modType: Int, modVal: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 1028)
        put16(&b, 4, 1)                                // tech
        put16(&b, 6, modType); put16(&b, 8, modVal)   // primary modifier
        return Resource(type: NovaType.outfit, id: id, name: "Item\(id)", data: Data(b))
    }
    private func system(_ id: Int, links: [Int]) -> Resource {
        var b = [UInt8](repeating: 0, count: 420)
        for (i, l) in links.prefix(16).enumerated() { put16(&b, 4 + i * 2, l) }
        put16(&b, 102, -1)
        return Resource(type: NovaType.syst, id: id, name: "Sys\(id)", data: Data(b))
    }

    private func mapGame() -> NovaGame {
        var col = ResourceCollection()
        col.add(system(128, links: [129]))
        col.add(system(129, links: [128, 130]))
        col.add(system(130, links: [129]))
        col.add(outfit(500, modType: 16, modVal: 1))   // map: 1 jump
        return NovaGame(col)
    }

    func testMapAcquisitionChartsScopedSystems() {
        var player = PlayerState(currentSystem: 128)
        let game = mapGame()
        player.applyOutfitAcquisition(game.outfit(500)!, game: game, fromSystem: 128)
        XCTAssertEqual(player.chartedSystems, [128, 129])
        XCTAssertTrue(player.isSystemCharted(129))
        XCTAssertFalse(player.isSystemCharted(130), "2 jumps out — beyond a 1-jump map")
    }

    /// A charted system is NOT an explored one: buying a map must not satisfy the
    /// NCB `Exxx` "have you been there" test.
    func testMapAcquisitionDoesNotMarkExplored() {
        var player = PlayerState(currentSystem: 128)
        let game = mapGame()
        player.applyOutfitAcquisition(game.outfit(500)!, game: game, fromSystem: 128)
        XCTAssertFalse(player.isSystemExplored(129))
        XCTAssertEqual(player.exploredSystems, [128], "only the start system is explored")
    }

    func testCleanRecordClearsNamedGovtOnly() {
        var col = ResourceCollection()
        col.add(outfit(600, modType: 21, modVal: 128))   // clean record with govt 128
        let game = NovaGame(col)
        var player = PlayerState(currentSystem: 128)
        player.legalRecord = [128: -50, 129: -10]
        player.applyOutfitAcquisition(game.outfit(600)!, game: game, fromSystem: 128)
        XCTAssertNil(player.legalRecord[128], "record with 128 wiped")
        XCTAssertEqual(player.legalRecord[129], -10, "record with 129 untouched")
    }

    func testCleanRecordMinusOneClearsAll() {
        var col = ResourceCollection()
        col.add(outfit(601, modType: 21, modVal: -1))    // clean record with all
        let game = NovaGame(col)
        var player = PlayerState(currentSystem: 128)
        player.legalRecord = [128: -50, 129: -10, 130: 5]
        player.applyOutfitAcquisition(game.outfit(601)!, game: game, fromSystem: 128)
        XCTAssertTrue(player.legalRecord.isEmpty, "-1 clears every government")
    }

    // MARK: chartedSystems save compatibility

    func testChartedSystemsRoundTrips() throws {
        var player = PlayerState(currentSystem: 128)
        player.chartSystems([200, 201, 202])
        let data = try JSONEncoder().encode(player)
        let decoded = try JSONDecoder().decode(PlayerState.self, from: data)
        XCTAssertEqual(decoded.chartedSystems, [200, 201, 202])
    }

    /// A legacy save written before `chartedSystems` existed must still decode
    /// (the field is optional, exactly like `fuel`/`armor`).
    func testLegacySaveWithoutChartedSystemsDecodes() throws {
        let player = PlayerState(currentSystem: 128)
        let data = try JSONEncoder().encode(player)
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict.removeValue(forKey: "chartedSystems")
        let legacy = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(PlayerState.self, from: legacy)
        XCTAssertNil(decoded.chartedSystems)
        XCTAssertFalse(decoded.isSystemCharted(999))   // nil set → nothing charted
    }
}
