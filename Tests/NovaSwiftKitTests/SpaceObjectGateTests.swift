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

    // MARK: playerMayUseGate — the clearance mechanic

    private func hypergate(govt: Int, minStatus: Int) -> SpobRes {
        var b = [UInt8](repeating: 0, count: 1118)
        put16(&b, 20, govt)
        put16(&b, 22, minStatus)
        put32(&b, 30, 0x0000_1000)
        return SpobRes(Resource(type: NovaType.spob, id: 1400, name: "HG", data: Data(b)))
    }

    func testWormholeUsableByAnyone() {
        var b = [UInt8](repeating: 0, count: 1118)
        put16(&b, 20, 183)
        put32(&b, 30, 0x0000_2000)
        let wh = SpobRes(Resource(type: NovaType.spob, id: 465, name: "Wormhole", data: Data(b)))
        // Even hostile, deeply-criminal, unallied: a wormhole never checks.
        XCTAssertTrue(wh.playerMayUseGate(standing: -5000, hostile: true, allied: false))
    }

    func testIndependentHypergateOpenToAll() {
        let hg = hypergate(govt: 50, minStatus: 32767)   // govt < 128 = independent
        XCTAssertTrue(hg.playerMayUseGate(standing: 0, hostile: false, allied: false))
    }

    func testHostileOwnerRefusesHypergate() {
        let hg = hypergate(govt: 183, minStatus: -32767)  // would otherwise always allow
        XCTAssertFalse(hg.playerMayUseGate(standing: 500, hostile: true, allied: true))
    }

    func testRestrictedHypergateNeedsStandingOrAlliance() {
        let hg = hypergate(govt: 183, minStatus: 32767)   // the stock "restricted network" case
        XCTAssertFalse(hg.playerMayUseGate(standing: 0, hostile: false, allied: false))
        XCTAssertTrue(hg.playerMayUseGate(standing: 1, hostile: false, allied: false))   // liked
        XCTAssertTrue(hg.playerMayUseGate(standing: 0, hostile: false, allied: true))    // allied
    }

    func testOrdinaryMinStatusThreshold() {
        let hg = hypergate(govt: 183, minStatus: 100)
        XCTAssertFalse(hg.playerMayUseGate(standing: 99, hostile: false, allied: false))
        XCTAssertTrue(hg.playerMayUseGate(standing: 100, hostile: false, allied: false))
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

    func testLinklessWormholeExitsAreOtherLinklessWormholes() {
        var col = ResourceCollection()
        col.add(gateSpob(id: 460, govt: 183, flags2: 0x2000, links: []))  // our wormhole (link-less)
        col.add(gateSpob(id: 461, govt: 183, flags2: 0x2000, links: []))  // another link-less wormhole
        col.add(system(id: 300, spobIDs: [460]))
        col.add(system(id: 301, spobIDs: [461]))
        let game = NovaGame(col)
        let exits = game.wormholeExitCandidates(from: game.spob(460)!)
        XCTAssertEqual(exits.map(\.gateSpobID), [461])
        XCTAssertEqual(exits.first?.systemID, 301)
    }
}
