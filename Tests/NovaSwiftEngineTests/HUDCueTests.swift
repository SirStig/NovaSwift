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
