import XCTest
@testable import NovaSwiftEngine

final class HullAnimatorTests: XCTestCase {
    func testBankSetsAndWrap() {
        var c = HullAnimConfig()
        c.setCount = 3; c.mode = .banking; c.framesPerSet = 36
        XCTAssertEqual(c.baseSet(turnSign: 1, animClock: 0, disabled: false), 1)
        XCTAssertEqual(c.baseSet(turnSign: -1, animClock: 0, disabled: false), 2)
        XCTAssertEqual(c.baseSet(turnSign: 1, animClock: 0, disabled: true), 0)
        XCTAssertEqual(c.frameIndex(set: 2, heading: 5, count: 36), 5)   // fewer sets than the base wraps
    }

    func testWeaponGlowDecayAndShieldFlare() {
        var c = HullAnimConfig(); c.weapDecay = 50
        XCTAssertEqual(c.weaponGlowAfter(1, dt: 10), 0)
        XCTAssertGreaterThan(c.weaponGlowAfter(1, dt: 0.01), 0.8)
        let f = ShieldFlare.advance(0, shieldNow: 90, shieldWas: 100, maxShield: 100, dt: 0.016)
        XCTAssertGreaterThanOrEqual(f, 0.4)
        XCTAssertEqual(ShieldFlare.advance(f, shieldNow: 90, shieldWas: 90, maxShield: 100, dt: 1), 0)
    }

    func testStellarAnimatorAdvances() {
        var a = StellarAnimator(frameCount: 4, delay: 2, bias: 0, flags2: 0, custPic: 0)
        var frames: [Int] = []
        for _ in 0..<8 { frames.append(a.step(ticks: 1, engaged: false) { _ in 0 }) }
        XCTAssertEqual(Set(frames), [0, 1, 2, 3])
    }
}
