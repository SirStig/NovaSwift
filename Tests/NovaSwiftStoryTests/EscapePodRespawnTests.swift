import XCTest
import NovaSwiftKit
import NovaSwiftEngine
@testable import NovaSwiftStory

/// OS-02: the escape-pod respawn as pure edits of the pilot.
final class EscapePodRespawnTests: XCTestCase {

    private func system(_ id: Int, links: [Int], spobs: [Int]) -> Resource {
        var b = [UInt8](repeating: 0, count: 420)
        for i in 0..<16 { Bytes.i16(&b, 4 + i * 2, i < links.count ? links[i] : -1) }
        for i in 0..<16 { Bytes.i16(&b, 36 + i * 2, i < spobs.count ? spobs[i] : -1) }
        return Resource(type: NovaType.syst, id: id, name: "S\(id)", data: Data(b))
    }

    private func spob(_ id: Int, shipyard: Bool, minStatus: Int = -32767, govt: Int = -1) -> Resource {
        var b = [UInt8](repeating: 0, count: 1100)
        Bytes.i32(&b, 6, 0x01 | (shipyard ? 0x08 : 0))   // can land (+ shipyard)
        Bytes.i16(&b, 20, govt)
        Bytes.i16(&b, 22, minStatus)
        Bytes.i16(&b, 24, 1000)
        return Resource(type: NovaType.spob, id: id, name: "P\(id)", data: Data(b))
    }

    /// 128 (death, has a yard) — 129 (no yard) — 130 (yard); 128 — 131 (yard, unexplored).
    private func world() -> NovaGame {
        makeGame([
            system(128, links: [129, 131], spobs: [128]),
            system(129, links: [128, 130], spobs: [129]),
            system(130, links: [129], spobs: [130]),
            system(131, links: [128], spobs: [131]),
            spob(128, shipyard: true), spob(129, shipyard: false),
            spob(130, shipyard: true), spob(131, shipyard: true),
        ])
    }

    func testRespawnSearchesKnownNeighboursAndNeverTheDeathSystem() {
        let game = world()
        var state = PlayerState(currentSystem: 128)
        state.exploredSystems = [128, 129, 130]
        let found = EscapePodRespawn.respawnStellar(from: 128, state: state, game: game, isVisible: { _ in true })
        XCTAssertEqual(found?.spob, 130)
        XCTAssertEqual(found?.system, 130)
        state.exploredSystems.insert(131)
        XCTAssertEqual(EscapePodRespawn.respawnStellar(from: 128, state: state, game: game,
                                                       isVisible: { _ in true })?.spob, 131,
                       "an adjacent shipyard comes before recursing")
        XCTAssertEqual(EscapePodRespawn.respawnStellar(from: 128, state: state, game: game,
                                                       isVisible: { $0 != 131 })?.spob, 130,
                       "hidden systems are skipped")
        state.exploredSystems = [128]
        XCTAssertNil(EscapePodRespawn.respawnStellar(from: 128, state: state, game: game, isVisible: { _ in true }))
    }

    /// D-8: a map-charted (level 2) neighbour qualifies; a "land only when
    /// destroyed" port qualifies only as a wreck (0x004677a0 / 0x0046e440).
    func testRespawnCountsChartedSystemsAndTheDestroyedRule() {
        let game = world()
        var state = PlayerState(currentSystem: 128)
        state.exploredSystems = [128]
        state.chartSystems([131])
        XCTAssertEqual(EscapePodRespawn.respawnStellar(from: 128, state: state, game: game,
                                                       isVisible: { _ in true })?.spob, 131)
        var wreck = [UInt8](repeating: 0, count: 1100)
        Bytes.i32(&wreck, 6, 0x01 | 0x08 | 0x80)
        Bytes.i16(&wreck, 20, -1)
        Bytes.i16(&wreck, 22, -32767)
        let g2 = makeGame([
            system(128, links: [129], spobs: []),
            system(129, links: [128], spobs: [129]),
            Resource(type: NovaType.spob, id: 129, name: "W", data: Data(wreck)),
        ])
        var s2 = PlayerState(currentSystem: 128)
        s2.exploredSystems = [128, 129]
        XCTAssertNil(EscapePodRespawn.respawnStellar(from: 128, state: s2, game: g2, isVisible: { _ in true }),
                     "intact: not usable")
        s2.markStellarShotDown(129, onDay: 0)
        XCTAssertEqual(EscapePodRespawn.respawnStellar(from: 128, state: s2, game: g2, isVisible: { _ in true })?.spob, 129)
    }

    func testRespawnHonoursMinStatus() {
        let game = makeGame([
            system(128, links: [129], spobs: []),
            system(129, links: [128], spobs: [129]),
            spob(129, shipyard: true, minStatus: 10, govt: 140),
            govtResource(id: 140),
        ])
        var state = PlayerState(currentSystem: 128)
        state.exploredSystems = [128, 129]
        XCTAssertNil(EscapePodRespawn.respawnStellar(from: 128, state: state, game: game, isVisible: { _ in true }))
        state.systemReputation = [129: 10]
        XCTAssertEqual(EscapePodRespawn.respawnStellar(from: 128, state: state, game: game,
                                                       isVisible: { _ in true })?.spob, 129)
    }

    func testResetToClassZeroKeepsOnlyPersistentOutfits() {
        var persistent = [UInt8](repeating: 0, count: 1012)
        for pos in [6, 18, 22, 26] { Bytes.i16(&persistent, pos, -1) }
        Bytes.i16(&persistent, 12, 0x0004)
        let game = makeGame([
            shipResource(id: 128, cargo: 10, freeMass: 10, defaultItems: [(id: 202, count: 1)]),
            shipResource(id: 140, cargo: 50, freeMass: 50),
            Resource(type: NovaType.outfit, id: 200, name: "License", data: Data(persistent)),
            outfitResource(id: 201, name: "Shield Booster"),
            outfitResource(id: 202, name: "Stock Item"),
        ])
        var state = PlayerState(shipType: 140, currentSystem: 128)
        state.outfits = [200: 1, 201: 3]
        state.cargo = [0: 5]
        EscapePodRespawn.resetToClassZero(&state, game: game)
        XCTAssertEqual(state.shipType, 128)
        XCTAssertEqual(state.outfits, [200: 1, 202: 1])
        XCTAssertTrue(state.cargo.isEmpty)
        XCTAssertEqual(EscapePodRespawn.driftDays(roll30: 0), 15)
        XCTAssertEqual(EscapePodRespawn.driftDays(roll30: 29), 44)
    }

    func testFinishRespawnRenamesResetsStandingAndRefillsArmorWithShields() {
        var hull = [UInt8](repeating: 0, count: 1860)
        Bytes.i16(&hull, 2, 300)    // shield
        Bytes.i16(&hull, 14, 120)   // armor
        Bytes.i16(&hull, 12, 10)
        for off in [18, 20, 22, 24, 78, 80, 82, 84, 880, 882, 884, 886, 1742, 1744, 1746, 1748] { Bytes.i16(&hull, off, -1) }
        let game = makeGame([Resource(type: NovaType.ship, id: 128, name: "Shuttle", data: Data(hull))])
        var state = PlayerState(shipType: 128, currentSystem: 128)
        state.systemReputation = [128: -500]
        EscapePodRespawn.finishRespawn(&state, game: game, galaxy: Galaxy(game: game),
                                       registrationDigits: [3, 1, 4, 1])
        XCTAssertEqual(state.shipName, "Shuttle 3141")
        XCTAssertEqual(state.reputation(atSystem: 128), 0, "standing back to InitialRec")
        XCTAssertEqual(state.armor, 300, "armor refilled with the max *shield* (0x0044d83f)")
    }
}
