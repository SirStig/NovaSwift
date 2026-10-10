import XCTest
@testable import NovaSwiftEngine
import NovaSwiftKit

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
        // Closing runs on through the open frames to the end, wraps to T-1, then steps down.
        for _ in 0..<7 { frame = a.step(ticks: 1, engaged: false) { _ in 0 } }
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

final class PixelMaskAbutTests: XCTestCase {
    private func mask(_ opaque: ClosedRange<Int>, width: Int = 8) -> SpriteMaskSet {
        var w: UInt64 = 0
        for x in opaque { w |= 1 << UInt64(x) }
        return SpriteMaskSet(width: width, height: 1, frameCount: 1, bits: [w])
    }
    /// Oracle (0x00472190): A opaque 0...3 with B opaque from 4 is a hit; the reverse is not.
    func testAbuttingRunsHitOnlyInOneOrder() {
        let a = mask(0...3), b = mask(0...3)
        XCTAssertTrue(a.overlaps(frame: 0, left: 0, top: 0, b, otherFrame: 0, otherLeft: 4, otherTop: 0))
        XCTAssertFalse(b.overlaps(frame: 0, left: 4, top: 0, a, otherFrame: 0, otherLeft: 0, otherTop: 0))
    }
}
