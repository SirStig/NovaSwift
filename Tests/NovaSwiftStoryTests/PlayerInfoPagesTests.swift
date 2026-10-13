import XCTest
import NovaSwiftKit
@testable import NovaSwiftStory

/// UI-13: the Player Info stat grid reads STR# 2002 and the original's display
/// scales.
final class PlayerInfoPagesTests: XCTestCase {

    private func strList(_ id: Int, _ items: [String]) -> Resource {
        var b: [UInt8] = [UInt8(items.count >> 8), UInt8(items.count & 0xff)]
        for s in items { let bytes = Array(s.utf8); b.append(UInt8(bytes.count)); b += bytes }
        return Resource(type: NovaType.strList, id: id, name: "STR#\(id)", data: Data(b))
    }

    private func game() -> NovaGame {
        var misc = (1...400).map { "#\($0)" }
        misc[33 - 1] = "credits"
        misc[257 - 1] = "Turn Rate:"
        misc[258 - 1] = " deg/sec"   // ASCII: the builder writes UTF-8, the decoder reads MacRoman
        misc[259 - 1] = "Accel Rate:"
        misc[260 - 1] = "Max Speed:"
        misc[239 - 1] = "jump"; misc[240 - 1] = "jumps"
        misc[262 - 1] = "plus"; misc[263 - 1] = "only"; misc[9 - 1] = "maneuvering energy"
        return makeGame([strList(2002, misc)])
    }

    private func figures(speedPerTick: Double) -> PlayerInfoPages.ShipFigures {
        .init(turnDegPerTick: 3, thrustPerTick2: 0.1, maxSpeedPerTick: speedPerTick,
              shield: 50, maxShield: 100, armor: 100, maxArmor: 100, destroyed: false, fuel: 250)
    }

    func testNonStrictMaxSpeedShowsTheHullSpeed() {
        // shïp Speed 250 is 2.5 px/tick; a non-strict pilot flies it ×1.5, and the
        // grid's ×100 × 2/3 brings it back to 250.
        let player = PlayerState(currentSystem: 128)
        let rows = PlayerInfoPages(game: game(), player: player).rightColumn(figures(speedPerTick: 3.75))
        XCTAssertTrue(rows.contains(.init(label: "Max Speed:", value: "250")))
        XCTAssertTrue(rows.contains(.init(label: "Turn Rate:", value: "90 deg/sec")))
        XCTAssertTrue(rows.contains(.init(label: "Accel Rate:", value: "250")))
        XCTAssertEqual(rows.last, .init(label: "Credits:", value: OriginalText.grouped(player.credits)))
    }

    func testStrictMaxSpeedIsUnscaled() {
        var player = PlayerState(currentSystem: 128)
        player.strictPlay = true
        let rows = PlayerInfoPages(game: game(), player: player).rightColumn(figures(speedPerTick: 2.5))
        XCTAssertTrue(rows.contains(.init(label: "Max Speed:", value: "250")))
    }

    func testEnergyWording() {
        let pages = PlayerInfoPages(game: game(), player: PlayerState(currentSystem: 128))
        XCTAssertEqual(pages.energy(250), "2 jumps plus maneuvering energy")
        XCTAssertEqual(pages.energy(100), "1 jump")
        XCTAssertEqual(pages.energy(40), "maneuvering energy only")
    }

    // MARK: Extras / Honors prose (0x0049c050)

    /// An `oütf` with DispWeight @0, Flags @12 and the lower-case singular @875 / plural @939.
    private func proseOutfit(_ id: Int, weight: Int = 0, flags: Int = 0, lc: String, plural: String = "") -> Resource {
        var b = [UInt8](repeating: 0, count: 1012)
        for pos in [6, 18, 22, 26] { Bytes.i16(&b, pos, -1) }
        Bytes.i16(&b, 0, weight)
        Bytes.i16(&b, 12, flags)
        Bytes.cstr(&b, 875, lc)
        Bytes.cstr(&b, 939, plural)
        return Resource(type: NovaType.outfit, id: id, name: "Outfit \(id)", data: Data(b))
    }

    private func proseRank(_ id: Int, weight: Int, name: String) -> Resource {
        var b = [UInt8](repeating: 0, count: 152)
        Bytes.i16(&b, 0, weight)
        Bytes.cstr(&b, 24, name)
        return Resource(type: NovaType.rank, id: id, name: "Rank \(id)", data: Data(b))
    }

    private func proseGame(_ extra: [Resource]) -> NovaGame {
        var misc = (1...400).map { "#\($0)" }
        misc[1 - 1] = "ton"; misc[2 - 1] = "tons"
        misc[32 - 1] = "credit"; misc[33 - 1] = "credits"
        misc[270 - 1] = "NO EXTRAS"; misc[271 - 1] = "NO HONORS"
        misc[272 - 1] = "Extras:"; misc[273 - 1] = "Trade-in:"; misc[274 - 1] = "Honors:"
        misc[392 - 1] = "and"; misc[393 - 1] = "a"; misc[394 - 1] = "an"
        var words = (1...40).map { "#\($0)" }
        words[28 + 2 - 1] = "two"; words[28 + 3 - 1] = "three"
        return makeGame([strList(2002, misc), strList(137, words)] + extra)
    }

    private func pages(_ extra: [Resource], outfits: [Int: Int] = [:], ranks: Set<Int> = []) -> PlayerInfoPages {
        var player = PlayerState(currentSystem: 128)
        player.outfits = outfits
        player.activeRanks = ranks
        return PlayerInfoPages(game: proseGame(extra), player: player)
    }

    func testExtrasGroupsByLCNameOrdersByDispWeightAndGlues() {
        let res = [
            proseOutfit(200, weight: 10, lc: "fuel scoop", plural: "fuel scoops"),
            proseOutfit(201, weight: 50, lc: "shield booster", plural: "shield boosters"),
            proseOutfit(202, weight: 99, lc: "shield booster", plural: "shield boosters"), // similar_to 201
            proseOutfit(203, weight: 5, lc: "light blaster", plural: "light blasters"),
            proseOutfit(204, weight: 100, lc: ""),                      // empty LCName: skipped
            proseOutfit(205, weight: 100, flags: 0x2000, lc: "medal"),  // honors only
        ]
        let p = pages(res, outfits: [200: 1, 201: 1, 202: 1, 203: 5, 204: 3, 205: 1])
        // Heaviest representative (201 = two boosters) first and capitalised (count < 4),
        // a/an-less singular, digits for >= 4, comma before "and" with three groups.
        XCTAssertEqual(p.extras(tradeInValue: nil),
                       "Extras:\n\nTwo shield boosters, a fuel scoop, and 5 light blasters.")
    }

    func testExtrasArticleCountWordsAndTwoGroupGlue() {
        let res = [proseOutfit(200, weight: 2, lc: "ion cannon", plural: "ion cannons"),
                   proseOutfit(201, weight: 1, lc: "bomb", plural: "bombs")]
        XCTAssertEqual(pages(res, outfits: [200: 1, 201: 3]).extras(tradeInValue: nil),
                       "Extras:\n\nAn ion cannon and three bombs.")      // two groups: no comma
        // Four or more: digits, and the first phrase is not capitalised.
        XCTAssertEqual(pages(res, outfits: [201: 4]).extras(tradeInValue: nil), "Extras:\n\n4 bombs.")
    }

    func testExtrasSignedDispWeightAndSlotOrderTies() {
        let res = [proseOutfit(200, weight: -5, lc: "alpha"), proseOutfit(201, weight: 3, lc: "beta"),
                   proseOutfit(202, weight: 3, lc: "gamma")]
        XCTAssertEqual(pages(res, outfits: [200: 1, 201: 1, 202: 1]).extras(tradeInValue: nil),
                       "Extras:\n\nA beta, a gamma, and an alpha.")
    }

    func testExtrasTradeInLineAndEmptyPage() {
        let res = [proseOutfit(200, lc: "bomb", plural: "bombs")]
        let p = pages(res, outfits: [200: 1])
        XCTAssertEqual(p.extras(tradeInValue: 1), "Extras:\n\nA bomb.\n\nTrade-in: 1 credit")
        XCTAssertEqual(p.extras(tradeInValue: 1500),
                       "Extras:\n\nA bomb.\n\nTrade-in: \(OriginalText.grouped(1500)) credits")
        XCTAssertEqual(p.extras(tradeInValue: 0), "Extras:\n\nA bomb.")
        // Nothing listable (not owned / empty LCName): STR# 2002 #270, and #271 for honors.
        let empty = pages([proseOutfit(200, lc: "")], outfits: [200: 2])
        XCTAssertEqual(empty.extras(tradeInValue: 500), "NO EXTRAS")
        XCTAssertEqual(empty.honors(), "NO HONORS")
    }

    func testHonorsRankGlueAndOutfitsGetNoAnd() {
        let res = [proseRank(128, weight: 100, name: "Admiral"), proseRank(129, weight: 50, name: "Captain"),
                   proseOutfit(200, flags: 0x2000, lc: "medal", plural: "medals"),
                   proseOutfit(201, flags: 0x2000, lc: "honor badge", plural: "honor badges")]
        // Ranks by Weight desc; "and" after the second-to-last entry, the final outfit entry
        // gets nothing.
        XCTAssertEqual(pages(res, outfits: [200: 1], ranks: [128, 129]).honors(),
                       "Honors:\n\nAdmiral, Captain, and a medal")
        // Two outfit entries after the ranks are joined by ", " only (no "and" between them).
        XCTAssertEqual(pages(res, outfits: [200: 1, 201: 2], ranks: [128]).honors(),
                       "Honors:\n\nAdmiral, a medal, two honor badges")
        // Outfits only: the first phrase is capitalised.
        XCTAssertEqual(pages(res, outfits: [200: 1, 201: 5]).honors(), "Honors:\n\nA medal, 5 honor badges")
    }
}
