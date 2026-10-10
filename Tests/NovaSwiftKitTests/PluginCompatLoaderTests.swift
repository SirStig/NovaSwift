import XCTest
import Foundation
@testable import NovaSwiftKit

/// Plug-in compat R4, R8, R10, R11, R13 with synthetic resources only.
final class PluginCompatLoaderTests: XCTestCase {

    private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private func be32(_ v: Int) -> [UInt8] { be16(v >> 16) + be16(v & 0xFFFF) }
    private func le32(_ v: Int) -> [UInt8] { be32(v).reversed() }

    /// A one-resource BRGR file: type "TEST" id 128, one payload byte.
    private func brgr() -> Data {
        var d = [UInt8]()
        d += Array("BRGR".utf8) + le32(1) + le32(48) + le32(1) + le32(0) + le32(2)
        d += le32(48) + le32(1) + le32(0)          // entry 0: the payload
        d += le32(49) + le32(20 + 266) + le32(0)   // entry 1: the map
        d += [0x42]
        d += be32(8) + be32(1)                     // map: typeListOffset, numTypes
        d += Array("TEST".utf8) + be32(20) + be32(1)
        d += be32(0) + Array("TEST".utf8) + be16(128) + [UInt8](repeating: 0, count: 256)
        return Data(d)
    }

    func testBRGRRoundTripAndTruncation() throws {
        let ok = try ResourceFile.read(brgr())
        XCTAssertEqual(ok.totalCount, 1)
        XCTAssertThrowsError(try ResourceFile.read(brgr().dropLast(10)))
        XCTAssertThrowsError(try ResourceFile.read(brgr().prefix(60)))
    }

    func testCorruptPluginFileIsSkipped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("novaswift-r10-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base.ndat")
        try ClassicForkBuilder.build(type: "shïp", resources: [(id: 128, name: "Base", payload: Data([0]))]).write(to: base)
        let bad = root.appendingPathComponent("bad.rez")
        try brgr().dropLast(10).write(to: bad)
        let good = root.appendingPathComponent("good.ndat")
        try ClassicForkBuilder.build(type: "shïp", resources: [(id: 129, name: "Good", payload: Data([0]))]).write(to: good)
        let plugin = PluginBundle(id: "p", name: "p", kind: .unknown, fileURLs: [bad, good], isEnabled: true)
        let merged = try GameLibrary.merge(baseFiles: [base], plugins: [plugin])
        XCTAssertEqual(merged.resource(NovaType.ship, 128)?.name, "Base")
        XCTAssertEqual(merged.resource(NovaType.ship, 129)?.name, "Good")
    }

    func testNebulaBeyond32SlotsDropped() {
        var c = ResourceCollection()
        c.add(Resource(type: NovaType.nebula, id: 159, data: Data(count: 518)))
        c.add(Resource(type: NovaType.nebula, id: 160, data: Data(count: 518)))
        c.normalizeScenarioRecords()
        XCTAssertNotNil(c.resource(NovaType.nebula, 159))
        XCTAssertNil(c.resource(NovaType.nebula, 160))
    }

    func testWeaponGraphicZeroIsSpin3000() throws {
        var body = [UInt8](repeating: 0, count: 134)
        func set(_ off: Int, _ v: Int) { body[off] = UInt8((v >> 8) & 0xFF); body[off + 1] = UInt8(v & 0xFF) }
        let fork0 = ClassicForkBuilder.build(type: "wëap", resources: [(id: 128, name: "A", payload: Data(body))])
        set(14, -1)
        let forkN = ClassicForkBuilder.build(type: "wëap", resources: [(id: 129, name: "B", payload: Data(body))])
        XCTAssertEqual(NovaGame(try ResourceFile.read(fork0)).weapon(128)?.graphicSpinID, 3000)
        XCTAssertNil(NovaGame(try ResourceFile.read(forkN)).weapon(129)?.graphicSpinID)
    }

    func testNonImmediateBufferCommandDecodes() throws {
        var d = [UInt8]()
        d += be16(1) + be16(0) + be16(1) + be16(81) + be16(0) + be32(14)    // no data-offset bit
        d += be32(0) + be32(2) + be32(22050 << 16) + be32(0) + be32(0) + [0, 60, 10, 20]
        XCTAssertEqual(try SndDecoder.decode(Data(d)).samples.count, 2)
    }

    func testPixPatDecodes() throws {
        // patType 1, PixMap at 28, pixel data at 120 (4x2 pixels, 2 bits, rowBytes 1), clut at 90.
        var d = [UInt8](repeating: 0, count: 140)
        func put(_ at: Int, _ bytes: [UInt8]) { for (i, v) in bytes.enumerated() { d[at + i] = v } }
        put(0, be16(1)); put(2, be32(28)); put(6, be32(120))
        put(28 + 4, be16(0x8001))
        put(28 + 6, be16(0) + be16(0) + be16(2) + be16(4))
        put(28 + 32, be16(2))
        put(28 + 42, be32(90))
        put(90 + 6, be16(1))                                       // 2 entries
        put(98, be16(0) + be16(0) + be16(0) + be16(0))             // index 0 black
        put(106, be16(1) + be16(0x00FF) + be16(0x0080) + be16(0x0010))
        put(120, [0b00_01_00_01, 0b01_01_00_00])
        let s = try PixPat.decode(Data(d))
        XCTAssertEqual(s.frameWidth, 4); XCTAssertEqual(s.frameHeight, 2)
        XCTAssertEqual(Array(s.rgba[0..<3]), [0, 0, 0])
        XCTAssertEqual(Array(s.rgba[4..<7]), [0xFF, 0x80, 0x10])
        XCTAssertEqual(Array(s.rgba[(4 * 4)..<(4 * 4 + 3)]), [0xFF, 0x80, 0x10])
        XCTAssertThrowsError(try PixPat.decode(Data(d.prefix(50))))
    }
}
