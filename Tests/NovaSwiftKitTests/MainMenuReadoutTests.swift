import XCTest
@testable import NovaSwiftKit

/// Pins the main-menu pilot readout of `FUN_004873b0` and its helpers.
final class MainMenuReadoutTests: XCTestCase {

    func testLayoutOffsets() {
        let l = MainMenuReadout.lines
        XCTAssertEqual(l.first, .init(kind: .label(251), dx: -190, baselineDY: 250))
        XCTAssertEqual(l[1], .init(kind: .value(.pilotName), dx: -185, baselineDY: 262))
        XCTAssertTrue(l.contains(.init(kind: .value(.shipSubtitle), dx: -185, baselineDY: 346)))
        XCTAssertTrue(l.contains(.init(kind: .value(.legalStatus), dx: 125, baselineDY: 274)))
        XCTAssertTrue(l.contains(.init(kind: .label(252), dx: 120, baselineDY: 334)))
        XCTAssertEqual(MainMenuReadout.shipPictTopDY, 280)
        XCTAssertEqual(MainMenuReadout.centredLineBaselineDY, 310)
    }

    func testKilledLine() {
        XCTAssertEqual(MainMenuReadout.killedLine(pilotName: "Ash", killedText: "has been killed"),
                       "Ash has been killed")
        XCTAssertEqual(MainMenuReadout.killedLine(pilotName: "Kenny", killedText: "x"),
                       "Oh my God! They killed Kenny!")
        // Only the first five bytes are compared.
        XCTAssertEqual(MainMenuReadout.killedLine(pilotName: "Kennyboy", killedText: "x"),
                       "Oh my God! They killed Kenny!")
    }

    func testButtonsFollowTheirRowsShutter() {
        XCTAssertEqual((0..<6).map(MainMenuReadout.slideIndex(forButton:)), [0, 1, 2, 0, 1, 2])
    }

    /// STR# 134 entry for a record against crime tolerance 10.
    func testLegalRecordEntries() {
        let t = 10
        XCTAssertEqual(MainMenuReadout.legalRecordEntry(record: 0, tolerance: t), 2)     // No Record
        XCTAssertEqual(MainMenuReadout.legalRecordEntry(record: -1, tolerance: t), 3)    // No Convictions
        XCTAssertEqual(MainMenuReadout.legalRecordEntry(record: -11, tolerance: t), 4)
        XCTAssertEqual(MainMenuReadout.legalRecordEntry(record: -41, tolerance: t), 5)
        XCTAssertEqual(MainMenuReadout.legalRecordEntry(record: -40961, tolerance: t), 10)
        XCTAssertEqual(MainMenuReadout.legalRecordEntry(record: 1, tolerance: t), 11)    // Citizen
        XCTAssertEqual(MainMenuReadout.legalRecordEntry(record: 41, tolerance: t), 12)
        XCTAssertEqual(MainMenuReadout.legalRecordEntry(record: 10241, tolerance: t), 16)
    }

    func testLegalStatusOverrides() {
        XCTAssertNil(MainMenuReadout.legalStatusEntry(record: 5, tolerance: 1, dominatedStellars: 0,
                                                      otherStellars: 1, governmentIsXenophobic: true))
        XCTAssertEqual(MainMenuReadout.legalStatusEntry(record: 5, tolerance: 1, dominatedStellars: 2,
                                                        otherStellars: 0, governmentIsXenophobic: false), 18)
        XCTAssertEqual(MainMenuReadout.legalStatusEntry(record: 5, tolerance: 1, dominatedStellars: 1,
                                                        otherStellars: 1, governmentIsXenophobic: false), 17)
    }

    func testDate() {
        let months = ["Jan.", "Feb.", "Mar.", "Apr.", "May", "Jun.", "Jul.", "Aug.", "Sep.", "Oct.", "Nov.", "Dec."]
        let str: (Int) -> String? = { i in
            if (13...24).contains(i) { return months[i - 13] }
            return [25: "st", 26: "nd", 27: "rd", 28: "th"][i]
        }
        XCTAssertEqual(MainMenuReadout.date(day: 1, month: 1, year: 1177, prefix: "", suffix: " NC", str137: str),
                       "Jan. 1st, 1177 NC")
        XCTAssertEqual(MainMenuReadout.date(day: 12, month: 6, year: 1177, prefix: "", suffix: "", str137: str),
                       "Jun. 12th, 1177")
        XCTAssertEqual(MainMenuReadout.date(day: 23, month: 12, year: 3, prefix: "Y", suffix: "", str137: str),
                       "YDec. 23rd, 3")
    }
}
