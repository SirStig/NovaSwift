import XCTest
import NovaSwiftKit
@testable import NovaSwiftStory

/// Same-position twin systems (0x00448090, 0x00432470, 0x0046b920,
/// 0x0046b9b0): stellar ownership, the pilot's relocation and the shared
/// discovery level follow `sÿst.Visibility`.
final class TwinSystemTests: XCTestCase {

    private func system(_ id: Int, x: Int, y: Int, links: [Int] = [], spobs: [Int], visibility: String = "") -> Resource {
        var b = [UInt8](repeating: 0, count: 420)
        Bytes.i16(&b, 0, x)
        Bytes.i16(&b, 2, y)
        for i in 0..<16 { Bytes.i16(&b, 4 + i * 2, i < links.count ? links[i] : -1) }
        for i in 0..<16 { Bytes.i16(&b, 36 + i * 2, i < spobs.count ? spobs[i] : -1) }
        Bytes.cstr(&b, 150, visibility)
        return Resource(type: NovaType.syst, id: id, name: "S\(id)", data: Data(b))
    }

    private func spob(_ id: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 1100)
        Bytes.i32(&b, 6, 0x01)
        Bytes.i16(&b, 20, -1)
        return Resource(type: NovaType.spob, id: id, name: "P\(id)", data: Data(b))
    }

    /// 200 (b100) and 201 (always) at one spot, both listing stellar 300;
    /// 202 elsewhere.
    private func twins() -> NovaGame {
        makeGame([
            system(200, x: 10, y: 10, spobs: [300], visibility: "b100"),
            system(201, x: 10, y: 10, spobs: [300]),
            system(202, x: 50, y: 50, links: [200], spobs: [301]),
            spob(300), spob(301),
        ])
    }

    func testStellarBelongsToTheLowestVisibleTwin() {
        let game = twins()
        var state = PlayerState(currentSystem: 202)
        XCTAssertEqual(game.owningSystem(ofSpob: 300, state: state), 201, "200 is hidden while b100 is clear")
        state.setBit(100)
        XCTAssertEqual(game.owningSystem(ofSpob: 300, state: state), 200, "the lowest visible system claims it")
    }

    func testOnlyTheFirstVisibleTwinClaimsStellars() {
        // Both twins visible: 201 is claimed by 200's group, so a stellar only
        // 201 lists has no visible owner and falls back to the first listing.
        let game = makeGame([
            system(200, x: 10, y: 10, spobs: [300]),
            system(201, x: 10, y: 10, spobs: [300, 302]),
            system(203, x: 90, y: 90, spobs: [302], visibility: "b1"),
            spob(300), spob(302),
        ])
        let state = PlayerState(currentSystem: 200)
        XCTAssertEqual(game.owningSystem(ofSpob: 300, state: state), 200)
        XCTAssertEqual(game.systemContaining(spob: 302, hidden: []), 203,
                       "201 is claimed by its twin 200, so the next visible lister owns it")
        XCTAssertEqual(game.systemContaining(spob: 302, hidden: [203]), 201,
                       "no visible claimant: the first system that lists it")
    }

    func testPilotInAHiddenSystemMovesToItsVisibleTwin() {
        let game = twins()
        var state = PlayerState(currentSystem: 200)
        state.setBit(100)
        let engine = StoryEngine(game: game, player: state)
        XCTAssertNil(engine.resolveCurrentSystemVisibility())
        engine.apply(set: "!b100")
        XCTAssertEqual(engine.player.currentSystem, 201)
    }

    func testFullyHiddenGroupForcesItsRootVisible() {
        let game = makeGame([
            system(200, x: 10, y: 10, spobs: [300], visibility: "b100"),
            system(201, x: 10, y: 10, spobs: [300], visibility: "b101"),
            spob(300),
        ])
        let engine = StoryEngine(game: game, player: PlayerState(currentSystem: 201))
        XCTAssertEqual(engine.resolveCurrentSystemVisibility(), 200, "to the group root")
        XCTAssertTrue(engine.isSystemVisible(200), "reactivated while the pilot is there")
        XCTAssertFalse(engine.hiddenSystemIDs().contains(200))
        XCTAssertTrue(engine.hiddenSystemIDs().contains(201))
    }

    func testTwinsShareTheirDiscoveryLevel() {
        let game = twins()
        var state = PlayerState(currentSystem: 202)
        state.exploredSystems = [202, 201]
        state.landedSystems = [201]
        state.shareTwinDiscovery(game.reputationMap())
        XCTAssertTrue(state.isSystemExplored(200), "NCB E reads the group's level")
        XCTAssertEqual(state.discoveryLevel(200), 2)
        XCTAssertEqual(state.discoveryLevel(202), 1)
    }

    func testVisibleTwinWalksTheGroupFromItsRoot() {
        let game = twins()
        XCTAssertEqual(game.visibleTwin(of: 201, hidden: []), 200, "a visible lower twin wins")
        XCTAssertEqual(game.visibleTwin(of: 200, hidden: [200]), 201)
        XCTAssertNil(game.visibleTwin(of: 202, hidden: [202]))
    }
}
