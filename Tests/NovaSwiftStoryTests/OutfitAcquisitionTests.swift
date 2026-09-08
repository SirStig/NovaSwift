import XCTest
import Foundation
import NovaSwiftKit
import NovaSwiftEngine
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

    // MARK: charts are consumed, so they can be bought again in the next region

    /// A star chart reveals the systems around *wherever it is bought* — so it
    /// has to be re-buyable at the next port. The stock records only carry
    /// `Max 1` and never set `Flags` 0x0010, which read literally means one
    /// chart per pilot per game: bought once at Earth, greyed out at every other
    /// world forever (exactly what a tester hit). Buying consumes it instead; the
    /// reveal it paid for is already permanent in `chartedSystems`.
    func testChartIsConsumedOnPurchaseSoItCanBeBoughtAgainElsewhere() {
        var col = ResourceCollection()
        col.add(system(128, links: [129]))
        col.add(system(129, links: [128, 130]))
        col.add(system(130, links: [129]))
        var b = [UInt8](repeating: 0, count: 1028)
        put16(&b, 4, 1)                       // tech
        put16(&b, 6, 16); put16(&b, 8, 1)     // ModType 16, 1 jump
        put16(&b, 10, 1)                      // Max 1
        b[14] = 0; b[15] = 0; b[16] = 0x03; b[17] = 0xE8   // cost 1000
        col.add(Resource(type: NovaType.outfit, id: 500, name: "Map", data: Data(b)))
        let game = NovaGame(col)
        let galaxy = Galaxy(game: game)
        let chart = game.outfit(500)!
        XCTAssertTrue(chart.isConsumableChart)

        var player = PlayerState(credits: 10_000, currentSystem: 128)
        XCTAssertTrue(PilotEconomy.buyOutfit(&player, chart, galaxy: galaxy))
        XCTAssertEqual(player.credits, 9_000)
        XCTAssertNil(player.outfits[500], "a chart is a service, not an item in the hold")
        XCTAssertEqual(player.chartedSystems, [128, 129])

        // …and the next port sells one again, revealing its own neighbourhood.
        player.currentSystem = 129
        XCTAssertTrue(PilotEconomy.canBuyOutfit(player, chart, galaxy: galaxy),
                      "Max 1 must not lock a pilot out of every later chart")
        XCTAssertTrue(PilotEconomy.buyOutfit(&player, chart, galaxy: galaxy))
        XCTAssertEqual(player.chartedSystems, [128, 129, 130])

        // One per transaction: a consumed item never accumulates, so a bulk
        // "buy 50" would otherwise charge fifty times for one reveal.
        player.currentSystem = 130
        XCTAssertEqual(PilotEconomy.buyOutfit(&player, chart, count: 50, galaxy: galaxy), 1)
        XCTAssertEqual(player.credits, 7_000)
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
