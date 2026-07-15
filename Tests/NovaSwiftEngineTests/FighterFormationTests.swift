import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

/// Regression: a player-launched fighter must hold formation on its carrier
/// even while the carrier is continuously maneuvering. The original bug had the
/// escort controller pure-pursue the (orbiting) formation slot of a turning
/// leader, which settled into a fixed-radius lag orbit — "launch a fighter and
/// it flies off to a random point and circles forever." The velocity-matching
/// controller converges instead, so the fighter stays on station.
final class FighterFormationTests: XCTestCase {

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

    func testFighterHoldsFormationOnManeuveringCarrier() throws {
        let galaxy = Galaxy(game: game())
        // Player IS the carrier.
        let player = try XCTUnwrap(galaxy.makeLoadedShip(128, government: 128, extraOutfits: [200: 1]))
        player.position = Vec2(0, 0)
        player.velocity = Vec2(0, 0)
        let world = World(player: player)
        world.galaxy = galaxy
        world.diplomacy = galaxy.makeDiplomacy()
        let bay = try XCTUnwrap(player.fighterBays.first)
        world.step(1.0 / 30.0)

        // Launch one fighter as a player escort (mirrors the fire-path setup).
        let pos = player.position + Vec2.heading(player.angle) * (player.radius + 20)
        let fighter = try XCTUnwrap(galaxy.makeLoadedShip(bay.spec.fighterShipID, government: player.government,
                                                          at: pos, angle: player.angle))
        let brain = fighter.brain ?? AIBrain(aiType: .interceptor, govt: player.government)
        fighter.brain = brain
        brain.leaderID = World.playerEntityID
        brain.escortOrder = EscortOrder.defensive
        fighter.carrierID = World.playerEntityID
        fighter.velocity = player.velocity
        _ = world.addNPC(fighter)

        // The slot for row 0 sits ~one slot-spacing behind the leader; the wing
        // should hold within a small multiple of that, never run away to the
        // hundreds-of-units lag orbit the bug produced (~550+).
        let slotSpacing = max(64, player.radius + fighter.radius + 40)
        let maxAllowed = slotSpacing * 2.2

        var maxSeen = 0.0
        for f in 0..<600 {
            // Continuous hard turn at cruise — the worst case for formation
            // keeping, and exactly what a carrier dogfighting does.
            player.angle += 0.4 * (1.0 / 30.0)
            player.velocity = Vec2.heading(player.angle) * player.stats.maxSpeed
            player.position += player.velocity * (1.0 / 30.0)
            world.step(1.0 / 30.0)
            // Allow a couple seconds to close from the launch point first.
            if f > 60 {
                let d = (fighter.position - player.position).length
                maxSeen = max(maxSeen, d)
                XCTAssertEqual(fighter.brain?.state, .escorting,
                               "fighter should stay escorting, not peel off")
            }
        }
        XCTAssertLessThan(maxSeen, maxAllowed,
                          "fighter held within \(Int(maxAllowed))px of its maneuvering carrier (saw \(Int(maxSeen)))")
    }
}
