import XCTest
@testable import NovaSwiftEngine
@testable import NovaSwiftKit

/// The headless simulation is a pure function of its seed: two runs of the
/// same system produce the same event stream tick for tick. Swift seeds
/// Set/Dictionary iteration per process and per instance, so any outcome that
/// depends on hashed-collection order shows up here as a mismatch.
final class SimulationDeterminismTests: XCTestCase {

    private static var cachedGame: NovaGame?

    private func stockGame() throws -> NovaGame {
        if let g = Self.cachedGame { return g }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = GameLibrary.discoverResourceFiles(in: repo.appendingPathComponent("data/base"))
        guard !files.isEmpty else { throw XCTSkip("No stock data under data/base") }
        let g = NovaGame(try GameLibrary.merge(baseFiles: files))
        Self.cachedGame = g
        return g
    }

    /// Populate system `systemID` the way `novaswift-extract ai` does and run
    /// it `ticks` steps, returning every event plus a final pose line per ship.
    private func run(_ game: NovaGame, systemID: Int, ticks: Int) throws -> [String] {
        let galaxy = Galaxy(game: game)
        let sys = try XCTUnwrap(game.system(systemID))
        let hull = sys.spawns.first?.id ?? 128
        let player = galaxy.makeShip(hull, government: independentGovt, at: Vec2())
            ?? Ship(name: "Player", stats: ShipStats(speed: 300, acceleration: 300, turnRate: 100))
        let world = World(player: player)
        world.diplomacy = galaxy.makeDiplomacy()
        world.galaxy = galaxy
        world.systemContext = galaxy.systemContext(for: sys.id)
        world.spawner = Spawner(galaxy: galaxy, table: SpawnTable(system: sys))
        world.spawner?.populate(world)
        var log: [String] = []
        for i in 0..<ticks {
            world.step(1.0 / 30.0)
            for e in world.events { log.append("\(i) \(e)") }
        }
        for s in world.allShips {
            log.append(String(format: "#%d %.6f %.6f %.6f %.3f %.3f", s.entityID, s.position.x, s.position.y,
                              s.angle, s.armor, s.shield))
        }
        log.append("rng \(world.rng.seed)")
        return log
    }

    func testTwoRunsOfABusySystemProduceIdenticalEventStreams() throws {
        let game = try stockGame()
        // 336 is a carrier battle (fighter bays, many outfits); 160 a quiet
        // trade lane. 50 s each.
        for systemID in [336, 160] where game.system(systemID) != nil {
            let a = try run(game, systemID: systemID, ticks: 1500)
            let b = try run(game, systemID: systemID, ticks: 1500)
            XCTAssertGreaterThan(a.count, 10, "system \(systemID) should do something")
            if a != b {
                let first = a.indices.first { !b.indices.contains($0) || a[$0] != b[$0] } ?? min(a.count, b.count)
                XCTFail("system \(systemID) diverged at line \(first): \(a.indices.contains(first) ? a[first] : "<end>") vs \(b.indices.contains(first) ? b[first] : "<end>")")
            }
        }
    }
}
