import XCTest
import Foundation
import NovaSwiftKit
import NovaSwiftEngine
@testable import NovaSwiftStory

/// Batch 1b of docs/reverse-engineering/FIDELITY_PLAN.md on the pilot side:
/// the original's save cadence (UI-01), Strict Play deletion (FL-03), munitions
/// as pilot state (UI-02), load-time normalisation (UI-03) and the day costs of
/// a spaceport visit (FL-05). File tests use throwaway temp directories only.
final class PilotFidelityTests: XCTestCase {

    // MARK: UI-01 save cadence

    func testOnlyTheOriginalSavePointsSaveByDefault() {
        let all: [PilotSaveReason] = [.newPilot, .launch, .podRespawn, .manual, .land, .jump, .event,
                                      .periodic, .background, .backgroundLanded]
        let saved = all.filter { $0.shouldSave(frequentAutosave: false, strictPlay: false) }
        XCTAssertEqual(saved, [.newPilot, .launch, .backgroundLanded],
                       "a quit or suspend while landed saves, as the original's quit while landed does")
        XCTAssertEqual(all.filter { $0.shouldSave(frequentAutosave: false, strictPlay: true) },
                       [.newPilot, .launch, .podRespawn, .backgroundLanded],
                       "the pod respawn saves only under Strict Play")
        XCTAssertEqual(all.filter { $0.shouldSave(frequentAutosave: true, strictPlay: false) }, all,
                       "frequentAutosave keeps every NovaSwift save")
    }

    // MARK: FL-03 Strict Play deletion

    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for r in roots { try? FileManager.default.removeItem(at: r) }
    }

    private func tempArchive(cloud: Bool = false) -> PilotArchive {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("novaswift-strict-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return PilotArchive(location: cloud ? .iCloud(root) : .local(root))
    }

    func testStrictPlayDeathDeletesThePilotItsBackupsAndItsOtherStoreCopy() throws {
        let local = tempArchive()
        let cloud = tempArchive(cloud: true)
        var save = PilotSave(displayName: "Doomed", scenarioName: "", player: PlayerState(pilotName: "Doomed"), snapshot: .init())
        save = try local.save(save, backup: false)
        save = try local.save(save, backup: true)                    // leaves a backup
        let other = try local.save(PilotSave(displayName: "Other", scenarioName: "", player: PlayerState(), snapshot: .init()),
                                   backup: false)
        cloud.importPilots(from: local)                              // migration copies, it doesn't move
        XCTAssertFalse(local.backups(for: save.id).isEmpty)
        XCTAssertTrue(cloud.exists(id: save.id))

        XCTAssertEqual(PilotArchive.deleteEverywhere(id: save.id, archives: [local, cloud]), 2)
        XCTAssertFalse(local.exists(id: save.id))
        XCTAssertTrue(local.backups(for: save.id).isEmpty)
        XCTAssertFalse(cloud.exists(id: save.id))
        XCTAssertTrue(cloud.backups(for: save.id).isEmpty)
        XCTAssertTrue(local.exists(id: other.id), "other pilots are untouched")
        XCTAssertTrue(cloud.exists(id: other.id))
    }

    func testStrictPlayDeathSparesTheEscapePodHullAndNonStrictPilots() {
        var p = PlayerState(shipType: 128)
        XCTAssertFalse(p.strictPlayDeathDeletesPilot, "non-strict death only rolls back")
        p.strictPlay = true
        XCTAssertTrue(p.strictPlayDeathDeletesPilot)
        p.shipType = PlayerState.escapePodShipID
        XCTAssertFalse(p.strictPlayDeathDeletesPilot, "dying in the pod (shïp 895) keeps the pilot")
    }

    // MARK: UI-03 load

    func testLoadRestoresFullDefencesAndPrunesMissingPluginData() {
        var p = PlayerState(shipType: 999)
        p.shield = 3; p.armor = 4; p.fuel = 150
        p.outfits = [200: 1, 300: 2]
        p.cargo = [1: 5, 140: 2, 150: 1]
        let repaired = p.normalizeForLoad(outfitExists: { $0 == 200 }, junkExists: { $0 == 140 },
                                          shipExists: { $0 == 128 }, fallbackShipID: 128)
        XCTAssertTrue(repaired)
        XCTAssertNil(p.shield); XCTAssertNil(p.armor)
        XCTAssertEqual(p.fuel, 150, "only fuel is restored")
        XCTAssertEqual(p.outfits, [200: 1])
        XCTAssertEqual(p.cargo, [1: 5, 140: 2])
        XCTAssertEqual(p.shipType, 128)

        var intact = PlayerState(shipType: 128)
        intact.armor = 1
        XCTAssertFalse(intact.normalizeForLoad(outfitExists: { _ in true }, shipExists: { _ in true },
                                               fallbackShipID: 128))
        XCTAssertNil(intact.armor, "a damaged ship always loads at full")
    }

    // MARK: FL-05 visit days

    func testSpaceportVisitDayCosts() {
        var v = SpaceportVisitDays()
        XCTAssertEqual(v.departureDays, 1, "a plain landing and launch is one day")
        v.outfitTransaction = true
        XCTAssertEqual(v.departureDays, 2)
        v.shipPurchase = true
        XCTAssertEqual(v.departureDays, 6, "outfitter + ship in one visit: launch + 5")
        var e = SpaceportVisitDays()
        e.escortsSoldOrUpgraded = 1
        XCTAssertEqual(e.departureDays, 1, "one escort sold costs 0 days")
        e.escortsSoldOrUpgraded = 3
        XCTAssertEqual(e.departureDays, 2)
    }

    // MARK: UI-02 munitions

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }

    private func munitionsGame() -> NovaGame {
        var col = ResourceCollection()
        var hull = [UInt8](repeating: 0, count: 2000)
        put16(&hull, 2, 100); put16(&hull, 4, 300); put16(&hull, 6, 300); put16(&hull, 8, 30)
        put16(&hull, 10, 300); put16(&hull, 12, 500); put16(&hull, 14, 100)
        put16(&hull, 42, 4); put16(&hull, 44, 4)
        col.add(Resource(type: NovaType.ship, id: 128, name: "Carrier", data: Data(hull)))
        col.add(Resource(type: NovaType.ship, id: 129, name: "Fighter", data: Data(hull)))
        func weapon(_ id: Int, guidance: Int, ammoType: Int, maxAmmo: Int) {
            var w = [UInt8](repeating: 0, count: 140)
            put16(&w, 0, 30); put16(&w, 2, 60); put16(&w, 4, 10); put16(&w, 6, 10)
            put16(&w, 8, guidance); put16(&w, 10, 100); put16(&w, 12, ammoType); put16(&w, 108, maxAmmo)
            col.add(Resource(type: NovaType.weapon, id: id, name: "W\(id)", data: Data(w)))
        }
        weapon(130, guidance: -1, ammoType: 2, maxAmmo: 20)       // missile launcher, pool 130
        weapon(131, guidance: 99, ammoType: 129, maxAmmo: 4)      // fighter bay
        func outfit(_ id: Int, _ type: Int, _ value: Int) {
            var o = [UInt8](repeating: 0, count: 40)
            put16(&o, 6, type); put16(&o, 8, value)
            col.add(Resource(type: NovaType.outfit, id: id, name: "O\(id)", data: Data(o)))
        }
        outfit(210, 3, 130)   // missile
        outfit(211, 1, 130)   // launcher
        outfit(212, 1, 131)   // bay
        outfit(213, 3, 131)   // fighter
        return NovaGame(col)
    }

    func testFiredMissilesAndLostFightersStaySpent() throws {
        let game = munitionsGame()
        let galaxy = Galaxy(game: game)
        var state = PlayerState(shipType: 128)
        state.outfits = [211: 1, 210: 10, 212: 1, 213: 2]
        let ship = try XCTUnwrap(galaxy.makeLoadedShip(128, extraOutfits: state.outfits,
                                                       includeDefaultItems: false, includeHullWeapons: false))
        Munitions.loadCarriedFighters(into: ship, state: state, game: game)
        let launcher = try XCTUnwrap(ship.weapons.first { $0.spec.id == 130 })
        let bay = try XCTUnwrap(ship.fighterBays.first)
        XCTAssertEqual(launcher.ammo, 10)
        XCTAssertEqual(bay.docked, 2, "the bay carries the fighters owned, not a full load of 4")

        launcher.ammo = 5          // fired 5
        bay.docked = 1             // lost one
        XCTAssertTrue(Munitions.record(ship, into: &state, game: game))
        XCTAssertEqual(state.outfits[210], 5)
        XCTAssertEqual(state.outfits[213], 1)

        launcher.ammo = 8          // plundered 3
        Munitions.record(ship, into: &state, game: game)
        XCTAssertEqual(state.outfits[210], 8, "plundered rounds add to the owned count")

        launcher.ammo = 0
        Munitions.record(ship, into: &state, game: game)
        XCTAssertNil(state.outfits[210], "an empty pool owns no rounds")
        XCTAssertEqual(state.outfits[211], 1, "the launcher itself is untouched")
    }
}
