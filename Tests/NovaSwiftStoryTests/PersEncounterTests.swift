import XCTest
import NovaSwiftKit
@testable import NovaSwiftStory

/// pêrs hail quotes + LinkMission offering, honouring the flag conditions.
final class PersEncounterTests: XCTestCase {
    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }
    private func putStr(_ b: inout [UInt8], _ off: Int, _ s: String) {
        for (i, byte) in Array(s.utf8).enumerated() { b[off + i] = byte }
    }
    /// A STR# resource from a list of strings.
    private func strList(_ id: Int, _ items: [String]) -> Resource {
        var b: [UInt8] = [UInt8(items.count >> 8), UInt8(items.count & 0xff)]
        for s in items { let bytes = Array(s.utf8); b.append(UInt8(bytes.count)); b += bytes }
        return Resource(type: NovaType.strList, id: id, name: "STR#\(id)", data: Data(b))
    }
    private func pers(_ id: Int, commQuote: Int, hailQuote: Int, linkMission: Int, flags: Int, govt: Int = 149) -> Resource {
        var b = [UInt8](repeating: 0, count: 400)
        put16(&b, 2, govt); put16(&b, 10, 134)
        put16(&b, 44, commQuote); put16(&b, 46, hailQuote); put16(&b, 48, linkMission); put16(&b, 50, flags)
        return Resource(type: NovaType.pers, id: id, name: "Jack Folstam", data: Data(b))
    }
    private func mission(_ id: Int) -> Resource {
        Resource(type: NovaType.mission, id: id, name: "Mission\(id)", data: Data(count: 2000))
    }

    private func game(persFlags: Int, linkMission: Int = 140) -> NovaGame {
        var col = ResourceCollection()
        col.add(strList(7100, ["", "Nice ship.", "You again."]))   // CommQuote index 2 = "Nice ship."
        col.add(strList(7101, ["", "Come closer.", "I'll destroy you!"]))
        col.add(pers(131, commQuote: 2, hailQuote: 2, linkMission: linkMission, flags: persFlags))
        col.add(mission(140))
        return NovaGame(col)
    }

    func testHailShowsCommQuoteAndOffersMission() {
        let g = game(persFlags: 0)
        let engine = StoryEngine(game: g, player: PlayerState(currentSystem: 128))
        let r = PersEncounter.hail(g.pers(131)!, player: engine.player, game: g, engine: engine)
        XCTAssertEqual(r.commQuote, "Nice ship.")
        XCTAssertEqual(r.offerMissionID, 140)
    }

    func testHailQuoteGatedByGrudge() {
        // Flag 0x0004: only show HailQuote when the ship has a grudge.
        let g = game(persFlags: 0x0004)
        var player = PlayerState(currentSystem: 128)
        let engine = StoryEngine(game: g, player: player)
        // No grudge yet → the grudge-only hail quote is withheld.
        XCTAssertNil(PersEncounter.hail(g.pers(131)!, player: engine.player, game: g, engine: engine).hailQuote)
        // With a grudge recorded → it shows.
        player.recordPersGrudge(131)
        let engine2 = StoryEngine(game: g, player: player)
        XCTAssertEqual(PersEncounter.hail(g.pers(131)!, player: player, game: g, engine: engine2).hailQuote,
                       "Come closer.")
    }

    func testHailQuoteGatedByAttackingContext() {
        // Flag 0x0010: only show HailQuote when the ship begins to attack
        // the player (SESSION_AUDIT_FOLLOWUPS.md §A — previously decoded but
        // never actually consulted by `hail`'s gating).
        let g = game(persFlags: 0x0010)
        let engine = StoryEngine(game: g, player: PlayerState(currentSystem: 128))
        XCTAssertNil(PersEncounter.hail(g.pers(131)!, player: engine.player, game: g, engine: engine,
                                        attacking: false).hailQuote,
                     "not currently attacking — the attacking-only quote stays withheld")
        XCTAssertEqual(PersEncounter.hail(g.pers(131)!, player: engine.player, game: g, engine: engine,
                                          attacking: true).hailQuote, "Come closer.")
    }

    func testMissionOnBoardNotOfferedOnHail() {
        // Flag 0x0200: LinkMission is offered on boarding, not hailing.
        let g = game(persFlags: 0x0200)
        let engine = StoryEngine(game: g, player: PlayerState(currentSystem: 128))
        XCTAssertNil(PersEncounter.hail(g.pers(131)!, player: engine.player, game: g, engine: engine).offerMissionID)
        XCTAssertEqual(PersEncounter.hail(g.pers(131)!, player: engine.player, game: g, engine: engine, boarding: true).offerMissionID, 140)
    }

    func testGrudgeAndDefeatedState() {
        var p = PlayerState(currentSystem: 128)
        XCTAssertFalse(p.persHoldsGrudge(131))
        p.recordPersGrudge(131)
        XCTAssertTrue(p.persHoldsGrudge(131))
        p.recordPersDefeated(131)
        XCTAssertTrue(p.isPersDefeated(131))
    }
}
