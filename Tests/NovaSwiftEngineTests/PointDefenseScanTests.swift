import XCTest
@testable import NovaSwiftEngine
@testable import NovaSwiftKit

/// Play-test bug: a Federation destroyer near Earth turned hostile with no
/// cause. Its point-defense gun treated a Federation scout that was merely
/// closing in to scan it as an attacker and fired; the stray rounds hit the
/// idle player, whose "ship was shot" rule then provoked the destroyer.
final class PointDefenseScanTests: XCTestCase {
    func testIdlePlayerInSolIsNeverShotByPointDefense() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = GameLibrary.discoverResourceFiles(in: repo.appendingPathComponent("data/base"))
        try XCTSkipIf(files.isEmpty, "needs data/base")
        let game = NovaGame(try GameLibrary.merge(baseFiles: files))
        let galaxy = Galaxy(game: game)
        let sys = try XCTUnwrap(game.system(130))
        let player = try XCTUnwrap(galaxy.makeShip(129, government: independentGovt, at: Vec2()))
        let world = World(player: player)
        world.diplomacy = galaxy.makeDiplomacy()
        world.galaxy = galaxy
        world.systemContext = galaxy.systemContext(for: 130)
        world.spawner = Spawner(galaxy: galaxy, table: SpawnTable(system: sys))
        world.rng = NovaRandom(seed: 8 as UInt32)       // the seed that reproduced it
        world.spawner?.populate(world)
        for _ in 0..<(30 * 120) { world.step(1.0 / 30) }
        XCTAssertFalse(world.npcs.contains { $0.government == 128 && $0.brain?.provokedByPlayer == true },
                       "no Federation ship may be provoked by an idle player")
    }
}
