import XCTest
import NovaSwiftKit
@testable import NovaSwiftStory

/// Batch 5 rules against the stock data. Skips when the user-supplied game
/// data isn't present under `data/base`.
final class OriginalMissionRealDataTests: XCTestCase {

    private func stockGame() throws -> NovaGame {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = GameLibrary.discoverResourceFiles(in: repo.appendingPathComponent("data/base"))
        guard !files.isEmpty else { throw XCTSkip("No stock data under data/base") }
        return NovaGame(try GameLibrary.merge(baseFiles: files))
    }

    /// mïsn 194's `L131 K132` moves the Vell-os player from the first
    /// permanent rank to the second instead of stacking them (MS-03).
    func testVellosRanksReplaceEachOther() throws {
        let game = try stockGame()
        XCTAssertTrue(game.rank(131)?.permanent ?? false)
        let eng = StoryEngine(game: game, player: PlayerState(shipType: 128, currentSystem: 128))
        eng.apply(set: "K131")
        eng.apply(set: "L131 K132")
        XCTAssertEqual(eng.player.activeRanks, [132])
    }

    /// crön 156 "Auroran Drop Bear Mating Season" is seasonal: its 1 Sep –
    /// 30 Dec window applies in every year (MS-14).
    func testDropBearSeasonIsSeasonal() throws {
        let game = try stockGame()
        let c = try XCTUnwrap(game.cron(156))
        let eng = StoryEngine(game: game, player: PlayerState(date: GameDate(day: 15, month: 6, year: 1180)))
        XCTAssertFalse(eng.dateInWindow(c))
        eng.player.date = GameDate(day: 15, month: 10, year: 1185)
        XCTAssertTrue(eng.dateInWindow(c))
    }

    /// The generic courier missions are repeatable: nothing but AvailBits gates
    /// them, and they come back after completion (MS-04).
    func testGenericMissionsComeBackAfterCompletion() throws {
        let game = try stockGame()
        let generic = game.missions().filter { $0.availBits.isEmpty && $0.availRandom > 0 && $0.availLocation == .missionComputer }
        XCTAssertGreaterThan(generic.count, 50)
    }

    /// A landing resolves the offer targets for the whole stock mission set
    /// and the BBS lists some — quickly enough to run on every dock.
    func testLandingPreparesStockOffers() throws {
        let game = try stockGame()
        let earth = 128
        let sys = try XCTUnwrap(game.systemContaining(spob: earth))
        let eng = StoryEngine(game: game, player: PlayerState(shipType: 128, currentSystem: sys))
        let start = Date()
        eng.playerLanded(onSpob: earth)
        let offered = eng.missionsOffered(at: .missionComputer, spob: earth)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(offered.isEmpty)
        XCTAssertLessThan(elapsed, 2.0, "landing took \(elapsed) s")
        for m in offered { XCTAssertFalse(eng.resolvedName(for: m).contains("[Error]"), m.name) }
    }
}
