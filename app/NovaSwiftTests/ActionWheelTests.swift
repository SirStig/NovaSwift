import XCTest
@testable import NovaSwift

final class ActionWheelTests: XCTestCase {
    func testDefaultsLeaveNothingUncovered() {
        let missing = ActionWheels.uncovered(bindings: PadBindings(), wheels: ActionWheels())
        XCTAssertEqual(missing, [], "unreachable from the pad: \(missing.map(\.rawValue))")
    }

    func testRemovingAWheelReportsItsActions() {
        var w = ActionWheels()
        w.wheels.removeAll { $0.id == "info" }
        let missing = ActionWheels.uncovered(bindings: PadBindings(), wheels: w)
        XCTAssertTrue(missing.contains(.playerInfo))
        XCTAssertFalse(missing.contains(.turnLeft), "the left stick covers turning")
    }

    func testEverySlotIsDiscreteOrSelfDestruct() {
        for wheel in ActionWheels.defaults {
            XCTAssertTrue(ActionWheel.slotRange.contains(wheel.slots.count), wheel.title)
            for a in wheel.slots {
                XCTAssertTrue(ActionWheels.isSlotEligible(a), "\(a) in \(wheel.title)")
                XCTAssertTrue(!a.continuous || a == .selfDestruct)
            }
        }
    }

    func testDefaultTriggersAreUniqueAndUsable() {
        let triggers = ActionWheels.defaults.map(\.trigger)
        XCTAssertEqual(Set(triggers).count, triggers.count)
        for t in triggers { XCTAssertTrue(ActionWheels.canTrigger(t, bindings: PadBindings())) }
        XCTAssertFalse(ActionWheels.canTrigger(.buttonA, bindings: PadBindings()), "A fires the primary")
    }

    func testSaveLoadRoundTrip() {
        let key = ActionWheels.storageKey
        let saved = UserDefaults.standard.data(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        var w = ActionWheels()
        w.wheels[0].trigger = .dpadUp
        w.wheels[0].slots.removeLast()
        w.save()
        XCTAssertEqual(ActionWheels.load(), w)
    }

    func testSlotIndexFromAngle() {
        // 8 slots: slot 0 up, then clockwise every 45 degrees.
        XCTAssertEqual(ActionWheels.slotIndex(x: 0, y: 1, count: 8), 0)
        XCTAssertEqual(ActionWheels.slotIndex(x: 1, y: 1, count: 8), 1)
        XCTAssertEqual(ActionWheels.slotIndex(x: 1, y: 0, count: 8), 2)
        XCTAssertEqual(ActionWheels.slotIndex(x: 0, y: -1, count: 8), 4)
        XCTAssertEqual(ActionWheels.slotIndex(x: -1, y: 0, count: 8), 6)
        XCTAssertEqual(ActionWheels.slotIndex(x: -0.1, y: 1, count: 8), 0, "just left of up is still slot 0")
        XCTAssertEqual(ActionWheels.slotIndex(x: -1, y: 0, count: 12), 9, "left of a 12-slot wheel")
        XCTAssertNil(ActionWheels.slotIndex(x: 0.2, y: 0.2, count: 8), "inside the dead centre")
        XCTAssertEqual(ActionWheels.slotIndex(angle: -.pi / 4, count: 8), 7)
        XCTAssertEqual(ActionWheels.slotIndex(angle: 2 * .pi, count: 12), 0)
    }
}
