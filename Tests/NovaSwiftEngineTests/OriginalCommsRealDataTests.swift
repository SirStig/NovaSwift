import XCTest
@testable import NovaSwiftEngine
@testable import NovaSwiftKit

/// The ship comm window's greeting (AI-43, 0x004819d0) against the stock
/// data: the düde's InfoTypes choose the text.
final class OriginalCommsRealDataTests: XCTestCase {

    private func stockGame() throws -> NovaGame {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = GameLibrary.discoverResourceFiles(in: repo.appendingPathComponent("data/base"))
        guard !files.isEmpty else { throw XCTSkip("No stock data under data/base") }
        return NovaGame(try GameLibrary.merge(baseFiles: files))
    }

    private func world(_ galaxy: Galaxy) -> World {
        let w = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        w.galaxy = galaxy
        w.diplomacy = galaxy.makeDiplomacy()
        return w
    }

    private func ship(of dude: DudeRes, galaxy: Galaxy, world: World) throws -> Ship {
        let hull = try XCTUnwrap(dude.ships.first?.shipID)
        let s = try XCTUnwrap(galaxy.makeLoadedShip(hull, government: dude.govt >= 128 ? dude.govt : independentGovt,
                                                    at: Vec2(400, 0), includeDefaultItems: false))
        s.brain = AIBrain(aiType: dude.aiType, govt: s.government)
        s.dudeID = dude.id
        world.addNPC(s)
        world.step(1.0 / 30.0)
        return s
    }

    func testTradeTipDudeAlwaysGivesATradeTip() throws {
        let game = try stockGame()
        guard let dude = game.dudes().first(where: { $0.infoTypes & 0xf000 == 0x1000 && !$0.ships.isEmpty }) else {
            throw XCTSkip("no trade-tip-only düde in the stock data")
        }
        let galaxy = Galaxy(game: game)
        let w = world(galaxy)
        let s = try ship(of: dude, galaxy: galaxy, world: w)
        let middle = try XCTUnwrap(game.stringList(2002)?.string(at: 176))
        for _ in 0..<5 {
            let session = w.originalAI.openComm(with: s, world: w, playerCredits: 10_000)
            XCTAssertTrue(session.greeting.contains(middle), "\(session.greeting)")
            XCTAssertTrue(session.greeting.hasSuffix("."))
        }
    }

    func testDudeWithoutInfoTypesSaysGreetings() throws {
        let game = try stockGame()
        guard let dude = game.dudes().first(where: { $0.infoTypes & 0xf000 == 0 && !$0.ships.isEmpty }) else {
            throw XCTSkip("every stock düde has InfoTypes")
        }
        let galaxy = Galaxy(game: game)
        let w = world(galaxy)
        let s = try ship(of: dude, galaxy: galaxy, world: w)
        let session = w.originalAI.openComm(with: s, world: w, playerCredits: 10_000)
        XCTAssertEqual(session.greeting, game.stringList(2002)?.string(at: 175))
        let quoted = w.originalAI.openComm(with: s, world: w, playerCredits: 10_000,
                                           context: .init(persCommQuote: "Hello, captain."))
        XCTAssertEqual(quoted.greeting, "Hello, captain.", "a përs CommQuote overrides the greeting")
    }

    /// AI-32: a retreating trader that likes the player calls for help once
    /// per overlay, "<class>:  <STR# 5003 line>".
    func testRetreatingTraderBroadcastsADistressCallOncePerOverlay() throws {
        let game = try stockGame()
        guard let dude = game.dudes().first(where: { $0.aiTypeRaw == 1 && !$0.ships.isEmpty }) else {
            throw XCTSkip("no trader düde")
        }
        let galaxy = Galaxy(game: game)
        let w = world(galaxy)
        let s = try ship(of: dude, galaxy: galaxy, world: w)
        let pirate = try XCTUnwrap(galaxy.makeLoadedShip(dude.ships[0].shipID, at: Vec2(600, 0), includeDefaultItems: false))
        pirate.brain = AIBrain(aiType: .warship, govt: independentGovt)
        w.addNPC(pirate)
        w.step(1.0 / 30.0)
        let lines = Set(game.stringList(5003)?.strings ?? [])
        let r = try XCTUnwrap(w.originalAI.record(for: s.entityID))
        var calls = 0
        for _ in 0..<60 {
            r.hostility = 5
            r.primary = pirate.entityID
            r.state = OriginalAIState.retreat
            w.step(1.0 / 30.0)
            for e in w.events {
                if case let .overlayMessage(text, frames) = e {
                    calls += 1
                    XCTAssertEqual(frames, 240)
                    XCTAssertTrue(lines.contains { text.hasSuffix(":  " + $0) }, text)
                }
            }
        }
        XCTAssertEqual(calls, 1, "the overlay gate holds it to one call while the message is up")
    }
}

