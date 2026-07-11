import XCTest
import Foundation
@testable import NovaSwiftKit

final class NovaModelsTests: XCTestCase {

    private func payload(_ size: Int, _ set: (Int, Int)...) -> Data {
        var p = [UInt8](repeating: 0, count: size)
        for (off, v) in set {
            let u = v < 0 ? v + 0x10000 : v
            p[off] = UInt8((u >> 8) & 0xFF)
            p[off + 1] = UInt8(u & 0xFF)
        }
        return Data(p)
    }

    func testShipStatsDecode() throws {
        // Offsets per ShipRes: cargo0 shield2 accel4 speed6 turn8 armor14 sRech16
        let body = payload(120, (0, 10), (2, 100), (4, 500), (6, 300), (8, 40),
                           (14, 80), (16, 12), (62, 25))
        let fork = ClassicForkBuilder.build(type: "shïp", resources: [
            (id: 128, name: "Test Ship", payload: body),
        ])
        let game = NovaGame(try ResourceFile.read(fork))
        let ship = try XCTUnwrap(game.ship(128))
        XCTAssertEqual(ship.name, "Test Ship")
        XCTAssertEqual(ship.cargoSpace, 10)
        XCTAssertEqual(ship.shield, 100)
        XCTAssertEqual(ship.acceleration, 500)
        XCTAssertEqual(ship.speed, 300)
        XCTAssertEqual(ship.turnRate, 40)
        XCTAssertEqual(ship.armor, 80)
        XCTAssertEqual(ship.shieldRecharge, 12)
        XCTAssertEqual(ship.mass, 25)
    }

    func testSystemLinksAndSpobs() throws {
        // position (50, -30); links at 4+i*2; spobs at 36+i*2. Only >=128 kept.
        let body = payload(80, (0, 50), (2, -30),
                           (4, 200), (6, 201), (8, 5) /* <128 dropped */,
                           (36, 128), (38, 129))
        let fork = ClassicForkBuilder.build(type: "sÿst", resources: [
            (id: 128, name: "Sol", payload: body),
        ])
        let game = NovaGame(try ResourceFile.read(fork))
        let sys = try XCTUnwrap(game.system(128))
        XCTAssertEqual(sys.name, "Sol")
        XCTAssertEqual(sys.x, 50)
        XCTAssertEqual(sys.y, -30)
        XCTAssertEqual(sys.links, [200, 201])
        XCTAssertEqual(sys.spobs, [128, 129])
    }

    func testSpinTileGeometry() throws {
        let body = payload(16, (0, 1000), (2, 1001), (4, 24), (6, 24), (8, 6), (10, 6))
        let fork = ClassicForkBuilder.build(type: "spïn", resources: [
            (id: 400, name: "", payload: body),
        ])
        let game = NovaGame(try ResourceFile.read(fork))
        let spin = try XCTUnwrap(game.spin(400))
        XCTAssertEqual(spin.spriteID, 1000)
        XCTAssertEqual(spin.tileWidth, 24)
        XCTAssertEqual(spin.tilesAcross, 6)
    }
}
