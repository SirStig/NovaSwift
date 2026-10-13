import XCTest
import Foundation
import NovaSwiftKit
import NovaSwiftEngine
@testable import NovaSwiftStory

/// FIDELITY_PLAN closing pass: EC-04 / EC-05 (gates share the planet ladder and fee), EC-25 (a
/// bribe is one approach), EC-10 (rank privileges spread over allied governments), EC-12 (the
/// RequireGovt bands) and OS-08 (the bomb fuse reseeds on every recompute).
final class ClosingPassGatesRanksTests: XCTestCase {

    // MARK: Builders

    private func spob(_ id: Int, govt: Int = -1, flags: UInt32 = 0x01, flags2: UInt32 = 0,
                      minStatus: Int = 0, fee: Int = 0) -> Resource {
        var b = [UInt8](repeating: 0, count: 1102)
        Bytes.i32(&b, 6, Int(Int32(bitPattern: flags)))
        Bytes.i16(&b, 20, govt)
        Bytes.i16(&b, 22, minStatus)
        Bytes.i32(&b, 30, Int(Int32(bitPattern: flags2)))
        for i in 0..<8 { Bytes.i16(&b, 38 + i * 2, -1) }
        Bytes.i32(&b, 564, fee)
        return Resource(type: NovaType.spob, id: id, name: "Spob \(id)", data: Data(b))
    }

    private func system(_ id: Int, govt: Int, spobs: [Int]) -> Resource {
        var b = [UInt8](repeating: 0, count: 160)
        for i in 0..<16 { Bytes.i16(&b, 4 + i * 2, -1); Bytes.i16(&b, 36 + i * 2, -1) }
        for (i, s) in spobs.enumerated() { Bytes.i16(&b, 36 + i * 2, s) }
        for i in 0..<8 { Bytes.i16(&b, 68 + i * 2, -1) }
        Bytes.i16(&b, 102, govt)
        return Resource(type: NovaType.syst, id: id, name: "System \(id)", data: Data(b))
    }

    private func govt(_ id: Int, flags1: Int = 0, classes: [Int] = [], allies: [Int] = [], require: UInt64 = 0) -> Resource {
        var b = [UInt8](repeating: 0, count: 176)
        Bytes.i16(&b, 2, flags1)
        for i in 0..<4 {
            Bytes.i16(&b, 24 + i * 2, i < classes.count ? classes[i] : -1)
            Bytes.i16(&b, 32 + i * 2, i < allies.count ? allies[i] : -1)
            Bytes.i16(&b, 40 + i * 2, -1)
        }
        Bytes.i32(&b, 84, Int(Int32(truncatingIfNeeded: require >> 32)))
        Bytes.i32(&b, 88, Int(Int32(truncatingIfNeeded: require & 0xFFFF_FFFF)))
        return Resource(type: NovaType.govt, id: id, name: "Govt \(id)", data: Data(b))
    }

    private func clearance(_ game: NovaGame, _ id: Int, _ state: PlayerState, bribed: Bool = false,
                           bits: UInt64 = 0) -> LandedServices.LandingClearance {
        LandedServices.landingClearance(spob: game.spob(id)!, system: 128, state: state, game: game,
                                        diplomacy: nil, contributedBits: bits, bribed: bribed)
    }

    // MARK: EC-04 · gates run the planet ladder

    func testGatesAndWormholesShareTheLandingLadder() {
        let game = makeGame([
            govt(183), govt(140), system(128, govt: 183, spobs: [140, 141, 142, 143]),
            spob(140, govt: 183, flags: 0x21, flags2: 0x1000, minStatus: 32767),    // stock-style hypergate
            spob(141, govt: 183, flags: 0x21, flags2: 0x2000, minStatus: 32767),    // wormhole, same MinStatus
            spob(142, govt: 50, flags: 0x21, flags2: 0x1000, minStatus: 32767),     // government below 128
            spob(143, govt: 183, flags: 0x21, flags2: 0x1000, minStatus: -32767),   // always open
            rankResource(200, govt: 183, flags: 0x0200),
        ])
        var state = PlayerState(credits: 1000)
        state.systemReputation = [128: 500]
        XCTAssertEqual(clearance(game, 140, state), .denied, "MinStatus 32767 is refused whatever the standing")
        XCTAssertEqual(clearance(game, 141, state), .denied, "a wormhole uses the same ladder")
        XCTAssertEqual(clearance(game, 142, state), .denied, "government below 128 is no automatic pass")
        XCTAssertEqual(clearance(game, 143, state), .granted)
        state.systemReputation = [128: -5000]
        XCTAssertEqual(clearance(game, 143, state), .granted, "a hostile owner is no automatic fail at MinStatus -32767")
        // A waiver in the ladder opens it.
        var dominated = state; dominated.dominate(140)
        XCTAssertEqual(clearance(game, 140, dominated), .granted, "domination")
        var onMission = state
        onMission.activeMissions = [ActiveMission(missionID: 128, acceptedDate: state.date, deadline: nil,
                                                  cargoPickedUp: false, shipObjectivesRemaining: 0, travelSpobID: 141)]
        XCTAssertEqual(clearance(game, 141, onMission), .granted, "a mission stellar")
        var ranked = state; ranked.activeRanks = [200]
        XCTAssertEqual(clearance(game, 140, ranked), .granted, "AlwaysLand")
    }

    // MARK: EC-05 · the gate fee

    func testGateFeeRefusesAndIsCharged() {
        let game = makeGame([
            govt(183), system(128, govt: 183, spobs: [140]),
            spob(140, govt: 183, flags: 0x21, flags2: 0x1000, minStatus: -32767, fee: 100),
        ])
        let gate = game.spob(140)!
        XCTAssertEqual(clearance(game, 140, PlayerState(credits: 99)), .cannotPayFee(100))
        XCTAssertEqual(LandedServices.refusalMessage(.cannotPayFee(100), spob: gate, game: game)?.isEmpty, false)
        var state = PlayerState(credits: 150)
        XCTAssertEqual(clearance(game, 140, state), .granted)
        XCTAssertEqual(LandedServices.chargeGateFee(spob: gate, state: &state), 100)
        XCTAssertEqual(state.credits, 50)
        state.dominate(140)
        XCTAssertEqual(LandedServices.chargeGateFee(spob: gate, state: &state), 0, "a dominated body waives the fee")
        XCTAssertEqual(state.credits, 50)
    }

    // MARK: EC-25 · a bribe waives MinStatus but not Require

    func testBribeWaivesMinStatusOnlyAndOneApproachIsAFlag() {
        let game = makeGame([
            govt(140), govt(141, require: 0x2), system(128, govt: 140, spobs: [130, 131]),
            spob(130, govt: 140, minStatus: 32767), spob(131, govt: 141, minStatus: 32767),
        ])
        let state = PlayerState(credits: 10)
        XCTAssertEqual(clearance(game, 130, state), .denied)
        XCTAssertEqual(clearance(game, 130, state, bribed: true), .granted, "the paid timer waives MinStatus")
        XCTAssertEqual(clearance(game, 131, state, bribed: true), .denied, "Require can still refuse")
        XCTAssertEqual(clearance(game, 131, state, bribed: true, bits: 0x2), .granted)
        let comm = FlightComm()
        XCTAssertFalse(comm.hasBribeWaiver)
        comm.consumeBribeWaiver()
        XCTAssertNil(comm.bribeWaiverStellar)
    }

    // MARK: EC-10 · rank privileges reach allied governments

    func testRankPrivilegeSpreadsOverAlliesButNotDerelicts() {
        // A (128) classes [1]; B (129) lists A's class as an ally; C (130) derelict ally; D (131) unrelated.
        let game = makeGame([
            govt(128, classes: [1]), govt(129, classes: [2], allies: [1]),
            govt(130, flags1: 0x0800, classes: [3], allies: [1]), govt(131, classes: [4]),
            rankResource(200, govt: 128, flags: 0x0100 | 0x0200),
        ])
        let ranks: Set<Int> = [200]
        XCTAssertEqual(RankPrivilege.governments(with: RankPrivilege.wontAttack, activeRanks: ranks, game: game), [128, 129],
                       "own government and its ally, not the derelict or the stranger")
        XCTAssertTrue(RankPrivilege.has(RankPrivilege.alwaysLand, govt: 129, activeRanks: ranks, game: game))
        XCTAssertFalse(RankPrivilege.has(RankPrivilege.alwaysLand, govt: 130, activeRanks: ranks, game: game))
        XCTAssertFalse(RankPrivilege.has(RankPrivilege.alwaysLand, govt: 131, activeRanks: ranks, game: game))
        // The seeded diplomacy shields the player from B's ships too.
        let dip = Diplomacy(govts: game.govts())
        var pilot = PlayerState(currentSystem: 128)
        pilot.activeRanks = ranks
        WorldPilotLink.seedDiplomacy(dip, pilot: pilot, game: game, systemID: 128)
        XCTAssertEqual(dip.rankProtectedGovts, [128, 129])
        // AlwaysLand colours B's planet on the radar and the map.
        let bPlanet = makeGame([govt(128, classes: [1]), govt(129, classes: [2], allies: [1]),
                                rankResource(200, govt: 128, flags: 0x0200),
                                spob(150, govt: 129, minStatus: 32767), system(128, govt: 129, spobs: [150])])
        var p2 = PlayerState(currentSystem: 128)
        p2.systemReputation = [128: -5]
        func color() -> RadarIFF.RGB16 { RadarIFF.stellarColor(bPlanet.spob(150)!, state: p2, game: bPlanet, system: 128) }
        XCTAssertEqual(color().r, RadarIFF.red.r, "refused without the rank")
        p2.activeRanks = [200]
        XCTAssertEqual(color().g, RadarIFF.yellow.g, "AlwaysLand reaches the allied planet")
    }

    // MARK: EC-12 · RequireGovt bands

    func testRequireGovtBandsEnforceOrWaiveTheBits() {
        let game = makeGame([
            govt(130, classes: [1]), govt(131, classes: [2], allies: [1]), govt(132, classes: [3]),
            spob(300, govt: 130), spob(301, govt: 131), spob(302, govt: 132), spob(303, govt: -1),
        ])
        func enforced(_ rg: Int, _ port: Int) -> Bool { game.requireBitsEnforced(rg, at: game.spob(port)!) }
        // 128-383: enforce only at that government or an ally.
        XCTAssertTrue(enforced(130, 300)); XCTAssertTrue(enforced(130, 301))
        XCTAssertFalse(enforced(130, 302)); XCTAssertFalse(enforced(130, 303))
        // 1128-1383: also at an independent port.
        XCTAssertTrue(enforced(1130, 303)); XCTAssertFalse(enforced(1130, 302))
        // 2128-2383: waived at that government or an ally, enforced everywhere else, independent included.
        XCTAssertFalse(enforced(2130, 300)); XCTAssertFalse(enforced(2130, 301))
        XCTAssertTrue(enforced(2130, 302)); XCTAssertTrue(enforced(2130, 303))
        // 3128-3383: also waived at an independent port.
        XCTAssertFalse(enforced(3130, 303)); XCTAssertTrue(enforced(3130, 302))
        // Outside every band the bits always apply.
        for rg in [-1, 0, 127, 384, 1000, 1127, 1384, 2000, 2384, 3384, 4000] {
            XCTAssertTrue(enforced(rg, 300), "RequireGovt \(rg)")
        }
    }

    func testRequireGovtWaiverAllowsTheBuyAndOwningDoesNotSkipTheBits() {
        var o = [UInt8](repeating: 0, count: 1012)
        for pos in [6, 18, 22, 26] { Bytes.i16(&o, pos, -1) }
        Bytes.i32(&o, 38, 0); Bytes.i32(&o, 42, 0x2)                 // Require bit 1
        Bytes.i16(&o, 1010, 2130)                                     // waived at govt 130 and allies
        let game = makeGame([
            govt(130, classes: [1]), govt(132, classes: [3]), spob(300, govt: 130), spob(302, govt: 132),
            Resource(type: NovaType.outfit, id: 500, name: "Item", data: Data(o)),
        ])
        let item = game.outfit(500)!
        let dip = Diplomacy(govts: game.govts())
        var pilot = PlayerState()
        XCTAssertEqual(game.lockState(for: item, pilot: pilot, at: game.spob(300)!, diplomacy: dip), .available,
                       "buyable at the waived government without the Require bits")
        XCTAssertNotEqual(game.lockState(for: item, pilot: pilot, at: game.spob(302)!, diplomacy: dip), .available,
                          "locked at an unrelated government when the bits fail")
        pilot.outfits[500] = 1
        XCTAssertNotEqual(game.lockState(for: item, pilot: pilot, at: game.spob(302)!, diplomacy: dip), .available,
                          "already owning one does not skip the bits")
    }

    // MARK: OS-08 · the fuse reseeds on every recompute

    func testBombFuseReseedsOnEveryRecomputeAndLethalWins() {
        func bomb(_ id: Int, type: Int) -> Resource {
            var b = [UInt8](repeating: 0, count: 1012)
            for pos in [6, 18, 22, 26] { Bytes.i16(&b, pos, -1) }
            Bytes.i16(&b, 6, type); Bytes.i16(&b, 8, 0)
            return Resource(type: NovaType.outfit, id: id, name: "Bomb \(id)", data: Data(b))
        }
        let game = makeGame([bomb(400, type: 50), bomb(401, type: 47)])
        var pilot = PlayerState()
        var fuse: Int? = 250
        HazardOutfits.recompute(fuse: &fuse, pilot: pilot, game: game, rand: { _ in 42 })
        XCTAssertNil(fuse, "no bomb aboard: the timer clears")
        pilot.outfits[400] = 1
        HazardOutfits.recompute(fuse: &fuse, pilot: pilot, game: game, rand: { _ in 42 })
        XCTAssertEqual(fuse, 42)
        fuse = 280                                       // a fuse well on its way ...
        HazardOutfits.recompute(fuse: &fuse, pilot: pilot, game: game, rand: { _ in 7 })
        XCTAssertEqual(fuse, 7, "... is drawn again by the next recompute (a jump or launch does not keep it)")
        pilot.outfits[401] = 1
        XCTAssertEqual(HazardOutfits.activeBomb(pilot: pilot, game: game)?.0.id, 401, "ModType 47 outranks 50")
    }
}
