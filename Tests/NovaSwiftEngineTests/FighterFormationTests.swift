import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

/// TEMP diagnostic: trace a player-launched fighter's state + distance from the
/// player over time, with NO enemies present, to reproduce the reported
/// "fighters fly off far away and circle forever" bug.
final class FighterTraceTests: XCTestCase {

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }
    private func ship(_ id: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 2000)
        put16(&b, 2, 100); put16(&b, 6, 300); put16(&b, 4, 200); put16(&b, 8, 30)
        put16(&b, 12, 40); put16(&b, 14, 100)
        put16(&b, 10, 400)
        return Resource(type: NovaType.ship, id: id, name: "Ship\(id)", data: Data(b))
    }
    private func bayWeapon(_ id: Int, fighter: Int, capacity: Int, reload: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 130)
        put16(&b, 0, reload)
        put16(&b, 8, 99)
        put16(&b, 12, fighter)
        put16(&b, 108, capacity)
        return Resource(type: NovaType.weapon, id: id, name: "Bay\(id)", data: Data(b))
    }
    private func weaponGrantOutfit(_ id: Int, weapon: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 1028)
        put16(&b, 6, 1); put16(&b, 8, weapon)
        return Resource(type: NovaType.outfit, id: id, name: "BayOutfit", data: Data(b))
    }
    private func game() -> NovaGame {
        var col = ResourceCollection()
        col.add(ship(128))
        col.add(ship(144))
        col.add(bayWeapon(149, fighter: 144, capacity: 3, reload: 30))
        col.add(weaponGrantOutfit(200, weapon: 149))
        return NovaGame(col)
    }

    func testTracePlayerLaunchedFighterNoEnemies() throws {
        let galaxy = Galaxy(game: game())
        world_diplomacy: do {}
        // Player IS the carrier: give the player the bay-equipped hull.
        let player = try XCTUnwrap(galaxy.makeLoadedShip(128, government: 128, extraOutfits: [200: 1]))
        player.position = Vec2(0, 0)
        player.velocity = Vec2(0, 0)
        let world = World(player: player)
        world.galaxy = galaxy
        world.diplomacy = galaxy.makeDiplomacy()

        // Manually launch a fighter the way the player's fire path does.
        let bay = try XCTUnwrap(player.fighterBays.first)
        // Step a few frames first so roster is built.
        world.step(1.0 / 30.0)

        // Simulate the player pulling the bay trigger: spawn one fighter as an
        // escort of the player. Mirror launchFighter's setup.
        let pos = player.position + Vec2.heading(player.angle) * (player.radius + 20)
        let fighter = try XCTUnwrap(galaxy.makeLoadedShip(bay.spec.fighterShipID, government: player.government,
                                                          at: pos, angle: player.angle))
        let brain = fighter.brain ?? AIBrain(aiType: .interceptor, govt: player.government)
        fighter.brain = brain
        brain.leaderID = World.playerEntityID
        brain.escortOrder = EscortOrder.defensive
        brain.formationSlot = 0
        fighter.carrierID = World.playerEntityID
        fighter.velocity = player.velocity
        _ = world.addNPC(fighter)

        print("=== TRACE: player-launched fighter, NO enemies — 8s hard turn, then 8s straight cruise ===")
        // Drive the player like a real pilot: hold a cruise velocity along its
        // heading and slowly turn, so the leader's angle changes over time.
        for f in 0..<480 {
            // First 8s: continuous hard turn (the worst case). Then straight
            // cruise, to confirm the wing closes tight and holds without
            // overshoot/oscillation.
            if f < 240 { player.angle += 0.4 * (1.0 / 30.0) }
            let cruise = player.stats.maxSpeed
            player.velocity = Vec2.heading(player.angle) * cruise
            player.position += player.velocity * (1.0 / 30.0)

            world.step(1.0 / 30.0)
            if f % 15 == 0 {
                let d = (fighter.position - player.position).length
                let st = fighter.brain?.state.rawValue ?? "?"
                let tgt = fighter.brain?.targetID.map(String.init) ?? "nil"
                print(String(format: "t=%.1fs state=%@ target=%@ dist=%.0f fpos=(%.0f,%.0f) fspd=%.0f ppos=(%.0f,%.0f)",
                             Double(f) / 30.0, st, tgt, d,
                             fighter.position.x, fighter.position.y, fighter.velocity.length,
                             player.position.x, player.position.y))
            }
        }
        let finalDist = (fighter.position - player.position).length
        print("=== final dist from player: \(Int(finalDist)) ===")
    }
}
