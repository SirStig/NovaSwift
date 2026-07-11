import XCTest
import Foundation
@testable import EVNovaKit

/// Decode tests for the audio-related fields added to `wëap`/`bööm`/`shïp`/
/// `gövt`/`spöb`: weapon fire/explosion sounds, government hail text, and
/// stellar ambient sound. Offsets verified empirically against the real base
/// data (`evnova-extract raw`/`sounds`) — see docs/DATA_FORMAT.md.
final class AudioResourceModelTests: XCTestCase {

    private func payload(_ size: Int, _ set: [(Int, Int)] = [], strings: [(Int, String)] = []) -> Data {
        var p = [UInt8](repeating: 0, count: size)
        for (off, v) in set {
            let u = v < 0 ? v + 0x10000 : v
            p[off] = UInt8((u >> 8) & 0xFF)
            p[off + 1] = UInt8(u & 0xFF)
        }
        for (off, s) in strings {
            let bytes = [UInt8](s.data(using: .macOSRoman) ?? Data())
            for (i, b) in bytes.enumerated() where off + i < size { p[off + i] = b }
        }
        return Data(p)
    }

    // MARK: wëap — fire sound, explosion, loop flag

    func testWeaponFireAndExplosionSound() throws {
        // sound@18 raw=8 -> 208; explosion@22 raw=0 -> bööm 128; flags@28 loop bit set.
        let body = payload(120, [(18, 8), (22, 0), (28, 0x0010)])
        let fork = ClassicForkBuilder.build(type: "wëap", resources: [(id: 128, name: "Light Blaster", payload: body)])
        let game = NovaGame(try ResourceFile.read(fork))
        let w = try XCTUnwrap(game.weapon(128))
        XCTAssertEqual(w.fireSoundID, 208)
        XCTAssertEqual(w.explosionBoomID, 128)
        XCTAssertTrue(w.loopSound)
    }

    func testWeaponSilentAndNoExplosionWhenRawIsMinusOne() throws {
        let body = payload(120, [(18, -1), (22, -1)])
        let fork = ClassicForkBuilder.build(type: "wëap", resources: [(id: 129, name: "Silent", payload: body)])
        let game = NovaGame(try ResourceFile.read(fork))
        let w = try XCTUnwrap(game.weapon(129))
        XCTAssertNil(w.fireSoundID)
        XCTAssertNil(w.explosionBoomID)
        XCTAssertFalse(w.loopSound)
    }

    func testWeaponExplosionSparksVariant() throws {
        // raw explosion >= 1000 is the "explosion + sparks" variant: bööm id = raw - 1000 + 128.
        let body = payload(120, [(22, 1005)])
        let fork = ClassicForkBuilder.build(type: "wëap", resources: [(id: 130, name: "Sparky", payload: body)])
        let game = NovaGame(try ResourceFile.read(fork))
        let w = try XCTUnwrap(game.weapon(130))
        XCTAssertEqual(w.explosionBoomID, 133)
    }

    // MARK: bööm — explosion sound + graphic

    func testBoomDecode() throws {
        let body = payload(12, [(0, 100), (2, 2), (4, 5)])
        let fork = ClassicForkBuilder.build(type: "bööm", resources: [(id: 128, name: "Boom", payload: body)])
        let game = NovaGame(try ResourceFile.read(fork))
        let b = try XCTUnwrap(game.boom(128))
        XCTAssertEqual(b.animationRate, 100)
        XCTAssertEqual(b.soundID, 302)   // 2 + 300
        XCTAssertEqual(b.graphicSpinID, 405)  // 5 + 400
    }

    func testBoomSilentWhenSoundIsMinusOne() throws {
        let body = payload(12, [(2, -1)])
        let fork = ClassicForkBuilder.build(type: "bööm", resources: [(id: 129, name: "Silent Boom", payload: body)])
        let game = NovaGame(try ResourceFile.read(fork))
        let b = try XCTUnwrap(game.boom(129))
        XCTAssertNil(b.soundID)
    }

    // MARK: shïp — breakup/final explosion

    func testShipExplosionFields() throws {
        let body = payload(120, [(56, 3), (58, 1005)])
        let fork = ClassicForkBuilder.build(type: "shïp", resources: [(id: 128, name: "Test Ship", payload: body)])
        let game = NovaGame(try ResourceFile.read(fork))
        let s = try XCTUnwrap(game.ship(128))
        XCTAssertEqual(s.breakupExplosionBoomID, 131)   // 3 + 128
        XCTAssertEqual(s.finalExplosionBoomID, 133)     // 1005 - 1000 + 128
    }

    func testDeathExplosionSoundIDPrefersFinalOverBreakup() throws {
        let shipBody = payload(120, [(56, 3), (58, 4)])   // breakup -> bööm 131, final -> bööm 132
        let boom131 = payload(12, [(2, 10)])  // sound 310
        let boom132 = payload(12, [(2, 20)])  // sound 320
        let fork = ClassicForkBuilder.build(type: "shïp", resources: [(id: 128, name: "Test Ship", payload: shipBody)])
        let boomFork = ClassicForkBuilder.build(type: "bööm", resources: [
            (id: 131, name: "Breakup", payload: boom131), (id: 132, name: "Final", payload: boom132),
        ])
        var merged = try ResourceFile.read(fork)
        merged.overlay(try ResourceFile.read(boomFork))
        let game = NovaGame(merged)
        let s = try XCTUnwrap(game.ship(128))
        XCTAssertEqual(game.deathExplosionSoundID(s), 320, "prefers the final explosion's sound over the breakup one's")
    }

    // MARK: gövt — hail text + can't-be-hailed flag

    func testGovtCommNameAndTargetCode() throws {
        let body = payload(120, strings: [(52, "Federation"), (68, " Fed.")])
        let fork = ClassicForkBuilder.build(type: "gövt", resources: [(id: 128, name: "Federation", payload: body)])
        let game = NovaGame(try ResourceFile.read(fork))
        let g = try XCTUnwrap(game.govt(128))
        XCTAssertEqual(g.commName, "Federation")
        XCTAssertEqual(g.targetCode, "Fed.")
    }

    func testGovtCommNameFallsBackToResourceName() throws {
        let body = payload(120)
        let fork = ClassicForkBuilder.build(type: "gövt", resources: [(id: 129, name: "Pirate", payload: body)])
        let game = NovaGame(try ResourceFile.read(fork))
        let g = try XCTUnwrap(game.govt(129))
        XCTAssertEqual(g.commName, "Pirate")
        XCTAssertEqual(g.targetCode, "Pirate")
    }

    func testGovtCantBeHailedFlag() throws {
        let body = payload(120, [(2, 0x0400)])
        let fork = ClassicForkBuilder.build(type: "gövt", resources: [(id: 130, name: "Reclusive", payload: body)])
        let game = NovaGame(try ResourceFile.read(fork))
        let g = try XCTUnwrap(game.govt(130))
        XCTAssertTrue(g.cantBeHailed)
    }

    // MARK: spöb — ambient sound

    func testSpobAmbientSoundID() throws {
        let body = payload(30, [(26, 10033)])
        let fork = ClassicForkBuilder.build(type: "spöb", resources: [(id: 299, name: "Holpa Station", payload: body)])
        let game = NovaGame(try ResourceFile.read(fork))
        let s = try XCTUnwrap(game.spob(299))
        XCTAssertEqual(s.ambientSoundID, 10033)
    }

    func testSpobNoAmbientSoundWhenMinusOne() throws {
        let body = payload(30, [(26, -1)])
        let fork = ClassicForkBuilder.build(type: "spöb", resources: [(id: 128, name: "Earth", payload: body)])
        let game = NovaGame(try ResourceFile.read(fork))
        let s = try XCTUnwrap(game.spob(128))
        XCTAssertNil(s.ambientSoundID)
    }
}
