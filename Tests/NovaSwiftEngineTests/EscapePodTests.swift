import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

/// OS-02 in flight: eject, the derelict wreck, the pod's 350 ticks.
final class EscapePodTests: XCTestCase {

    private let tick = 1.0 / 30.0

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }
    private func ship(_ id: Int, deathDelay: Int = 30, flags: Int = 0) -> Resource {
        var b = [UInt8](repeating: 0, count: 2000)
        put16(&b, 2, 100); put16(&b, 6, 300); put16(&b, 4, 200); put16(&b, 8, 30)
        put16(&b, 12, 40); put16(&b, 14, 100); put16(&b, 10, 400)
        put16(&b, 52, deathDelay); put16(&b, 74, flags)
        return Resource(type: NovaType.ship, id: id, name: "Ship\(id)", data: Data(b))
    }
    private func outfit(_ id: Int, modType: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 1028)
        put16(&b, 6, modType); put16(&b, 8, 1)
        return Resource(type: NovaType.outfit, id: id, name: "O\(id)", data: Data(b))
    }

    private func world(outfits: [Int: Int]) throws -> World {
        var col = ResourceCollection()
        col.add(ship(128)); col.add(ship(895, deathDelay: 0))
        col.add(outfit(200, modType: 11))    // escape pod
        col.add(outfit(201, modType: 20))    // auto-eject
        let galaxy = Galaxy(game: NovaGame(col))
        let player = try XCTUnwrap(galaxy.makeLoadedShip(128, extraOutfits: outfits))
        let world = World(player: player)
        world.galaxy = galaxy
        return world
    }

    private func kill(_ world: World) {
        world.player.shield = 0
        world.player.armor = -5
        world.step(tick)
    }

    func testWithoutAnEjectThePilotIsLostWhenTheDeathSequenceRunsOut() throws {
        // A pod but no auto-eject and no key press: the pilot dies.
        let world = try world(outfits: [200: 1])
        XCTAssertTrue(world.player.hasEscapePod)
        kill(world)
        XCTAssertTrue(world.events.contains { if case .playerDying = $0 { return true } else { return false } })
        XCTAssertTrue(world.canPlayerEject)
        var lost = false
        for _ in 0..<200 {
            world.step(tick)
            if world.events.contains(where: { if case .playerDestroyed = $0 { return true } else { return false } }) {
                lost = true; break
            }
        }
        XCTAssertTrue(lost)
        XCTAssertFalse(world.canPlayerEject, "too late once the hull is gone")
    }

    func testManualEjectFliesThePodThenAsksForTheRespawn() throws {
        let world = try world(outfits: [200: 1])
        let hull = world.player
        hull.angle = 0
        kill(world)
        world.requestEject()
        world.step(tick)
        let ejected = world.events.compactMap { e -> (Int, Int, Bool, Int)? in
            if case let .playerEjected(prev, new, pod, wreck) = e { return (prev, new, pod, wreck) }
            return nil
        }.first
        XCTAssertEqual(ejected?.0, 128)
        XCTAssertEqual(ejected?.1, Ship.escapePodShipID)
        XCTAssertEqual(ejected?.2, true)
        XCTAssertEqual(world.player.shipTypeID, Ship.escapePodShipID)
        XCTAssertTrue(world.npcs.contains { $0 === hull }, "the old hull stays behind as a wreck")
        XCTAssertNotEqual(hull.entityID, 0)
        var respawn = false
        var ticks = 0
        while !respawn && ticks < 400 {
            world.step(tick); ticks += 1
            respawn = world.events.contains { if case .escapePodRespawn = $0 { return true } else { return false } }
        }
        XCTAssertTrue(respawn)
        XCTAssertEqual(ticks, 349, accuracy: 1, "350 ticks of pod flight")
        XCTAssertGreaterThan(world.player.position.y, 500, "flying straight out along its heading")
    }

    func testAutoEjectGoesOnceHalfTheDeathSequenceHasRun() throws {
        // DeathDelay 30: the player's timer starts at 90 raw calls; auto-eject
        // once it's down to 30 (≤ 15 or ≤ 30 calls), i.e. after 60 calls ≈ 1.26 s.
        let world = try world(outfits: [200: 1, 201: 1])
        kill(world)
        var steps = 0
        while world.player.shipTypeID != Ship.escapePodShipID && steps < 100 {
            world.step(tick); steps += 1
        }
        XCTAssertEqual(Double(steps) / 30, 60 * OriginalClock.rawCallSeconds, accuracy: 0.07)
    }

    func testDisabledPlayerCanEject() throws {
        let world = try world(outfits: [200: 1])
        world.player.shield = 0
        world.player.armor = 20
        XCTAssertTrue(world.player.disabled)
        world.requestEject()
        world.step(tick)
        XCTAssertEqual(world.player.shipTypeID, Ship.escapePodShipID)
        let wreck = try XCTUnwrap(world.npcs.first { $0.shipTypeID == 128 })
        XCTAssertTrue(wreck.isAlive && wreck.disabled, "a disabled hull is left as a hulk")
    }

    /// UI-15: holding the self-destruct command arms a 150-tick countdown and
    /// blows the ship at 1; letting go first aborts it.
    func testSelfDestructNeedsTheCommandHeldFiveSeconds() throws {
        let world = try world(outfits: [:])
        var hold = ControlIntent()
        hold.selfDestruct = true
        world.intent = hold
        for _ in 0..<60 { world.step(tick) }
        XCTAssertTrue(world.player.isAlive)
        world.intent = ControlIntent()
        world.step(tick)
        XCTAssertEqual(world.selfDestructCountdown, -1, "released: aborted")

        world.intent = hold
        for _ in 0..<160 { world.step(tick) }
        XCTAssertFalse(world.player.isAlive)
        XCTAssertEqual(world.player.shield, 0)
    }
}
