import XCTest
import NovaSwiftKit
@testable import NovaSwiftStory

/// UI-11 closing pass (2026-10-13): the in-flight status lines are the original's
/// STR# 2002 / 137 sentences (contraband scan 0x00401800, plunder 0x00482940,
/// assistance 0x00408150, nonlethal bomb), and the new-pilot travel hint chain
/// (STR# 2002 #22-31, 0x00451f8f) follows the original's state machine.
final class FlightStatusTextTests: XCTestCase {

    private func strList(_ id: Int, _ items: [String]) -> Resource {
        var b: [UInt8] = [UInt8(items.count >> 8), UInt8(items.count & 0xff)]
        for s in items { let bytes = Array(s.utf8); b.append(UInt8(bytes.count)); b += bytes }
        return Resource(type: NovaType.strList, id: id, name: "STR#\(id)", data: Data(b))
    }

    /// STR# 2002 with the entries these lines read, every other one "#n".
    private func game(extra: [Int: String] = [:]) -> NovaGame {
        var strings: [Int: String] = [
            1: "ton", 2: "tons", 6: "No fit", 4: "Filled", 5: "Partial",
            22: "Dock at", 23: "Land on", 24: "and look around. Hit '", 25: "' to land.",
            26: "Now hyperspace. Hit '", 27: "' for the map, then '", 28: "' to jump.",
            30: "Beyond range", 31: "Nothing out here",
            32: "credit", 33: "credits", 39: "Your", 40: "has exploded!", 41: "have exploded!",
            106: "You retrieved ", 108: "from this ship.", 114: "Cargo no room", 115: "You salvaged",
            116: "You stole all the", 117: "No ammo room",
            284: "Mission failed.", 286: "Scanned - mission failed.",
            336: "none", 364: "Free cargo space", 365: "in your ship", 366: "in your fleet",
            362: "Current cargo", 369: "free in your ship",
            375: "your posession of", 376: "your attempt to smuggle", 377: "illegal cargo",
            378: "through this system", 379: "has been detected", 380: "You have been fined",
            384: "Repairs complete", 391: "of", 392: "and", 393: "a", 394: "an",
            268: "fleet empty", 269: "ship empty",
        ]
        for (k, v) in extra { strings[k] = v }
        let misc = (1...400).map { strings[$0] ?? "#\($0)" }
        let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        let full = ["January", "February", "March", "April", "May", "June", "July",
                    "August", "September", "October", "November", "December"]
        return makeGame([strList(2002, misc), strList(137, full + full + ["st", "nd", "rd", "th"] + words)])
    }

    // MARK: Contraband scan (0x00401800)

    func testScanSentenceForMissionCargoJunkAndOutfits() {
        let text = OriginalText(game: game())
        XCTAssertEqual(
            text.scanDetected(scanner: "Auroran Cruiser", pilot: "Ann", finding: .missionCargo, fine: 0),
            "Auroran Cruiser:  Ann, your attempt to smuggle illegal cargo through this system has been detected.")
        XCTAssertEqual(
            text.scanDetected(scanner: "Capt. Vex", pilot: "Ann", finding: .junk("luxury goods"), fine: 1),
            "Capt. Vex:  Ann, your attempt to smuggle luxury goods through this system has been detected. You have been fined 1 credit.")
        // One outfit takes "a/an" by its first letter; several take the plural.
        XCTAssertEqual(
            text.scanDetected(scanner: "Cruiser", pilot: "Ann", finding: .outfit(singular: "illegal gun", plural: "illegal guns", count: 1), fine: 1500),
            "Cruiser:  Ann, your posession of an illegal gun has been detected. You have been fined 1,500 credits.")
        XCTAssertEqual(
            text.scanDetected(scanner: "Cruiser", pilot: "Ann", finding: .outfit(singular: "mine", plural: "mines", count: 3), fine: 0),
            "Cruiser:  Ann, your posession of mines has been detected.")
        XCTAssertEqual(text.missionFailedLine, "Mission failed.")
    }

    func testScanLinesOrderTheFailureThenTheDetection() {
        let g = game()
        let player = PlayerState(currentSystem: 128)
        let result = ContrabandResult(contrabandOutfits: [], contrabandCargo: [], smugglingMissions: [3],
                                      fine: 0, warningOnly: true, smugglingPenalty: 0)
        let lines = ContrabandScan.scanLines(failed: true, result: result, state: player, game: g, scanner: "Cruiser")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.first, "Scanned - mission failed.")
        XCTAssertTrue(lines.last?.hasPrefix("Cruiser:  ") == true)
        XCTAssertTrue(lines.last?.hasSuffix("has been detected.") == true)
        XCTAssertTrue(ContrabandScan.scanLines(failed: false, result: nil, state: player, game: g, scanner: "Cruiser").isEmpty)
    }

    func testAssistanceRepairsLine() {
        XCTAssertEqual(OriginalText(game: game()).repairsComplete(shipClass: "Shuttle", pilot: "Ann"),
                       "Shuttle:  Repairs complete, Ann.")
    }

    // MARK: Plunder (0x00482940)

    func testPlunderLinesUseTheOriginalSentences() {
        let text = OriginalText(game: game())
        XCTAssertEqual(text.plunderedCredits, "You stole all the credits from this ship.")
        XCTAssertEqual(text.plunderedCargo(tons: 12, name: "Food"), "You salvaged 12 tons of Food from this ship.")
        XCTAssertEqual(text.plunderedCargo(tons: 1, name: "Food"), "You salvaged 1 ton of Food from this ship.")
        XCTAssertEqual(text.plunderCargoNoRoom, "Cargo no room")
        XCTAssertEqual(text.plunderedAmmo(rounds: 2, singular: "rocket", plural: "rockets"),
                       "You salvaged two rockets from this ship.")
        XCTAssertEqual(text.plunderedAmmo(rounds: 1, singular: "rocket", plural: "rockets"),
                       "You salvaged one rocket from this ship.")
        XCTAssertEqual(text.plunderedAmmo(rounds: 0, singular: "rocket", plural: "rockets"), "No ammo room")
        XCTAssertEqual(text.plunderedEnergy(tookAny: false, tankFull: false), "No fit")
        XCTAssertEqual(text.plunderedEnergy(tookAny: true, tankFull: false), "Partial")
        XCTAssertEqual(text.plunderedEnergy(tookAny: true, tankFull: true), "Filled")
    }

    func testRetrievedOutfitCountWords() {
        let text = OriginalText(game: game())
        XCTAssertEqual(text.retrievedOutfit(count: 1, singular: "laser", plural: "lasers"),
                       "You retrieved a laser from this ship.")
        XCTAssertEqual(text.retrievedOutfit(count: 1, singular: "ion cannon", plural: "ion cannons"),
                       "You retrieved an ion cannon from this ship.")
        XCTAssertEqual(text.retrievedOutfit(count: 4, singular: "laser", plural: "lasers"),
                       "You retrieved four lasers from this ship.")
        XCTAssertEqual(text.retrievedOutfit(count: 12, singular: "laser", plural: "lasers"),
                       "You retrieved 12 lasers from this ship.")
    }

    func testBombExplodedLine() {
        let text = OriginalText(game: game())
        XCTAssertEqual(text.bombExploded(count: 1, singular: "mine", plural: "mines"), "Your mine has exploded!")
        XCTAssertEqual(text.bombExploded(count: 2, singular: "mine", plural: "mines"), "Your mines have exploded!")
    }

    func testLocalizedCountWordAndArticle() {
        let text = OriginalText(game: game())
        XCTAssertEqual(text.localizedCountWord(1), "one")
        XCTAssertEqual(text.localizedCountWord(10), "ten")
        XCTAssertEqual(text.localizedCountWord(11), "11")
        XCTAssertEqual(text.article(before: "Apple"), "an")
        XCTAssertEqual(text.article(before: "banana"), "a")
    }

    // MARK: Player Info cargo (0x0049c050)

    func testCargoPageIsOneSentenceWithCountWords() {
        var player = PlayerState(currentSystem: 128)
        player.cargo = [0: 1, 1: 3]    // commodities 0 and 1
        let pages = PlayerInfoPages(game: game(), player: player)
        let text = pages.cargo(shipCapacity: 30, fleetCapacity: 30)
        // Header, blank line, "One ton of …, three tons of …", footer.
        XCTAssertTrue(text.hasPrefix("Current cargo in your ship:\n\n"), text)
        XCTAssertTrue(text.contains("One ton of "), text)
        XCTAssertTrue(text.contains(" and three tons of "), text)
        XCTAssertTrue(text.contains(".\n\nFree cargo space: 26 tons"), text)
    }

    func testCargoPageOfAFleetNamesTheShipsShareToo() {
        var player = PlayerState(currentSystem: 128)
        player.cargo = [0: 5]
        let pages = PlayerInfoPages(game: game(), player: player)
        let text = pages.cargo(shipCapacity: 5, fleetCapacity: 20)
        XCTAssertTrue(text.hasPrefix("Current cargo in your fleet:\n\n"), text)
        XCTAssertTrue(text.contains("Free cargo space in your fleet:  15 tons(none free in your ship)"), text)
    }

    func testEmptyCargoPageText() {
        let pages = PlayerInfoPages(game: game(), player: PlayerState(currentSystem: 128))
        XCTAssertEqual(pages.cargo(shipCapacity: 10, fleetCapacity: 10), "ship empty")
        XCTAssertEqual(pages.cargo(shipCapacity: 10, fleetCapacity: 40), "fleet empty")
    }

    // MARK: Travel hint chain (0x00451f8f)

    private let keys = TravelHintTracker.Keys(land: "L", map: "M", jump: "J")
    private let earth = TravelHintTracker.Stellar(name: "Earth", isStation: false)
    private let dock = TravelHintTracker.Stellar(name: "Dock", isStation: true)

    func testNewPilotWelcomeNamesTheStellarAndTheLandKey() {
        let t = TravelHintTracker(); t.beginNewPilot()
        let text = OriginalText(game: game())
        XCTAssertEqual(t.state, -3)
        let hint = t.evaluate(distanceSquared: 0, disabled: false, nearest: earth, keys: keys, text: text)
        XCTAssertEqual(hint?.text, "Land on Earth and look around. Hit 'L' to land.")
        XCTAssertEqual(hint?.rawCalls, 0x200)
        XCTAssertEqual(hint?.beep, 5)
        XCTAssertEqual(t.state, -2)
        // A station takes the docking lead.
        let t2 = TravelHintTracker(); t2.beginNewPilot()
        XCTAssertEqual(t2.evaluate(distanceSquared: 0, disabled: false, nearest: dock, keys: keys, text: text)?.text,
                       "Dock at Dock and look around. Hit 'L' to land.")
    }

    func testLaunchIsSilentBelowStateThreeAndAlwaysRearmsTheHyperspaceHint() {
        let t = TravelHintTracker(); t.beginNewPilot()
        let text = OriginalText(game: game())
        _ = t.evaluate(distanceSquared: 0, disabled: false, nearest: earth, keys: keys, text: text)   // -3 -> -2
        XCTAssertFalse(t.launched(), "no launch line for a fresh pilot")
        XCTAssertEqual(t.state, -1)
        let hint = t.evaluate(distanceSquared: 0, disabled: false, nearest: earth, keys: keys, text: text)
        XCTAssertEqual(hint?.text, "Now hyperspace. Hit 'M' for the map, then 'J' to jump.")
        XCTAssertEqual(t.state, 0)
        // The quirk: every further launch before the first jump does it again.
        XCTAssertFalse(t.launched())
        XCTAssertEqual(t.state, -1)
        XCTAssertNotNil(t.evaluate(distanceSquared: 0, disabled: false, nearest: earth, keys: keys, text: text))
        // A jump (or a loaded pilot) latches it: the launch line shows again.
        t.latch()
        XCTAssertTrue(t.launched())
        XCTAssertEqual(t.state, TravelHintTracker.latched)
        XCTAssertNil(t.evaluate(distanceSquared: 0, disabled: false, nearest: earth, keys: keys, text: text))
    }

    func testRangeHintsFireOutsideTheRadiiAndSkipADisabledShip() {
        let t = TravelHintTracker(); t.beginNewPilot()
        let text = OriginalText(game: game())
        _ = t.evaluate(distanceSquared: 0, disabled: false, nearest: earth, keys: keys, text: text)   // -2
        // Inside 2,000,000 nothing; outside, #30 and state 1 — unless disabled.
        XCTAssertNil(t.evaluate(distanceSquared: 1_900_000, disabled: false, nearest: earth, keys: keys, text: text))
        XCTAssertNil(t.evaluate(distanceSquared: 3_000_000, disabled: true, nearest: earth, keys: keys, text: text))
        XCTAssertEqual(t.state, -2)
        XCTAssertEqual(t.evaluate(distanceSquared: 3_000_000, disabled: false, nearest: earth, keys: keys, text: text)?.text,
                       "Beyond range")
        XCTAssertEqual(t.state, 1)
        // State 1 waits for 10,000,000; then #31 ends the chain.
        XCTAssertNil(t.evaluate(distanceSquared: 9_000_000, disabled: false, nearest: earth, keys: keys, text: text))
        XCTAssertEqual(t.evaluate(distanceSquared: 11_000_000, disabled: false, nearest: earth, keys: keys, text: text)?.text,
                       "Nothing out here")
        XCTAssertEqual(t.state, 2)
        XCTAssertFalse(t.isActive)
        XCTAssertNil(t.evaluate(distanceSquared: 11_000_000, disabled: false, nearest: earth, keys: keys, text: text))
    }

    func testNoStellarMeansNoWelcomeButTheStateStillAdvances() {
        let t = TravelHintTracker(); t.beginNewPilot()
        let text = OriginalText(game: game())
        XCTAssertNil(t.evaluate(distanceSquared: 0, disabled: false, nearest: nil, keys: keys, text: text))
        XCTAssertEqual(t.state, -2)
    }

    func testTheCheckRunsOncePerSixtyRawCalls() {
        let t = TravelHintTracker(); t.beginNewPilot()
        let text = OriginalText(game: game())
        XCTAssertNil(t.tick(rawCalls: 30, distanceSquared: 0, disabled: false, nearest: earth, keys: keys, text: text))
        XCTAssertEqual(t.state, -3)
        XCTAssertNotNil(t.tick(rawCalls: 31, distanceSquared: 0, disabled: false, nearest: earth, keys: keys, text: text))
        XCTAssertEqual(t.state, -2)
        // The next evaluation only comes after another 60.
        XCTAssertNil(t.tick(rawCalls: 20, distanceSquared: 3_000_000, disabled: false, nearest: earth, keys: keys, text: text))
        XCTAssertEqual(t.state, -2)
        XCTAssertNotNil(t.tick(rawCalls: 50, distanceSquared: 3_000_000, disabled: false, nearest: earth, keys: keys, text: text))
        XCTAssertEqual(t.state, 1)
    }

    func testLoadedPilotsStartLatchedAndNeverSeeHints() {
        let t = TravelHintTracker()
        XCTAssertEqual(t.state, TravelHintTracker.latched)
        XCTAssertNil(t.tick(rawCalls: 600, distanceSquared: 5_000_000, disabled: false, nearest: earth, keys: keys,
                            text: OriginalText(game: game())))
    }
}
