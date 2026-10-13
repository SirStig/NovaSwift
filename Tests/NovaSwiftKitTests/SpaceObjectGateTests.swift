import XCTest
@testable import NovaSwiftKit

/// Byte-level decode tests for the `spöb` hypergate/wormhole fields, reverse-
/// engineered and verified against the base data: Flags2 (@30) carries `0x1000`
/// for hypergates and `0x2000` for wormholes, and HyperLink1-8 (@38, eight
/// int16s) hold the connected gates' spöb ids. Real reference: HG-V01 (#1400)
/// has Flags2 `0x1200` and links to 1401 and 1411.
final class SpaceObjectGateTests: XCTestCase {

    private func put16(_ buf: inout [UInt8], _ off: Int, _ val: Int) {
        let v = UInt16(bitPattern: Int16(truncatingIfNeeded: val))
        buf[off] = UInt8(v >> 8); buf[off + 1] = UInt8(v & 0xff)
    }
    private func put32(_ buf: inout [UInt8], _ off: Int, _ val: UInt32) {
        buf[off] = UInt8((val >> 24) & 0xff); buf[off + 1] = UInt8((val >> 16) & 0xff)
        buf[off + 2] = UInt8((val >> 8) & 0xff); buf[off + 3] = UInt8(val & 0xff)
    }

    /// HG-V01: Flags2 0x1200 (hypergate), HyperLinks 1401 & 1411, rest −1.
    func testHypergateDecodesLinks() {
        var b = [UInt8](repeating: 0, count: 1118)
        put32(&b, 30, 0x0000_1200)
        put16(&b, 38, 1401); put16(&b, 40, 1411)
        for i in 2..<8 { put16(&b, 38 + i * 2, -1) }
        let s = SpobRes(Resource(type: NovaType.spob, id: 1400, name: "HG-V01", data: Data(b)))
        XCTAssertTrue(s.isHypergate)
        XCTAssertFalse(s.isWormhole)
        XCTAssertTrue(s.isGate)
        XCTAssertEqual(s.hyperLinks, [1401, 1411])
    }

    /// A base-data wormhole: Flags2 0x2000, all HyperLinks −1 (random connect).
    func testWormholeRandomHasNoLinks() {
        var b = [UInt8](repeating: 0, count: 1118)
        put32(&b, 30, 0x0000_2000)
        for i in 0..<8 { put16(&b, 38 + i * 2, -1) }
        let s = SpobRes(Resource(type: NovaType.spob, id: 465, name: "Wormhole", data: Data(b)))
        XCTAssertTrue(s.isWormhole)
        XCTAssertFalse(s.isHypergate)
        XCTAssertEqual(s.hyperLinks, [])
    }

    // MARK: MinStatus (@22) + emerge angle (@26, CustSndID) decode

    /// HG-V01's real bytes: Govt 183 @20, MinStatus 32767 @22, CustSndID 120 @26
    /// (repurposed as the ships-emerge angle on gates), Flags2 0x1200 @30.
    func testGateMinStatusAndEmergeAngleDecode() {
        var b = [UInt8](repeating: 0, count: 1118)
        put16(&b, 20, 183)          // Govt
        put16(&b, 22, 32767)        // MinStatus (never land by standing)
        put16(&b, 26, 120)          // CustSndID → emerge angle for a gate
        put32(&b, 30, 0x0000_1200)  // hypergate + provoke-only weapon
        let s = SpobRes(Resource(type: NovaType.spob, id: 1400, name: "HG-V01", data: Data(b)))
        XCTAssertEqual(s.government, 183)
        XCTAssertEqual(s.minStatus, 32767)
        XCTAssertEqual(s.gateEmergeAngle, 120)
        XCTAssertNil(s.ambientSoundID)      // gates repurpose @26, so no ambient sound
    }

    /// An out-of-range CustSndID on a gate means "emerge in a random direction".
    func testGateRandomEmergeAngle() {
        var b = [UInt8](repeating: 0, count: 1118)
        put16(&b, 26, -1)
        put32(&b, 30, 0x0000_1000)
        let s = SpobRes(Resource(type: NovaType.spob, id: 1401, name: "HG", data: Data(b)))
        XCTAssertNil(s.gateEmergeAngle)
    }

    // MARK: gate → system mapping over a small hand-built galaxy

    private func system(id: Int, spobIDs: [Int]) -> Resource {
        var b = [UInt8](repeating: 0, count: 428)
        for (i, sp) in spobIDs.prefix(16).enumerated() { put16(&b, 36 + i * 2, sp) }
        return Resource(type: NovaType.syst, id: id, name: "Sys\(id)", data: Data(b))
    }

    private func gateSpob(id: Int, govt: Int, flags2: UInt32, links: [Int]) -> Resource {
        var b = [UInt8](repeating: 0, count: 1118)
        put16(&b, 20, govt)
        put32(&b, 30, flags2)
        for i in 0..<8 { put16(&b, 38 + i * 2, i < links.count ? links[i] : -1) }
        return Resource(type: NovaType.spob, id: id, name: "Gate\(id)", data: Data(b))
    }

    func testGateDestinationsResolveToSystems() {
        var col = ResourceCollection()
        col.add(gateSpob(id: 1400, govt: 183, flags2: 0x1000, links: [1500]))
        col.add(gateSpob(id: 1500, govt: 183, flags2: 0x1000, links: [1400]))
        col.add(system(id: 200, spobIDs: [1400]))
        col.add(system(id: 201, spobIDs: [1500]))
        let game = NovaGame(col)
        XCTAssertEqual(game.systemContaining(spob: 1500), 201)
        let dests = game.gateDestinations(from: game.spob(1400)!)
        XCTAssertEqual(dests.count, 1)
        XCTAssertEqual(dests.first?.gateSpobID, 1500)
        XCTAssertEqual(dests.first?.systemID, 201)
    }

    /// A deterministic `NovaRandom_Range` stand-in: replays `draws`, wrapping into `0..<n`.
    private func scripted(_ draws: [Int]) -> (Int) -> Int {
        var k = 0
        return { n in defer { k += 1 }; return draws[k % draws.count] % max(1, n) }
    }

    func testLinkedWormholeCanEmergeInAHiddenSystemAndDuplicatesWeighMore() {
        // OS-06 (`Stellar_EnterWormhole` 0x00456ca0 / `FUN_0046ebb0`).
        var col = ResourceCollection()
        // Slots: 464, 464, 465, then five empty. 464 sits in a hidden system, 465 in a visible one.
        col.add(gateSpob(id: 460, govt: 183, flags2: 0x2000, links: [464, 464, 465]))
        col.add(gateSpob(id: 464, govt: 183, flags2: 0x2000, links: []))
        col.add(gateSpob(id: 465, govt: 183, flags2: 0x2000, links: []))
        col.add(system(id: 300, spobIDs: [460]))
        col.add(system(id: 301, spobIDs: [464]))
        col.add(system(id: 302, spobIDs: [465]))
        let game = NovaGame(col)
        let visible = { (id: Int) in id != 301 }
        let wh = game.spob(460)!
        XCTAssertEqual(wh.validHyperLinkSlots, [464, 464, 465], "raw slots keep duplicates")
        // rand(8) = 0 or 1 -> the duplicated hidden hole; 2 -> the visible one; 3...7 redraw over an empty slot.
        XCTAssertEqual(game.wormholeExit(from: wh, currentSystem: 300, isVisible: visible, rand: scripted([0])),
                       .exit(gateSpobID: 464, systemID: 301), "a hidden system can be chosen")
        XCTAssertEqual(game.wormholeExit(from: wh, currentSystem: 300, isVisible: visible, rand: scripted([1])),
                       .exit(gateSpobID: 464, systemID: 301), "the duplicated slot is a second ticket")
        XCTAssertEqual(game.wormholeExit(from: wh, currentSystem: 300, isVisible: visible, rand: scripted([2])),
                       .exit(gateSpobID: 465, systemID: 302))
        XCTAssertEqual(game.wormholeExit(from: wh, currentSystem: 300, isVisible: visible, rand: scripted([5, 2])),
                       .exit(gateSpobID: 465, systemID: 302), "an empty slot redraws")
        // Every link hidden: unusable.
        XCTAssertEqual(game.wormholeExit(from: wh, currentSystem: 300, isVisible: { $0 == 300 }, rand: scripted([0])),
                       .unusable)
    }

    func testLinklessWormholeDrawThatLandsOnALinkedHoleStaysPut() {
        var col = ResourceCollection()
        col.add(gateSpob(id: 460, govt: 183, flags2: 0x2000, links: []))      // ours, link-less
        col.add(gateSpob(id: 461, govt: 183, flags2: 0x2000, links: []))      // link-less, visible, other system
        col.add(gateSpob(id: 462, govt: 183, flags2: 0x2000, links: [461]))   // LINKED, other system
        col.add(gateSpob(id: 463, govt: 183, flags2: 0x2000, links: []))      // link-less, same system as ours
        col.add(system(id: 300, spobIDs: [460, 463]))
        col.add(system(id: 301, spobIDs: [461]))
        col.add(system(id: 302, spobIDs: [462]))
        let game = NovaGame(col)
        let wh = game.spob(460)!
        // The stellar draw is `128 + rand(0x800)`: 461 -> exit; 462 (linked) -> stay put; 463 (same system) redraws.
        XCTAssertEqual(game.wormholeExit(from: wh, currentSystem: 300, rand: scripted([461 - 128])),
                       .exit(gateSpobID: 461, systemID: 301))
        XCTAssertEqual(game.wormholeExit(from: wh, currentSystem: 300, rand: scripted([462 - 128])),
                       .stayPut, "a draw that lands on a linked hole stays put")
        XCTAssertEqual(game.wormholeExit(from: wh, currentSystem: 300, rand: scripted([463 - 128, 461 - 128])),
                       .exit(gateSpobID: 461, systemID: 301), "a hole in the current system redraws")
        // No link-less wormhole in a visible other system: fails outright.
        XCTAssertEqual(game.wormholeExit(from: wh, currentSystem: 300, isVisible: { $0 != 301 },
                                         rand: scripted([462 - 128])), .unusable)
    }
}
