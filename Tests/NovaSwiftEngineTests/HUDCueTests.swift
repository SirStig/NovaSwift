import XCTest
@testable import NovaSwiftEngine

/// M-1: the Red Alert edge detector of 0x0044aa70 / 0x0044d371.
final class HUDCueTests: XCTestCase {

    func testRedAlertPlaysOnceOnTheRisingEdge() {
        var cue = RedAlertCue()
        var threat = false
        XCTAssertFalse(cue.advance(rawCalls: 120, lowVolume: false, inEscapePod: false) { threat })
        threat = true
        // The check runs only on every 60th frame.
        var fired = 0
        for _ in 0..<200 where cue.advance(rawCalls: 1, lowVolume: false, inEscapePod: false, threat: { threat }) {
            fired += 1
        }
        XCTAssertEqual(fired, 1, "one Red Alert while the threat persists")
        threat = false
        _ = cue.advance(rawCalls: 60, lowVolume: false, inEscapePod: false) { threat }
        threat = true
        XCTAssertTrue(cue.advance(rawCalls: 60, lowVolume: false, inEscapePod: false) { threat },
                      "a threat that clears and returns sounds again")
    }

    /// Input A / M3: E shows the panel, keys pick a group, orders go to that
    /// group, and the panel fades a level a frame after 0x1e0 ticks.
    func testEscortCommandPanel() {
        var panel = EscortCommandPanel()
        XCTAssertEqual(panel.pressE(hasEscorts: false, now: 0), .noEscorts)
        XCTAssertFalse(panel.isOpen)
        XCTAssertNil(panel.order(2), "closed: every escort")
        XCTAssertEqual(panel.orders, [2, 2, 2, 2])
        XCTAssertFalse(panel.pressGroupKey(1, hasCategory: { _ in true }, now: 0), "group keys need the panel")
        XCTAssertEqual(panel.pressE(hasEscorts: true, now: 0), .opened)
        XCTAssertEqual(panel.level, 0x20)
        XCTAssertFalse(panel.pressGroupKey(3, hasCategory: { $0 == 0 }, now: 10), "no warships")
        XCTAssertTrue(panel.pressGroupKey(1, hasCategory: { $0 == 0 }, now: 10))
        XCTAssertEqual(panel.order(1), 0, "only the fighters")
        XCTAssertEqual(panel.orders, [1, 2, 2, 2])
        panel.tick(frames: 5, now: 10 + 0x1e0, liveEscorts: 1, fighterOut: { _ in false })
        XCTAssertEqual(panel.level, 0x20, "still within the hold")
        panel.tick(frames: 5, now: 11 + 0x1e0, liveEscorts: 1, fighterOut: { _ in false })
        XCTAssertEqual(panel.level, 0x1b)
        panel.tick(frames: 40, now: 12 + 0x1e0, liveEscorts: 1, fighterOut: { _ in false })
        XCTAssertFalse(panel.isOpen)
        XCTAssertNil(panel.order(4), "faded: the order goes to everyone again")
    }

    func testNoAlertInTheEscapePodAndBlinkAtLowVolume() {
        var cue = RedAlertCue()
        XCTAssertFalse(cue.advance(rawCalls: 1, lowVolume: true, inEscapePod: true) { true })
        var cue2 = RedAlertCue()
        XCTAssertTrue(cue2.advance(rawCalls: 1, lowVolume: true, inEscapePod: false) { true })
        XCTAssertNotNil(cue2.blinkFrame)
        _ = cue2.advance(rawCalls: 150, lowVolume: true, inEscapePod: false) { true }
        XCTAssertNil(cue2.blinkFrame, "30 steps, one every 5th frame")
    }
}
