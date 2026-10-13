import XCTest
import NovaSwiftKit
import NovaSwiftEngine
@testable import NovaSwiftStory

/// The logic extracted from Apple SwiftUI views for the Godot port: gambling
/// (`RaceSession`), the bar's Hire Escort list (`EscortHire`), the in-flight
/// scan consequence (`ContrabandScan.scanPlayer`).
final class GameplayGapsTests: XCTestCase {

    // MARK: Gambling (GamblingView / FUN_0047dc50, EC-26)

    func testWinningBetPaysFourTimesTheWager() {
        var s = RaceSession(); var credits = 10_000
        let o = s.place(pick: .yellow, amount: 1000, credits: &credits, rand: { _ in 2 })
        XCTAssertEqual(o?.winner, .yellow)
        XCTAssertEqual(o?.payout, 4000)
        XCTAssertEqual(o?.net, 3000)
        XCTAssertEqual(credits, 10_000 - 1000 + 4000)
    }

    func testLosingBetCostsTheStake() {
        var s = RaceSession(); var credits = 10_000
        let o = s.place(pick: .blue, amount: 2500, credits: &credits, rand: { _ in 3 })
        XCTAssertEqual(o?.winner, .red)
        XCTAssertEqual(o?.payout, 0)
        XCTAssertEqual(credits, 7_500)
    }

    func testRepeatWinnerIsAGuaranteedLoss() {
        var s = RaceSession(); var credits = 100_000
        _ = s.place(pick: .green, amount: 1000, credits: &credits, rand: { _ in 0 })   // blue wins, remembered
        // The next roll repeats blue; the original re-rolls until it differs
        // from both the last winner and the player's pick — betting on blue loses.
        var rolls = [0, 0, 1, 0, 2].makeIterator()
        let o = s.place(pick: .blue, amount: 1000, credits: &credits, rand: { _ in rolls.next() ?? 3 })
        XCTAssertEqual(o?.payout, 0)
        XCTAssertNotEqual(o?.winner, .blue)
        XCTAssertEqual(s.bet.lastWinner, o?.winner.index)
    }

    func testBetRefusedWithoutCreditsAndNothingIsCharged() {
        var s = RaceSession(); var credits = 500
        XCTAssertNil(s.place(pick: .red, amount: 1000, credits: &credits, rand: { _ in 0 }))
        XCTAssertNil(s.place(pick: .red, amount: 0, credits: &credits, rand: { _ in 0 }))
        XCTAssertEqual(credits, 500)
        XCTAssertEqual(s.bet.lastWinner, -1, "a refused bet isn't a race")
        XCTAssertEqual(LandedServices.RaceBet.standardWager(credits: 500), 500)
        XCTAssertEqual(LandedServices.RaceBet.standardWager(credits: 50_000), 1000)
        XCTAssertEqual(LandedServices.RaceBet.maxPromptedWager(credits: 50_000), 10_000)
    }

    func testRaceColorArtIds() {
        XCTAssertEqual(RaceColor.blue.idlePictID, 8530)
        XCTAssertEqual(RaceColor.red.chosenPictID, 8543)
        XCTAssertEqual(RaceColor.green.winPictID, 8551)
        XCTAssertEqual(RaceColor.yellow.losePictID, 8562)
        XCTAssertEqual(RaceColor.yellow.clipName, "Race 3.mov")
        XCTAssertEqual(RaceColor(index: 3), .red)
    }

    // MARK: Contraband scan consequence

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) { Bytes.i16(&b, off, v) }

    private func scanGame(scanFine: Int, junkMask: Int = 0x8000, smug: Int = 5) -> NovaGame {
        var gb = [UInt8](repeating: 0, count: 192)
        put16(&gb, 6, scanFine); put16(&gb, 8, 100); put16(&gb, 10, smug); put16(&gb, 50, 0x8000)
        var jb = [UInt8](repeating: 0, count: 676)
        put16(&jb, 32, 400); put16(&jb, 36, junkMask)
        return makeGame([
            Resource(type: NovaType.govt, id: 128, name: "Patrol", data: Data(gb)),
            ownedSystemResource(id: 128, govt: 128),
            Resource(type: NovaType.junk, id: 130, name: "Illicit Goods", data: Data(jb)),
        ])
    }

    func testScanFinesJunkContrabandExactly() {
        var p = PlayerState(currentSystem: 128); p.credits = 20_000; p.cargo = [130: 7]
        let out = ContrabandScan.scanPlayer(state: &p, game: scanGame(scanFine: 3000), scannerGovt: 128)
        XCTAssertEqual(out.result?.contrabandCargo, [130])
        XCTAssertEqual(out.result?.fine, 3000)
        XCTAssertEqual(p.credits, 17_000)
        XCTAssertEqual(out.result?.smugglingPenalty, 5, "illegal junk costs SmugPenalty standing")
        XCTAssertTrue(out.messages.contains { $0.contains("fined you 3000cr") })
    }

    func testScanLegalJunkAndPoorPlayerNeverGoNegative() {
        var p = PlayerState(currentSystem: 128); p.credits = 20_000; p.cargo = [130: 7]
        let clean = scanGame(scanFine: 3000, junkMask: 0x0001)
        let none = ContrabandScan.scanPlayer(state: &p, game: clean, scannerGovt: 128)
        XCTAssertNil(none.result)
        XCTAssertEqual(p.credits, 20_000)
        XCTAssertTrue(none.messages.isEmpty)
        p.credits = 800
        let broke = ContrabandScan.scanPlayer(state: &p, game: scanGame(scanFine: 3000), scannerGovt: 128)
        XCTAssertEqual(broke.result?.fine, 800, "never fined more than the player has")
        XCTAssertEqual(p.credits, 0)
    }

    func testWarningOnlyGovernmentTakesNothing() {
        var p = PlayerState(currentSystem: 128); p.credits = 5000; p.cargo = [130: 1]
        let out = ContrabandScan.scanPlayer(state: &p, game: scanGame(scanFine: 0), scannerGovt: 128)
        XCTAssertEqual(out.result?.warningOnly, true)
        XCTAssertEqual(p.credits, 5000)
        XCTAssertTrue(out.messages.contains { $0.contains("let off with a warning") })
    }

    // MARK: Escort hire

    func testHireChargesTheTenthOfShipyardPriceAndJoinsTheWing() {
        var b = [UInt8](shipResource(id: 128, cargo: 10, freeMass: 20).data)
        Bytes.i16(&b, 46, 1); Bytes.i32(&b, 48, 10_000); Bytes.i16(&b, 906, 100)
        let game = makeGame([Resource(type: NovaType.ship, id: 128, name: "Shuttle", data: Data(b)),
                             landableSpob(id: 140, govt: 128, flags: 0)])
        let galaxy = Galaxy(game: game)
        let spob = game.spob(140)!
        let ship = game.ship(128)!
        var state = PlayerState(credits: 5_000)
        let price = EscortHire.price(ship, state: state, spob: spob, galaxy: galaxy)
        XCTAssertEqual(price, PilotEconomy.escortHirePrice(ship, scale: 1, stellarTech: spob.techLevel))
        XCTAssertGreaterThan(price, 0)
        XCTAssertTrue(EscortHire.hire(&state, ship, spob: spob, galaxy: galaxy))
        XCTAssertEqual(state.credits, 5_000 - price)
        XCTAssertEqual(state.escortWing.count, 1)
        XCTAssertEqual(state.escortWing.first?.origin, .hired)
        // Too poor, wing full: refused and not charged.
        var poor = PlayerState(credits: price - 1)
        XCTAssertFalse(EscortHire.hire(&poor, ship, spob: spob, galaxy: galaxy))
        XCTAssertEqual(poor.credits, price - 1)
        var full = PlayerState(credits: 1_000_000)
        for i in 0..<6 { full.registerEscort(shipType: 128, name: "E\(i)", origin: .hired, hireFee: 0, dailyFee: 0) }
        XCTAssertFalse(EscortHire.hire(&full, ship, spob: spob, galaxy: galaxy))
        XCTAssertEqual(EscortHire.categoryLabel(2), "Warship")
        XCTAssertEqual(EscortHire.categoryLabel(9), "Escort")
    }
}
