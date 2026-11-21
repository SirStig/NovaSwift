import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

/// Play-test report (1.0.0 build 462): "when being scanned the ship uses the
/// pilot name, not the ship name like the OG game" — the screenshot read
/// "Abomination:  Aurelian, prepare to be scanned." with Aurelian the pilot.
/// The interceptor's warning (0x00403de0) hails the player's ship by name.
final class ScanWarningNameTests: XCTestCase {
    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }

    private func setup() -> (World, Ship) {
        var col = ResourceCollection()
        var g = [UInt8](repeating: 0, count: 192)
        put16(&g, 50, 0x8000)                                   // ScanMask
        col.add(Resource(type: NovaType.govt, id: 128, name: "Patrol", data: Data(g)))
        // STR# 2002 up to #383; #381–#383 are the warning's tail.
        var items = (1...383).map { "#\($0)" }
        for i in 381...383 { items[i - 1] = "prepare to be scanned" }
        var s: [UInt8] = [UInt8(items.count >> 8), UInt8(items.count & 0xff)]
        for item in items { let bytes = Array(item.utf8); s.append(UInt8(bytes.count)); s += bytes }
        col.add(Resource(type: NovaType.strList, id: 2002, name: "Misc", data: Data(s)))
        let game = NovaGame(col)
        let galaxy = Galaxy(game: game)
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        world.galaxy = galaxy
        world.diplomacy = galaxy.makeDiplomacy()
        world.missionCargoScanMask = 0x8000                     // carrying cargo the patrol scans for
        let scanner = Ship(name: "Abomination", stats: ShipStats(maxSpeed: 100, acceleration: 50, turnRate: 1))
        scanner.government = 128
        world.addNPC(scanner)
        return (world, scanner)
    }

    private func overlayText(_ world: World) -> String? {
        for e in world.events { if case let .overlayMessage(text, _) = e { return text } }
        return nil
    }

    func testScanWarningAddressesTheShipByName() {
        let (world, scanner) = setup()
        world.pilotName = "Aurelian"
        world.playerShipName = "Starfall"
        world.originalAI.scanWarning(scanner, host: WorldAIHost(world: world, ai: world.originalAI))
        XCTAssertEqual(overlayText(world), "Abomination:  Starfall, prepare to be scanned.")
    }

    func testScanWarningFallsBackToThePilotWithoutAShipName() {
        let (world, scanner) = setup()
        world.pilotName = "Aurelian"
        world.originalAI.scanWarning(scanner, host: WorldAIHost(world: world, ai: world.originalAI))
        XCTAssertEqual(overlayText(world), "Abomination:  Aurelian, prepare to be scanned.")
    }
}
