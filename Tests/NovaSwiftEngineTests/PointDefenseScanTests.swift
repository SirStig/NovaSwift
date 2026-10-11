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

/// Play-test bug: a new pilot in Sol who merely *targeted* a Federation ship
/// drew fire from its point-defense turrets. The original's PD
/// (0x0043a310) only fires on the player while the defender itself presses
/// the player (0x0040f780); the reticle alone never counts.
final class PointDefenseTargetingTests: XCTestCase {
    func testTargetingAFedShipDoesNotDrawPointDefenseFire() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = GameLibrary.discoverResourceFiles(in: repo.appendingPathComponent("data/base"))
        try XCTSkipIf(files.isEmpty, "needs data/base")
        let game = NovaGame(try GameLibrary.merge(baseFiles: files))
        let galaxy = Galaxy(game: game)
        let player = try XCTUnwrap(galaxy.makeShip(129, government: independentGovt, at: Vec2()))
        let world = World(player: player)
        world.diplomacy = galaxy.makeDiplomacy()
        world.galaxy = galaxy
        world.systemContext = galaxy.systemContext(for: 130)
        world.rng = NovaRandom(seed: 8 as UInt32)
        // Every Federation hull that carries point defense, parked on the player.
        let pdHulls = (128...895).filter { id in
            galaxy.makeShip(id, government: 128, at: Vec2())?.weapons.contains { $0.spec.isPointDefense } == true
        }
        try XCTSkipIf(pdHulls.isEmpty, "no point-defense hulls in data/base")
        for (i, hull) in pdHulls.prefix(6).enumerated() {
            let fed = try XCTUnwrap(galaxy.makeShip(hull, government: 128,
                                                    at: Vec2(60 + Double(i) * 20, 40)))
            _ = world.addNPC(fed)
        }
        player.hullFlags2 |= 0x0008     // make sure the player is a legal PD target
        var pdShots = 0
        for step in 0..<(30 * 30) {
            let feds = world.npcs.filter { $0.government == 128 && $0.isAlive }
            if !feds.isEmpty { _ = world.selectTarget(id: feds[step / 30 % feds.count].entityID) }
            world.step(1.0 / 30)
            pdShots += world.projectiles.filter { $0.isPointDefenseRound && $0.ownerGovt == 128 }.count
        }
        XCTAssertEqual(pdShots, 0, "targeting alone must not draw point-defense fire")
        XCTAssertFalse(world.npcs.contains { $0.government == 128 && $0.brain?.provokedByPlayer == true })
    }
}
