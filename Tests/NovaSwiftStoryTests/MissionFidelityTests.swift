import XCTest
import NovaSwiftKit
@testable import NovaSwiftStory

/// Execution-fidelity tests for the newer mïsn/crön semantics: the full PayVal
/// range, CompReward reputation reversals, C/E/H ship-change outfit handling,
/// randomised cargo, destroyed-stellar persistence, and iterative cron flags.
final class MissionFidelityTests: XCTestCase {

    // MARK: - Local resource builders

    /// A ship with preinstalled (default) outfits at @78/@86 and a cargo hold.
    private func shipWithDefaults(id: Int, cargo: Int, defaults: [(id: Int, count: Int)]) -> Resource {
        var b = [UInt8](repeating: 0, count: 1000)
        Bytes.i16(&b, 0, cargo)
        for (i, d) in defaults.prefix(4).enumerated() {
            Bytes.i16(&b, 78 + i * 2, d.id)
            Bytes.i16(&b, 86 + i * 2, d.count)
        }
        return Resource(type: NovaType.ship, id: id, name: "Ship \(id)", data: Data(b))
    }

    /// A minimal outfit whose @12 `Flags` field can be set (0x0008 = can't-sell,
    /// used by the engine as a persistence proxy for the `H` ship change).
    private func outfit(id: Int, flags: Int = 0) -> Resource {
        var b = [UInt8](repeating: 0, count: 1020)
        Bytes.i16(&b, 12, flags)
        return Resource(type: NovaType.outfit, id: id, name: "Outfit \(id)", data: Data(b))
    }

    /// A government with explicit class / ally class slots (@24 classes, @32
    /// allies), unused slots forced to -1 so they don't collapse to "class 0".
    private func govt(id: Int, classes: [Int] = [], allies: [Int] = []) -> Resource {
        var b = [UInt8](repeating: 0, count: 176)
        for i in 0..<4 { Bytes.i16(&b, 24 + i * 2, i < classes.count ? classes[i] : -1) }
        for i in 0..<4 { Bytes.i16(&b, 32 + i * 2, i < allies.count ? allies[i] : -1) }
        for i in 0..<4 { Bytes.i16(&b, 40 + i * 2, -1) }  // enemies: none
        return Resource(type: NovaType.govt, id: id, name: "Govt \(id)", data: Data(b))
    }

    /// A spöb whose OnDestroy (@582) / OnRegen (@837) NCB set strings are set.
    private func spobWithHooks(id: Int, onDestroy: String = "", onRegen: String = "") -> Resource {
        var b = [UInt8](repeating: 0, count: 1100)
        Bytes.cstr(&b, 582, onDestroy)
        Bytes.cstr(&b, 837, onRegen)
        return Resource(type: NovaType.spob, id: id, name: "Spob \(id)", data: Data(b))
    }

    /// A sÿst whose `visibility` (@150) NCB test string is set.
    private func systWithVisibility(id: Int, visibility: String) -> Resource {
        var b = [UInt8](repeating: 0, count: 500)
        Bytes.cstr(&b, 150, visibility)
        return Resource(type: NovaType.syst, id: id, name: "Sys \(id)", data: Data(b))
    }

    private func engine(_ resources: [Resource],
                        player: PlayerState = PlayerState(shipType: 128, currentSystem: 128),
                        seed: UInt64 = 1) -> (StoryEngine, LoggingGameServices) {
        let game = makeGame(resources + [shipResource(id: 128, cargo: 100)])
        let svc = LoggingGameServices()
        let eng = StoryEngine(game: game, player: player, services: svc, seed: seed)
        return (eng, svc)
    }

    /// Accept then immediately complete a mission (drives the completion reward
    /// path). Returns nothing; inspect `eng.player`.
    private func acceptAndComplete(_ eng: StoryEngine, _ id: Int) {
        XCTAssertTrue(eng.accept(id))
        eng.completeMission(id)
    }

    // MARK: - 1. PayVal full range

    func testPayValPositiveCreditsPaidOnceOnCompletion() {
        let (eng, _) = engine([MissionSpec(id: 200, pay: 500).resource()])
        eng.player.credits = 1000
        acceptAndComplete(eng, 200)
        XCTAssertEqual(eng.player.credits, 1500, "positive pay adds credits once, on completion")
    }

    func testPayValZeroAndMinusOneNoPay() {
        for code in [0, -1] {
            let (eng, _) = engine([MissionSpec(id: 200, pay: code).resource()])
            eng.player.credits = 1000
            acceptAndComplete(eng, 200)
            XCTAssertEqual(eng.player.credits, 1000, "pay \(code) means no pay")
        }
    }

    func testPayValUncodedNegativeIsLiteralFee() {
        // -500 is NOT one of the coded ranges → literal credit delta on completion.
        let (eng, _) = engine([MissionSpec(id: 200, pay: -500).resource()])
        eng.player.credits = 1000
        acceptAndComplete(eng, 200)
        XCTAssertEqual(eng.player.credits, 500)
    }

    func testPayValCleanRecordWithGovt() {
        let (eng, _) = engine([MissionSpec(id: 200, pay: -10128).resource()])
        eng.player.legalRecord = [128: -50, 200: -30]
        acceptAndComplete(eng, 200)
        XCTAssertNil(eng.player.legalRecord[128], "record with govt 128 cleaned")
        XCTAssertEqual(eng.player.legalRecord[200], -30, "other govts untouched")
    }

    func testPayValCleanRecordWithGovtAndAllies() {
        // Govt 128 is allied with class 5; govt 200 is in class 5 (an ally),
        // govt 201 is in class 9 (not an ally).
        let resources = [
            MissionSpec(id: 300, pay: -20128).resource(),
            govt(id: 128, classes: [1], allies: [5]),
            govt(id: 200, classes: [5]),
            govt(id: 201, classes: [9]),
        ]
        let (eng, _) = engine(resources)
        eng.player.legalRecord = [128: -50, 200: -40, 201: -30]
        acceptAndComplete(eng, 300)
        XCTAssertNil(eng.player.legalRecord[128], "named govt cleaned")
        XCTAssertNil(eng.player.legalRecord[200], "ally (shared ally class) cleaned")
        XCTAssertEqual(eng.player.legalRecord[201], -30, "non-ally untouched")
    }

    func testPayValCleanRecordWithGovtAndClassmates() {
        // Govt 128 is in class 7; govt 200 shares class 7 (classmate), 201 doesn't.
        let resources = [
            MissionSpec(id: 300, pay: -30128).resource(),
            govt(id: 128, classes: [7]),
            govt(id: 200, classes: [7]),
            govt(id: 201, classes: [3]),
        ]
        let (eng, _) = engine(resources)
        eng.player.legalRecord = [128: -50, 200: -40, 201: -30]
        acceptAndComplete(eng, 300)
        XCTAssertNil(eng.player.legalRecord[128])
        XCTAssertNil(eng.player.legalRecord[200], "classmate cleaned")
        XCTAssertEqual(eng.player.legalRecord[201], -30, "non-classmate untouched")
    }

    func testPayValPercentOfCash() {
        // -40010 = take 10% of the player's cash, on completion.
        let (eng, _) = engine([MissionSpec(id: 200, pay: -40010).resource()])
        eng.player.credits = 1000
        acceptAndComplete(eng, 200)
        XCTAssertEqual(eng.player.credits, 900)
    }

    func testPayValUpFrontFeeChargedAtAcceptNotAgainAtCompletion() {
        // -50100 = charge (100) credits at mission START, and not again on success.
        let (eng, _) = engine([MissionSpec(id: 200, pay: -50100).resource()])
        eng.player.credits = 1000
        XCTAssertTrue(eng.accept(200))
        XCTAssertEqual(eng.player.credits, 900, "fee deducted up-front, at accept")
        eng.completeMission(200)
        XCTAssertEqual(eng.player.credits, 900, "fee NOT charged again on completion")
    }

    func testPayValUpFrontFeeZeroBoundary() {
        // -50000 = fee of 0.
        let (eng, _) = engine([MissionSpec(id: 200, pay: -50000).resource()])
        eng.player.credits = 1000
        XCTAssertTrue(eng.accept(200))
        XCTAssertEqual(eng.player.credits, 1000)
    }

    // MARK: - 2. CompReward reputation reversals

    func testCompRewardFullOnSuccess() {
        let (eng, _) = engine([MissionSpec(id: 200, compRewardGovt: 128, compLegalReward: 10).resource()])
        acceptAndComplete(eng, 200)
        XCTAssertEqual(eng.player.legalRecord[128], 10)
    }

    func testCompRewardHalfPenaltyOnFailure() {
        let (eng, _) = engine([MissionSpec(id: 200, compRewardGovt: 128, compLegalReward: 10).resource()])
        XCTAssertTrue(eng.accept(200))
        eng.failMission(200)
        XCTAssertEqual(eng.player.legalRecord[128], -5, "fail decreases record by 1/2 the reward")
    }

    func testCompRewardFiveXPenaltyOnAbortWhenFlagSet() {
        let m = MissionSpec(id: 200, compRewardGovt: 128, compLegalReward: 10, flags1: 0x0040).resource()
        let (eng, _) = engine([m])
        XCTAssertTrue(eng.accept(200))
        eng.abortMission(200)
        XCTAssertEqual(eng.player.legalRecord[128], -50, "abort penalty flag → -5x the reward")
    }

    func testCompRewardNoAbortPenaltyWithoutFlag() {
        let m = MissionSpec(id: 200, compRewardGovt: 128, compLegalReward: 10).resource()
        let (eng, _) = engine([m])
        XCTAssertTrue(eng.accept(200))
        eng.abortMission(200)
        XCTAssertNil(eng.player.legalRecord[128], "no abort-penalty flag → no reputation hit")
    }

    // MARK: - 3. C / E / H ship-change outfit semantics

    private func shipChangeGame() -> StoryEngine {
        let resources = [
            shipWithDefaults(id: 300, cargo: 100, defaults: [(id: 500, count: 1)]),
            outfit(id: 400),                 // ordinary (non-persistent)
            outfit(id: 500),                 // the new hull's default
            outfit(id: 600, flags: 0x0008),  // can't-sell → treated as persistent
        ]
        let (eng, _) = engine(resources)
        return eng
    }

    func testChangeShipC_KeepsOutfitsAddsNoDefaults() {
        let eng = shipChangeGame()
        eng.player.outfits = [400: 1]
        eng.apply(set: "C300")
        XCTAssertEqual(eng.player.shipType, 300)
        XCTAssertEqual(eng.player.outfits[400], 1, "kept existing outfit")
        XCTAssertNil(eng.player.outfits[500], "C adds none of the hull's defaults")
    }

    func testChangeShipE_KeepsOutfitsAddsDefaults() {
        let eng = shipChangeGame()
        eng.player.outfits = [400: 1]
        eng.apply(set: "E300")
        XCTAssertEqual(eng.player.shipType, 300)
        XCTAssertEqual(eng.player.outfits[400], 1, "kept existing outfit")
        XCTAssertEqual(eng.player.outfits[500], 1, "E adds the hull's default outfits")
    }

    func testChangeShipH_DropsNonPersistentKeepsPersistentAddsDefaults() {
        let eng = shipChangeGame()
        eng.player.outfits = [400: 1, 600: 1]
        eng.apply(set: "H300")
        XCTAssertEqual(eng.player.shipType, 300)
        XCTAssertNil(eng.player.outfits[400], "H drops non-persistent outfit")
        XCTAssertEqual(eng.player.outfits[600], 1, "H keeps persistent (can't-sell) outfit")
        XCTAssertEqual(eng.player.outfits[500], 1, "H adds the hull's default outfits")
    }

    // MARK: - 4. Randomised cargo (CargoQty <= -2, CargoType == 1000)

    func testCargoQtyRandomIsWithinFiftyPercentBandAndDeterministic() {
        // Two independent engines, same seed → identical resolved quantity, and
        // the pickup/release move exactly that amount.
        func run() -> (qty: Int, afterAccept: Int, afterAbort: Int) {
            let spec = MissionSpec(id: 200, cargoType: 0, cargoQty: -10, cargoPickup: 0).resource()
            let (eng, _) = engine([spec], seed: 42)
            XCTAssertTrue(eng.accept(200))
            let resolved = eng.player.activeMission(200)!.resolvedCargoQty!
            let afterAccept = eng.player.cargo[0] ?? 0
            eng.abortMission(200)
            return (resolved, afterAccept, eng.player.cargo[0] ?? 0)
        }
        let a = run(), b = run()
        XCTAssertEqual(a.qty, b.qty, "same seed → same resolved quantity")
        XCTAssertTrue((5...15).contains(a.qty), "abs(10) ± 50% is in [5,15], got \(a.qty)")
        XCTAssertEqual(a.afterAccept, a.qty, "pickup adds the resolved quantity")
        XCTAssertEqual(a.afterAbort, 0, "release removes exactly the resolved quantity")
    }

    func testCargoTypeRandomStandardIsZeroToFive() {
        let spec = MissionSpec(id: 200, cargoType: 1000, cargoQty: 4, cargoPickup: 0).resource()
        let (eng, _) = engine([spec], seed: 7)
        XCTAssertTrue(eng.accept(200))
        let type = eng.player.activeMission(200)!.resolvedCargoType!
        XCTAssertTrue((0...5).contains(type), "CargoType 1000 resolves to a standard type 0–5, got \(type)")
        XCTAssertEqual(eng.player.cargo[type], 4, "cargo added under the resolved type")
    }

    // MARK: - 5. destroyedStellars persistence

    func testDestroyStellarMarksAndRegeneratesPlayerState() {
        let (eng, _) = engine([])
        eng.apply(set: "Y128")
        XCTAssertTrue(eng.player.isStellarDestroyed(128))
        eng.apply(set: "U128")
        XCTAssertFalse(eng.player.isStellarDestroyed(128))
    }

    func testDestroyedStellarsSurvivesCodableRoundTrip() throws {
        let (eng, _) = engine([])
        eng.apply(set: "Y128 Y200")
        let data = try JSONEncoder().encode(eng.player)
        let decoded = try JSONDecoder().decode(PlayerState.self, from: data)
        XCTAssertTrue(decoded.isStellarDestroyed(128))
        XCTAssertTrue(decoded.isStellarDestroyed(200))
    }

    func testLegacyPlayerWithoutDestroyedStellarsDecodes() throws {
        // Simulate an older save: no destroyedStellars key at all.
        var player = PlayerState(shipType: 128, currentSystem: 128)
        player.destroyedStellars = nil
        let data = try JSONEncoder().encode(player)
        let decoded = try JSONDecoder().decode(PlayerState.self, from: data)
        XCTAssertFalse(decoded.isStellarDestroyed(1), "missing field decodes as 'none destroyed'")
    }

    // MARK: - 6. Cron iterative re-evaluation flags

    /// A cron that grants outfit 500 on start; grants accumulate, so the count
    /// equals the number of times OnStart ran.
    private func grantCron(id: Int, flags: Int, enableOn: String, onStart: String = "G500") -> Resource {
        CronSpec(id: id, random: 100, duration: 0, flags: flags, enableOn: enableOn, onStart: onStart).resource()
    }

    func testCronNonLoopingRunsOnStartOnce() {
        let (eng, _) = engine([grantCron(id: 128, flags: 0, enableOn: "")])
        eng.advanceOneDay()
        XCTAssertEqual(eng.player.outfits[500], 1, "a normal cron runs OnStart exactly once")
    }

    func testCronLoopStartHitsCapWhenEnableStaysTrue() {
        // loopStartUntilFalse (0x0001) with an always-true EnableOn re-runs OnStart
        // up to the hard cap (1000).
        let (eng, _) = engine([grantCron(id: 128, flags: 0x0001, enableOn: "")])
        eng.advanceOneDay()
        XCTAssertEqual(eng.player.outfits[500], 1000, "iterative cron re-runs OnStart up to the cap")
    }

    func testCronLoopStartTerminatesWhenOnStartFalsifiesEnable() {
        // OnStart grants 500 and sets b999; EnableOn = !b999, so after the first
        // run the loop condition is false and it stops (count 1, not 1000).
        let (eng, _) = engine([grantCron(id: 128, flags: 0x0001, enableOn: "!b999", onStart: "G500 b999")])
        eng.advanceOneDay()
        XCTAssertEqual(eng.player.outfits[500], 1, "iterative loop stops once EnableOn goes false")
        XCTAssertTrue(eng.player.isBitSet(999))
    }

    // MARK: - 7. Stellar OnDestroy / OnRegen hooks

    func testDestroyStellarFiresSpobOnDestroyBits() {
        let (eng, _) = engine([spobWithHooks(id: 400, onDestroy: "b555")])
        eng.apply(set: "Y400")
        XCTAssertTrue(eng.player.isStellarDestroyed(400))
        XCTAssertTrue(eng.player.isBitSet(555), "spöb OnDestroy control bits fire on a Y op")
    }

    func testRegenerateStellarFiresSpobOnRegenBits() {
        let (eng, _) = engine([spobWithHooks(id: 400, onDestroy: "b555", onRegen: "b666 !b555")])
        eng.apply(set: "Y400")
        XCTAssertTrue(eng.player.isBitSet(555))
        eng.apply(set: "U400")
        XCTAssertFalse(eng.player.isStellarDestroyed(400))
        XCTAssertTrue(eng.player.isBitSet(666), "spöb OnRegen control bits fire on a U op")
        XCTAssertFalse(eng.player.isBitSet(555), "OnRegen may clear what OnDestroy set")
    }

    // MARK: - 8. System visibility

    func testSystemVisibilityGatedByControlBit() {
        let (eng, _) = engine([systWithVisibility(id: 900, visibility: "b500")])
        XCTAssertFalse(eng.isSystemVisible(900), "hidden while gate bit is clear")
        XCTAssertEqual(eng.hiddenSystemIDs(), [900])

        eng.apply(set: "b500")
        XCTAssertTrue(eng.isSystemVisible(900), "visible once gate bit is set")
        XCTAssertTrue(eng.hiddenSystemIDs().isEmpty)
    }

    func testSystemWithoutVisibilityTestIsAlwaysVisible() {
        let (eng, _) = engine([systWithVisibility(id: 900, visibility: "")])
        XCTAssertTrue(eng.isSystemVisible(900), "blank visibility test → always visible")
        XCTAssertTrue(eng.hiddenSystemIDs().isEmpty)
    }

    func testUnknownSystemIsVisible() {
        let (eng, _) = engine([])
        XCTAssertTrue(eng.isSystemVisible(12345), "unknown system id is not hidden")
    }
}
