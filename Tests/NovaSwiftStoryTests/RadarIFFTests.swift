import XCTest
import NovaSwiftKit
@testable import NovaSwiftStory

/// D-4: the IFF stellar ladder of `Stellar_GetStellarRadarColor` 0x00466030.
final class RadarIFFTests: XCTestCase {

    private func spob(_ id: Int, flags: Int = 0x01, flags2: Int = 0, minStatus: Int = -32767) -> SpobRes {
        var b = [UInt8](repeating: 0, count: 1100)
        Bytes.i32(&b, 6, flags)
        Bytes.i16(&b, 20, -1)
        Bytes.i16(&b, 22, minStatus)
        Bytes.i32(&b, 30, flags2)
        return SpobRes(Resource(type: NovaType.spob, id: id, name: "P\(id)", data: Data(b)))
    }

    private func same(_ a: RadarIFF.RGB16, _ b: RadarIFF.RGB16) -> Bool { a.r == b.r && a.g == b.g && a.b == b.b }

    func testLadder() {
        let game = makeGame([])
        var state = PlayerState(currentSystem: 128)
        func c(_ s: SpobRes) -> RadarIFF.RGB16 { RadarIFF.stellarColor(s, state: state, game: game, system: 128) }
        XCTAssertTrue(same(c(spob(1, flags: 0)), RadarIFF.inactive), "not landable")
        XCTAssertTrue(same(c(spob(2, flags: 0x21)), RadarIFF.inactive), "uninhabited")
        XCTAssertTrue(same(c(spob(3, flags2: 0x2000)), RadarIFF.wormhole))
        XCTAssertTrue(same(c(spob(4)), RadarIFF.yellow), "MinStatus −32767 always lands")
        XCTAssertTrue(same(c(spob(5, minStatus: 10)), RadarIFF.orange), "refused at rep ≥ 0")
        state.systemReputation = [128: -5]
        XCTAssertTrue(same(c(spob(5, minStatus: 10)), RadarIFF.red), "refused at negative rep")
        XCTAssertTrue(same(c(spob(6, flags2: 0x1000, minStatus: 32767)), RadarIFF.red), "a gate takes the standing ladder")
        state.dominatedStellars = [7]
        XCTAssertTrue(same(c(spob(7, minStatus: 32767)), RadarIFF.green))
    }
}
