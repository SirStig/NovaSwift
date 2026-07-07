import XCTest
import Foundation
@testable import EVNovaKit

final class ContainerTests: XCTestCase {

    // MARK: FourCharCode / Mac Roman

    func testFourCharCodeMacRoman() throws {
        // EV Nova ship type is the raw Mac Roman bytes for "shïp".
        let ship = try XCTUnwrap(FourCharCode("shïp"))
        XCTAssertEqual(ship.stringValue, "shïp")
        XCTAssertEqual(ship.bytes.count, 4)
        // Round-trip through raw bytes.
        XCTAssertEqual(FourCharCode(bytes: ship.bytes), ship)
        // 'ï' in Mac Roman is 0x95 — proves we are not treating codes as ASCII.
        XCTAssertEqual(ship.bytes[2], 0x95)
    }

    func testASCIIFourCharCode() throws {
        let snd = try XCTUnwrap(FourCharCode("snd "))
        XCTAssertEqual(snd.bytes, [0x73, 0x6e, 0x64, 0x20])
    }

    // MARK: BinaryReader endianness

    func testReaderEndianness() throws {
        let r = BinaryReader(Data([0x12, 0x34, 0x56, 0x78]), bigEndian: true)
        try r.seek(0)
        XCTAssertEqual(try r.readU32(), 0x1234_5678)
        try r.seek(0)
        XCTAssertEqual(try r.readU32(bigEndian: false), 0x7856_3412)
    }

    func testReaderBoundsThrow() {
        let r = BinaryReader(Data([0x00, 0x01]))
        XCTAssertThrowsError(try r.readU32())
    }

    // MARK: Classic resource fork round-trip

    /// Build a minimal but valid classic resource fork containing two resources
    /// of one type, then parse it and assert the round-trip.
    func testClassicResourceForkRoundTrip() throws {
        let fork = ClassicForkBuilder.build(type: "shïp", resources: [
            (id: 128, name: "Shuttle", payload: Data([0xAA, 0xBB])),
            (id: 129, name: "Fighter", payload: Data([0x01, 0x02, 0x03, 0x04])),
        ])

        XCTAssertEqual(ResourceFile.detectFormat(fork), .classic)
        let collection = try ResourceFile.read(fork)

        let ship = try XCTUnwrap(FourCharCode("shïp"))
        XCTAssertEqual(collection.totalCount, 2)
        XCTAssertEqual(collection.resources(of: ship).map(\.id), [128, 129])

        let shuttle = try XCTUnwrap(collection.resource(ship, 128))
        XCTAssertEqual(shuttle.name, "Shuttle")
        XCTAssertEqual(shuttle.data, Data([0xAA, 0xBB]))

        let fighter = try XCTUnwrap(collection.resource(ship, 129))
        XCTAssertEqual(fighter.name, "Fighter")
        XCTAssertEqual(fighter.data, Data([0x01, 0x02, 0x03, 0x04]))
    }

    // MARK: Plug-in override semantics

    func testOverlayOverridesByTypeAndID() throws {
        let ship = try XCTUnwrap(FourCharCode("shïp"))
        var base = ResourceCollection()
        base.add(Resource(type: ship, id: 128, name: "Base", data: Data([0x00])))

        var plugin = ResourceCollection()
        plugin.add(Resource(type: ship, id: 128, name: "Modded", data: Data([0xFF])))
        plugin.add(Resource(type: ship, id: 200, name: "New", data: Data([0x42])))

        base.overlay(plugin)
        XCTAssertEqual(base.totalCount, 2)
        XCTAssertEqual(base.resource(ship, 128)?.name, "Modded")
        XCTAssertEqual(base.resource(ship, 200)?.name, "New")
    }

    // MARK: Optional test against a real downloaded fixture

    /// If EVNOVA_FIXTURE points to a real .rez/.ndat file (e.g. a downloaded
    /// community plug-in), parse it and assert it produced resources. Skipped
    /// when the env var is unset so the suite stays hermetic.
    func testRealFixtureIfProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["EVNOVA_FIXTURE"] else {
            throw XCTSkip("Set EVNOVA_FIXTURE to a real .rez/.ndat file to run this test")
        }
        let collection = try ResourceFile.read(contentsOf: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(collection.totalCount, 0)
        XCTAssertGreaterThan(collection.types.count, 0)
    }
}

/// Test helper: assembles a valid classic resource fork from scratch so the
/// parser can be exercised without any copyrighted game data.
enum ClassicForkBuilder {
    static func build(type typeString: String, resources: [(id: Int, name: String, payload: Data)]) -> Data {
        func u16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }
        func u32(_ v: Int) -> [UInt8] {
            [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
             UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
        }
        let typeBytes = [UInt8](typeString.data(using: .macOSRoman)!)

        // --- Data section: each resource = u32 length + payload ---
        let dataOffset = 256
        var dataSection: [UInt8] = []
        var dataOffsets: [Int] = []
        for r in resources {
            dataOffsets.append(dataSection.count)
            dataSection += u32(r.payload.count)
            dataSection += [UInt8](r.payload)
        }

        // --- Name list: Pascal strings; record each name's offset ---
        var nameList: [UInt8] = []
        var nameOffsets: [Int] = []
        for r in resources {
            let nb = [UInt8](r.name.data(using: .macOSRoman) ?? Data())
            nameOffsets.append(nameList.count)
            nameList.append(UInt8(nb.count))
            nameList += nb
        }

        // --- Map ---
        // Map layout (all offsets relative to the map's start):
        //   [0..16)  header copy (zeros permitted)
        //   [16..20) next-map handle
        //   [20..22) file reference number
        //   [22..24) fork attributes
        //   [24..26) offset to type list   ── the parser reads these two u16s at map+24
        //   [26..28) offset to name list
        //   [28..)   type list, then ref lists, then name list
        let numTypes = 1
        // Type list: u16(count-1) + per-type(4cc + u16(count-1) + u16 refListOffset) = 2 + 8 bytes.
        let typeListLength = 2 + numTypes * 8

        var typeList: [UInt8] = []
        typeList += u16(numTypes - 1)
        typeList += typeBytes
        typeList += u16(resources.count - 1)
        typeList += u16(typeListLength) // refListOffset, relative to type-list start

        var refList: [UInt8] = []
        for (i, r) in resources.enumerated() {
            refList += u16(r.id)
            refList += u16(nameOffsets[i])
            let off = dataOffsets[i] // attributes byte (0) + 3-byte data offset
            refList += [0x00,
                        UInt8(truncatingIfNeeded: off >> 16),
                        UInt8(truncatingIfNeeded: off >> 8),
                        UInt8(truncatingIfNeeded: off)]
            refList += u32(0) // in-memory handle placeholder
        }

        let typeListOffset = 28
        let nameListOffset = typeListOffset + typeList.count + refList.count

        var finalMap: [UInt8] = []
        finalMap += [UInt8](repeating: 0, count: 16) // header copy
        finalMap += u32(0)                            // next-map handle
        finalMap += u16(0)                            // file reference number
        finalMap += u16(0)                            // fork attributes
        finalMap += u16(typeListOffset)               // at map+24
        finalMap += u16(nameListOffset)               // at map+26
        finalMap += typeList
        finalMap += refList
        finalMap += nameList

        // --- Assemble file: [256 header pad][data][map] ---
        let mapOffset = dataOffset + dataSection.count
        var header: [UInt8] = []
        header += u32(dataOffset)
        header += u32(mapOffset)
        header += u32(dataSection.count)
        header += u32(finalMap.count)
        header += [UInt8](repeating: 0, count: dataOffset - header.count) // pad to 256

        return Data(header + dataSection + finalMap)
    }
}
