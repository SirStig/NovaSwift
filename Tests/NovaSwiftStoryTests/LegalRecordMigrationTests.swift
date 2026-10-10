import XCTest
import NovaSwiftKit
@testable import NovaSwiftStory

/// Pilots saved under the old per-government legal record still load, and are
/// moved onto one reputation per system (EC-02, Q-EC-10 "migration default").
final class LegalRecordMigrationTests: XCTestCase {

    private func oldSave() throws -> PlayerState {
        var p = PlayerState(currentSystem: 128)
        p.legalRecord = [128: -40, 129: 25]
        p.localLegalRecord = [128: [130: -10]]
        p.systemReputation = nil
        // Round-trip through JSON without the new key, as an old build wrote it.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        json["systemReputation"] = nil
        return try JSONDecoder().decode(PlayerState.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testOldSaveDecodesAndMigratesOnce() throws {
        var p = try oldSave()
        XCTAssertNil(p.systemReputation, "an old save carries no per-system record")
        let game = makeGame([ownedSystemResource(id: 128, govt: 128), ownedSystemResource(id: 129, govt: 129),
                             ownedSystemResource(id: 130, govt: 128), ownedSystemResource(id: 131, govt: -1)])
        XCTAssertTrue(p.migrateLegalRecordIfNeeded(game: game))
        XCTAssertEqual(p.systemReputation, [128: -40, 129: 25, 130: -50])
        XCTAssertEqual(p.legalRecord, [128: -40, 129: 25], "the old record stays readable")
        XCTAssertFalse(p.migrateLegalRecordIfNeeded(game: game), "runs once")
    }

    func testNewSaveRoundTripsTheRecord() throws {
        var p = PlayerState(currentSystem: 128)
        p.systemReputation = [128: -7, 140: 31999]
        let back = try JSONDecoder().decode(PlayerState.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.systemReputation, [128: -7, 140: 31999])
        XCTAssertEqual(back.reputationHere, -7)
    }

    func testApplyReputationDeltaClamps() {
        var p = PlayerState(currentSystem: 128)
        p.systemReputation = [128: 31990]
        p.applyReputationDelta([128: 50, 129: -40000])
        XCTAssertEqual(p.systemReputation, [128: 32000, 129: -32000])
    }
}
