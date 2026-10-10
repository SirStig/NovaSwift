import XCTest
@testable import NovaSwiftKit

final class OriginalRenderingTests: XCTestCase {
    func testFrameWrapsInsteadOfClamping() {
        XCTAssertEqual(OriginalRendering.wrappedFrame(113, count: 36), 5)
        XCTAssertEqual(OriginalRendering.wrappedFrame(-4, count: 36), 0)
        XCTAssertEqual(OriginalRendering.wrappedFrame(7, count: 0), 0)
    }

    func testPersColourTintsOnlyRed() {
        let t = OriginalRendering.shipTint(isPlayer: false, paint555: nil, persColor555: 0x7C00, govtShipColor: nil)
        XCTAssertEqual(t, .init(r: 31, g: 0, b: 0))
    }

    func testPlayerIgnoresGovtAndPers() {
        let t = OriginalRendering.shipTint(isPlayer: true, paint555: nil, persColor555: 0x7C00, govtShipColor: (255, 0, 0))
        XCTAssertTrue(t.isNeutral)
    }

    func testStarCountAndParticleFade() {
        XCTAssertEqual(OriginalRendering.starCount(viewHeight: 600), 20)
        XCTAssertEqual(OriginalRendering.starCount(viewHeight: 300), 10)
        XCTAssertEqual(OriginalRendering.particleAlpha(life: 40), 1)
        XCTAssertEqual(OriginalRendering.particleAlpha(life: 16), 0.5)
        XCTAssertEqual(OriginalRendering.particleAlpha(life: 1), 0)
    }
}
