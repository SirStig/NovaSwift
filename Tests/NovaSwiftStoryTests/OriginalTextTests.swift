import XCTest
import NovaSwiftKit
@testable import NovaSwiftStory

/// Batch 7 text: legal-status levels (UI-14), dates, status-bar and landing
/// lines (UI-08, UI-11) built from the string resources, never from English.
final class OriginalTextTests: XCTestCase {

    private func strList(_ id: Int, _ items: [String]) -> Resource {
        var b: [UInt8] = [UInt8(items.count >> 8), UInt8(items.count & 0xff)]
        for s in items { let bytes = Array(s.utf8); b.append(UInt8(bytes.count)); b += bytes }
        return Resource(type: NovaType.strList, id: id, name: "STR#\(id)", data: Data(b))
    }

    /// STR# 2002 with every entry "#n", except the ones a test reads as text.
    private func misc(_ overrides: [Int: String]) -> Resource {
        strList(2002, (1...400).map { overrides[$0] ?? "#\($0)" })
    }

    private func dates() -> Resource {
        let full = ["January", "February", "March", "April", "May", "June", "July",
                    "August", "September", "October", "November", "December"]
        let short = ["Jan.", "Feb.", "Mar.", "Apr.", "May", "June", "July",
                     "Aug.", "Sept.", "Oct.", "Nov.", "Dec."]
        let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return strList(137, full + short + ["st", "nd", "rd", "th"] + words)
    }

    private func player(_ date: GameDate, suffix: String = "") -> PlayerState {
        var p = PlayerState(currentSystem: 128, date: date)
        p.datePrefix = ""
        p.dateSuffix = suffix
        return p
    }

    // MARK: UI-14

    func testLegalLevelsScaleByCrimeTolerance() {
        // CrimeTol 10: −50 is below −4T → Offender (4); −200 below −16T → Criminal (5).
        XCTAssertEqual(LegalStatus.level(reputation: -50, crimeTolerance: 10), 4)
        XCTAssertEqual(LegalStatus.level(reputation: -200, crimeTolerance: 10), 5)
        XCTAssertEqual(LegalStatus.level(reputation: 0, crimeTolerance: 10), 1, "No Record")
        XCTAssertEqual(LegalStatus.level(reputation: -10, crimeTolerance: 10), 2, "−T is still No Convictions")
        XCTAssertEqual(LegalStatus.level(reputation: -11, crimeTolerance: 10), 3)
        XCTAssertEqual(LegalStatus.level(reputation: 40, crimeTolerance: 10), 10, "4T is still Citizen")
        XCTAssertEqual(LegalStatus.level(reputation: 41, crimeTolerance: 10), 11)
        XCTAssertEqual(LegalStatus.level(reputation: 10241, crimeTolerance: 10), 15)
        XCTAssertEqual(LegalStatus.level(reputation: -40961, crimeTolerance: 10), 9)
    }

    func testLegalLabelReadsStr134AndNA() {
        let labels = ["No Record", "No Record", "No Convictions", "Minor Offender", "Offender"]
        let game = makeGame([strList(134, labels), misc([396: "N/A"])])
        XCTAssertEqual(LegalStatus.label(level: 4, game: game), "Offender", "entry level + 1")
        XCTAssertEqual(LegalStatus.label(level: 1, game: game), "No Record")
        XCTAssertEqual(LegalStatus.label(level: 0, game: game), "N/A")
    }

    // MARK: Dates and counts

    func testShortAndLongDatesUseStr137AndTheCharAffixes() {
        let text = OriginalText(game: makeGame([dates()]))
        XCTAssertEqual(text.date(GameDate(day: 1, month: 9, year: 1177), suffix: " NC"), "Sept. 1st, 1177 NC")
        XCTAssertEqual(text.date(GameDate(day: 12, month: 6, year: 1178)), "June 12th, 1178")
        XCTAssertEqual(text.date(GameDate(day: 23, month: 1, year: 1177), long: true), "January 23rd, 1177")
        XCTAssertEqual(text.countWord(3), "three")
        XCTAssertEqual(OriginalText.grouped(1_234_567), "1,234,567")
        XCTAssertEqual(OriginalText.grouped(999), "999")
    }

    // MARK: UI-11

    func testArrivalLineWithoutBuoy() {
        let game = makeGame([dates(), misc([45: "Arriving in the", 48: "system on",
                                            49: "No stellar objects present."])])
        let line = OriginalText(game: game).arrival(
            system: "Sol", player: player(GameDate(day: 9, month: 10, year: 1177), suffix: " NC"),
            hasStellars: false) { _ in 2 }
        XCTAssertEqual(line, "Arriving in the Sol system on October 9th, 1177 NC. No stellar objects present.")
    }

    /// 0x0044f3d0 appends the bay fighters a jump left behind.
    func testArrivalLineCountsAbandonedFighters() {
        let game = makeGame([dates(), misc([45: "Arriving in the", 48: "system on",
                                            165: "fighters abandoned"])])
        let line = OriginalText(game: game).arrival(
            system: "Sol", player: player(GameDate(day: 9, month: 10, year: 1177)),
            hasStellars: true, abandonedFighters: 2) { _ in 2 }
        XCTAssertEqual(line, "Arriving in the Sol system on October 9th, 1177.  (Two fighters abandoned)")
    }

    func testLaunchLine() {
        let game = makeGame([dates(), misc([57: "Taking off from", 60: "on"])])
        XCTAssertEqual(OriginalText(game: game).launch(
            stellar: "Earth", player: player(GameDate(day: 2, month: 3, year: 1177))) { _ in 2 },
                       "Taking off from Earth on Mar. 2nd, 1177.")
    }

    // MARK: UI-08

    func testLandingRequestAndClearanceComposeTheirEntries() {
        let game = makeGame([misc([78: "traffic control reads you", 79: "Landing request received",
                                   80: "Begin initial approach.", 97: "Cleared to land",
                                   100: "Commence final approach.", 101: "Welcome to",
                                   104: "[Landing fee is", 105: ".]", 33: "credits",
                                   83: "Landing request denied."])])
        let text = OriginalText(game: game)
        // rand(3) = 0 → "<name> traffic control reads you"; rand(2) = 0 → ", <pilot>".
        XCTAssertEqual(text.landingRequest(body: .planet, stellar: "Earth", pilot: "Kay") { _ in 0 },
                       "Earth traffic control reads you, Kay. Begin initial approach.")
        XCTAssertEqual(text.landingRequest(body: .planet, stellar: "Earth", pilot: "Kay") { _ in 1 },
                       "Landing request received. Begin initial approach.")
        XCTAssertEqual(text.landingClearance(body: .planet, stellar: "Earth", pilot: "Kay", fee: 50) { _ in 0 },
                       "Cleared to land, Kay. Commence final approach. [Landing fee is 50 credits.]")
        XCTAssertEqual(text.landingDenied(body: .planet), "Landing request denied.")
    }
}
