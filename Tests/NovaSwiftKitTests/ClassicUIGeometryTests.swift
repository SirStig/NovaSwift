import XCTest
@testable import NovaSwiftKit

final class ClassicUIGeometryTests: XCTestCase {
    typealias G = ClassicUIGeometry

    func testCrispScaleFollowsReferenceScreenNotFrameFit() {
        // A small dialog is NOT blown up to fill the window: on 1280x720 /
        // 1280x800 (Steam Deck) the viewport barely outgrows 1024x768 -> 1x.
        XCTAssertEqual(G.crispScale(frameWidth: 355, frameHeight: 109, viewportWidth: 1280, viewportHeight: 800), 1.0)
        XCTAssertEqual(G.crispScale(frameWidth: 640, frameHeight: 480, viewportWidth: 1280, viewportHeight: 720), 1.0)
        // A 2048x1536 viewport is 2x the reference screen -> 2x.
        XCTAssertEqual(G.crispScale(frameWidth: 640, frameHeight: 480, viewportWidth: 2048, viewportHeight: 1536), 2.0)
        // ...snapped down to half steps (1.875 -> 1.5), capped at 2.6 -> 2.5.
        XCTAssertEqual(G.crispScale(frameWidth: 100, frameHeight: 100, viewportWidth: 1920, viewportHeight: 1440), 1.5)
        XCTAssertEqual(G.crispScale(frameWidth: 100, frameHeight: 100, viewportWidth: 4000, viewportHeight: 3000), 2.5)
        // A frame bigger than the viewport shrinks to fit.
        XCTAssertEqual(G.crispScale(frameWidth: 2000, frameHeight: 1000, viewportWidth: 1000, viewportHeight: 1000), 0.5)
    }

    func testBarSegments() {
        // wide bar fills from the left
        XCTAssertEqual(G.barSegment(left: 10, top: 5, width: 100, height: 8, from: 0, to: 0.5),
                       G.PixelRect(x: 10, y: 5, w: 50, h: 8))
        // tall bar fills from the bottom
        XCTAssertEqual(G.barSegment(left: 10, top: 5, width: 8, height: 100, from: 0, to: 0.25),
                       G.PixelRect(x: 10, y: 80, w: 8, h: 25))
    }

    func testFuelSplit() {
        let s = G.fuelSplit(fuelFraction: 0.75, jumps: 2, maxFuelUnits: 400)
        XCTAssertEqual(s.full, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.partial, 0.25, accuracy: 1e-9)
        let n = G.fuelSplit(fuelFraction: 0.3, jumps: 0, maxFuelUnits: 0)
        XCTAssertEqual(n.full, 0.3, accuracy: 1e-9)
        XCTAssertEqual(n.partial, 0, accuracy: 1e-9)
    }

    func testFocusNeighbours() {
        // 2x2 grid of buttons
        let r = [G.FocusRect(left: 0, top: 0, right: 50, bottom: 20),
                 G.FocusRect(left: 100, top: 0, right: 150, bottom: 20),
                 G.FocusRect(left: 0, top: 40, right: 50, bottom: 60),
                 G.FocusRect(left: 100, top: 40, right: 150, bottom: 60)]
        let n = G.focusNeighbours(r)
        XCTAssertEqual(n[0], [-1, 2, -1, 1])
        XCTAssertEqual(n[3], [1, -1, 2, -1])
    }

    func testButtonComposeStretchesMiddleAndMasksCaps() {
        func solid(_ w: Int, _ h: Int, _ c: UInt8) -> ThreeStateButtonRaster.Image {
            .init(width: w, height: h, rgba: (0..<(w * h)).flatMap { _ in [c, c, c, 255] })
        }
        // right-most column of the left cap masked out (white mask pixel)
        var mask = solid(2, 2, 0)
        for y in 0..<2 { let p = (y * 2 + 1) * 4; mask.rgba[p] = 255; mask.rgba[p + 1] = 255; mask.rgba[p + 2] = 255 }
        let left = ThreeStateButtonRaster.applyMask(mask, to: solid(2, 2, 10))
        XCTAssertEqual(left.rgba[3], 255); XCTAssertEqual(left.rgba[7], 0)
        let b = ThreeStateButtonRaster.compose(width: 10, height: 4, left: left, middle: solid(1, 1, 100), right: solid(2, 2, 200))
        func px(_ x: Int, _ y: Int) -> [UInt8] { Array(b.rgba[((y * 10 + x) * 4)..<((y * 10 + x) * 4 + 4)]) }
        XCTAssertEqual(px(0, 0), [10, 10, 10, 255])
        XCTAssertEqual(px(5, 2), [100, 100, 100, 255])   // middle stretched
        XCTAssertEqual(px(9, 3), [200, 200, 200, 255])
        XCTAssertEqual(px(1, 0), [0, 0, 0, 0])   // masked cap column stays transparent
    }
}
