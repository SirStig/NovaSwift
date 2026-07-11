import XCTest
@testable import NovaSwiftKit

/// Ground-truth checks for the outfit mechanics wired up in the outfitter audit:
/// map reveal (ModType 16), increase-maximum (ModType 27), OnPurchase/OnSell
/// decode, and the sell-anywhere (Flags 0x0800) tech-level bypass. All values
/// trace to the EV Nova Bible's `oütf` field/ModType definitions.
final class OutfitMechanicsTests: XCTestCase {

    // MARK: byte builders

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }
    private func put32(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt32(bitPattern: Int32(truncatingIfNeeded: v))
        b[off] = UInt8((u >> 24) & 0xff); b[off + 1] = UInt8((u >> 16) & 0xff)
        b[off + 2] = UInt8((u >> 8) & 0xff); b[off + 3] = UInt8(u & 0xff)
    }
    private func putStr(_ b: inout [UInt8], _ off: Int, _ s: String) {
        for (i, byte) in Array(s.utf8).enumerated() { b[off + i] = byte }
    }

    /// A full-size (1028-byte) outfit with one modifier slot, plus optional
    /// flags/cost/max/tech and an OnPurchase string.
    private func outfit(_ id: Int, name: String = "Item",
                        modType: Int = -1, modVal: Int = 0,
                        flags: Int = 0, cost: Int = 0, max: Int = 0,
                        tech: Int = 1, mass: Int = 0,
                        onPurchase: String = "", onSell: String = "") -> Resource {
        var b = [UInt8](repeating: 0, count: 1028)
        put16(&b, 2, mass)
        put16(&b, 4, tech)
        put16(&b, 6, modType); put16(&b, 8, modVal)   // primary modifier slot
        put16(&b, 10, max)
        put16(&b, 12, flags)
        put32(&b, 14, cost)
        putStr(&b, 301, onPurchase)
        putStr(&b, 556, onSell)
        return Resource(type: NovaType.outfit, id: id, name: name, data: Data(b))
    }

    private func system(_ id: Int, links: [Int] = [], spobs: [Int] = [], govt: Int = -1) -> Resource {
        var b = [UInt8](repeating: 0, count: 420)
        for (i, l) in links.prefix(16).enumerated() { put16(&b, 4 + i * 2, l) }
        for (i, s) in spobs.prefix(16).enumerated() { put16(&b, 36 + i * 2, s) }
        put16(&b, 102, govt)
        return Resource(type: NovaType.syst, id: id, name: "Sys\(id)", data: Data(b))
    }

    private func spob(_ id: Int, canLand: Bool, govt: Int = -1) -> Resource {
        var b = [UInt8](repeating: 0, count: 60)
        put32(&b, 6, canLand ? 0x01 : 0x00)   // Flags: 0x01 = can land
        put16(&b, 20, govt)
        return Resource(type: NovaType.spob, id: id, name: "Spob\(id)", data: Data(b))
    }

    private func govt(_ id: Int, classes: [Int]) -> Resource {
        var b = [UInt8](repeating: 0, count: 180)
        for i in 0..<4 { put16(&b, 24 + i * 2, i < classes.count ? classes[i] : -1) }
        return Resource(type: NovaType.govt, id: id, name: "Govt\(id)", data: Data(b))
    }

    // MARK: map reveal — ModType 16

    /// A chain 128—129—130—131. A positive map value reveals exactly that many
    /// hyperjumps out from the origin, inclusive — the Bible's "How many jumps
    /// away from present system to explore".
    func testMapPositiveRevealsNJumps() {
        var col = ResourceCollection()
        col.add(system(128, links: [129]))
        col.add(system(129, links: [128, 130]))
        col.add(system(130, links: [129, 131]))
        col.add(system(131, links: [130]))
        let game = NovaGame(col)

        XCTAssertEqual(game.mapRevealedSystems(modVal: 1, from: 128), [128, 129])
        XCTAssertEqual(game.mapRevealedSystems(modVal: 2, from: 128), [128, 129, 130])
        XCTAssertEqual(game.mapRevealedSystems(modVal: 3, from: 128), [128, 129, 130, 131])
        // A big value never exceeds the reachable graph — and is NOT "the whole
        // galaxy" if the galaxy has disconnected components (see below).
        XCTAssertEqual(game.mapRevealedSystems(modVal: 99, from: 129), [128, 129, 130, 131])
    }

    /// The pre-fix bug: buying any map revealed *everything*. A scoped reveal must
    /// leave an unreachable, different-faction system hidden.
    func testMapDoesNotRevealWholeGalaxy() {
        var col = ResourceCollection()
        col.add(system(128, links: [129]))
        col.add(system(129, links: [128]))
        col.add(system(500, links: []))       // disconnected island
        let game = NovaGame(col)
        let revealed = game.mapRevealedSystems(modVal: 5, from: 128)
        XCTAssertTrue(revealed.contains(128))
        XCTAssertTrue(revealed.contains(129))
        XCTAssertFalse(revealed.contains(500), "an unlinked system must stay hidden")
    }

    /// ModVal -1 = "all inhabited independent systems": independent (govt -1) AND
    /// has a landable stellar.
    func testMapMinusOneRevealsInhabitedIndependent() {
        var col = ResourceCollection()
        col.add(system(128, spobs: [200], govt: -1))   // independent, inhabited
        col.add(system(129, spobs: [201], govt: 128))  // govt-owned, inhabited
        col.add(system(130, spobs: [], govt: -1))      // independent, uninhabited
        col.add(spob(200, canLand: true, govt: -1))
        col.add(spob(201, canLand: true, govt: 128))
        let game = NovaGame(col)
        XCTAssertEqual(game.mapRevealedSystems(modVal: -1, from: 128), [128])
    }

    /// ModVal <= -1000 = "all systems of this govt class" (-1000 → class 0,
    /// -1005 → class 5).
    func testMapGovtClassReveal() {
        var col = ResourceCollection()
        col.add(system(128, govt: 128))
        col.add(system(129, govt: 129))
        col.add(system(130, govt: 128))
        col.add(govt(128, classes: [5]))
        col.add(govt(129, classes: [7]))
        let game = NovaGame(col)
        XCTAssertEqual(game.mapRevealedSystems(modVal: -1005, from: 128), [128, 130])
        XCTAssertEqual(game.mapRevealedSystems(modVal: -1007, from: 128), [129])
        XCTAssertEqual(game.mapRevealedSystems(modVal: -1000, from: 128), [], "no govt is in class 0")
    }

    func testMapZeroAndUndefinedBandRevealNothing() {
        var col = ResourceCollection()
        col.add(system(128, links: [129]))
        col.add(system(129, links: [128]))
        let game = NovaGame(col)
        XCTAssertEqual(game.mapRevealedSystems(modVal: 0, from: 128), [])
        XCTAssertEqual(game.mapRevealedSystems(modVal: -50, from: 128), [], "the (-1,-1000) band is undefined")
    }

    // MARK: increase-maximum — ModType 27

    func testIncreaseMaxMultipliesCap() {
        var col = ResourceCollection()
        col.add(outfit(200, name: "Ammo", max: 3))              // base cap 3
        col.add(outfit(201, name: "Magazine", modType: 27, modVal: 200)) // expands 200
        let game = NovaGame(col)

        XCTAssertEqual(game.effectiveMaxInstallable(of: 200, ownedOutfits: [:]), 3,
                       "no expander owned → standard max")
        XCTAssertEqual(game.effectiveMaxInstallable(of: 200, ownedOutfits: [201: 1]), 3,
                       "1 expander → base × 1")
        XCTAssertEqual(game.effectiveMaxInstallable(of: 200, ownedOutfits: [201: 2]), 6,
                       "2 expanders → base × 2")
    }

    func testIncreaseMaxLeavesUnlimitedUnlimited() {
        var col = ResourceCollection()
        col.add(outfit(200, name: "Cargo Pod", max: 0))         // 0 = unlimited
        col.add(outfit(201, name: "Expander", modType: 27, modVal: 200))
        let game = NovaGame(col)
        XCTAssertEqual(game.effectiveMaxInstallable(of: 200, ownedOutfits: [201: 3]), 0,
                       "unlimited stays unlimited")
    }

    // MARK: OnPurchase / OnSell decode — @301 / @556

    func testOnPurchaseOnSellDecode() {
        let o = OutfRes(outfit(300, onPurchase: "b1000", onSell: "!b1000"))
        XCTAssertEqual(o.onPurchase, "b1000")
        XCTAssertEqual(o.onSell, "!b1000")
        // A short/garbled record must not crash the decoder.
        let short = OutfRes(Resource(type: NovaType.outfit, id: 301, name: "x", data: Data([0, 0])))
        XCTAssertEqual(short.onPurchase, "")
        XCTAssertEqual(short.onSell, "")
    }

    // MARK: sell-anywhere tech bypass — Flags 0x0800

    func testSellAnywhereBypassesTechLevel() {
        var col = ResourceCollection()
        // Outfitter present (flags 0x04), tech level 1.
        var s = [UInt8](repeating: 0, count: 60)
        put32(&s, 6, 0x04)     // hasOutfitter
        put16(&s, 12, 1)       // techLevel 1
        col.add(Resource(type: NovaType.spob, id: 400, name: "Port", data: Data(s)))
        col.add(outfit(200, name: "Too Advanced", tech: 99))                 // gated out
        col.add(outfit(201, name: "Sold Anywhere", flags: 0x0800, tech: 99)) // 0x0800 bypasses
        let game = NovaGame(col)
        let spob = game.spob(400)!
        let ids = Set(game.outfitsSold(at: spob).map(\.id))
        XCTAssertFalse(ids.contains(200), "tech-99 item hidden at tech-1 port")
        XCTAssertTrue(ids.contains(201), "0x0800 item sold regardless of tech level")
    }
}
