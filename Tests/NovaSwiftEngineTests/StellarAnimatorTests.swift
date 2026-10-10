import XCTest
@testable import NovaSwiftEngine

final class StellarAnimatorTests: XCTestCase {
    func testZeroDelayAdvancesEveryStep() {
        var a = StellarAnimator(frameCount: 4, delay: 0, bias: 1, flags2: 0, custPic: 0)
        let frames = (0..<5).map { _ in a.step(ticks: 1, engaged: false) { _ in 0 } }
        XCTAssertEqual(frames, [0, 1, 2, 3, 0])
    }

    func testGateOpensToTransitionFrameThenCloses() {
        var a = StellarAnimator(frameCount: 8, delay: 1, bias: 1, flags2: 0x1000, custPic: 0)
        XCTAssertEqual(a.transitionFrame, 4)
        var frame = 0
        for _ in 0..<4 { frame = a.step(ticks: 1, engaged: true) { _ in 0 } }
        XCTAssertEqual(frame, 4)
        for _ in 0..<4 { frame = a.step(ticks: 1, engaged: false) { _ in 0 } }
        XCTAssertEqual(frame, 0)
    }

    func testRandomPickNeverRepeats() {
        var a = StellarAnimator(frameCount: 3, delay: 0, bias: 1, flags2: 0x0002, custPic: 0)
        var seq = [0, 0, 1, 1, 2, 2, 0]
        var last = -1
        for _ in 0..<3 {
            let f = a.step(ticks: 1, engaged: false) { _ in seq.removeFirst() }
            XCTAssertNotEqual(f, last); last = f
        }
    }
}
