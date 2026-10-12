import XCTest
@testable import NovaSwiftKit

final class LiveHullBudgetTests: XCTestCase {
    private func run(_ b: inout LiveHullBudget, seconds: Double, frameTime: Double, target: Double?, inUse: Int) {
        for _ in 0..<Int((seconds / frameTime).rounded()) { b.frame(seconds: frameTime, target: target, inUse: inUse) }
    }

    func testStartsAtCeiling() {
        XCTAssertEqual(LiveHullBudget(ceiling: 10).allowed, 10)
        XCTAssertEqual(LiveHullBudget(ceiling: -3).allowed, 0)
    }

    func testDeviceCeilings() {
        XCTAssertEqual(LiveHullBudget.ceiling(mobile: true, appleGPU: true, lowPowerGPU: false, memoryGB: 8), 6)
        XCTAssertEqual(LiveHullBudget.ceiling(mobile: true, appleGPU: true, lowPowerGPU: false, memoryGB: 2), 2)
        XCTAssertEqual(LiveHullBudget.ceiling(mobile: false, appleGPU: false, lowPowerGPU: true, memoryGB: 16), 2)
        XCTAssertEqual(LiveHullBudget.ceiling(mobile: false, appleGPU: false, lowPowerGPU: false, memoryGB: 16), 6)
        XCTAssertEqual(LiveHullBudget.ceiling(mobile: false, appleGPU: true, lowPowerGPU: false, memoryGB: 8), 10)
        XCTAssertEqual(LiveHullBudget.ceiling(mobile: false, appleGPU: true, lowPowerGPU: false, memoryGB: 16), 24)
    }

    func testSlowFramesShedFromWhatIsInUse() {
        var b = LiveHullBudget(ceiling: 24)
        // 60 FPS asked for, 40 achieved with 8 live hulls drawing.
        run(&b, seconds: 1.05, frameTime: 1.0 / 40, target: 1.0 / 60, inUse: 8)
        XCTAssertEqual(b.allowed, 6)   // min(24, 8) − 8/4
        run(&b, seconds: 1.05, frameTime: 1.0 / 40, target: 1.0 / 60, inUse: 6)
        XCTAssertEqual(b.allowed, 5)
    }

    func testSheddingReachesZero() {
        var b = LiveHullBudget(ceiling: 2)
        for _ in 0..<5 { run(&b, seconds: 1.05, frameTime: 1.0 / 20, target: 1.0 / 30, inUse: b.allowed) }
        XCTAssertEqual(b.allowed, 0)
    }

    func testIdleBudgetIsNotPunished() {
        var b = LiveHullBudget(ceiling: 6)
        run(&b, seconds: 3, frameTime: 1.0 / 20, target: 1.0 / 60, inUse: 0)
        XCTAssertEqual(b.allowed, 6)
    }

    func testSteadyFramesGrowBackOneAtATime() {
        var b = LiveHullBudget(ceiling: 6)
        run(&b, seconds: 1.05, frameTime: 1.0 / 30, target: 1.0 / 60, inUse: 4)
        XCTAssertEqual(b.allowed, 3)
        run(&b, seconds: 2.1, frameTime: 1.0 / 60, target: 1.0 / 60, inUse: 3)
        XCTAssertEqual(b.allowed, 3)   // two steady windows: not yet
        run(&b, seconds: 1.05, frameTime: 1.0 / 60, target: 1.0 / 60, inUse: 3)
        XCTAssertEqual(b.allowed, 4)
        for _ in 0..<20 { run(&b, seconds: 1.05, frameTime: 1.0 / 60, target: 1.0 / 60, inUse: b.allowed) }
        XCTAssertEqual(b.allowed, 6)   // never past the ceiling
    }

    func testHitchesAreIgnored() {
        var b = LiveHullBudget(ceiling: 4)
        for _ in 0..<10 { b.frame(seconds: 0.8, target: 1.0 / 60, inUse: 4) }
        XCTAssertEqual(b.allowed, 4)
    }
}
