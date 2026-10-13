import XCTest
@testable import NovaSwiftKit

/// The hypergate / wormhole entry movie lookup (`Stellar_EnterHypergate` 0x00456480 /
/// `Stellar_EnterWormhole` 0x00456ca0 -> `FUN_0049e3c0(selection + 0x80)`) and the shared
/// political-overlay builder behind the Godot map's Show Borders.
final class GateTravelMovieTests: XCTestCase {
    private func descResource(id: Int, movie: String?, flags: UInt16 = 0) -> Resource {
        var d = Data("Text".utf8); d.append(0)
        d.append(contentsOf: [0, 0])                                  // picture id
        var n = Array((movie ?? "").utf8)
        n += [UInt8](repeating: 0, count: 32 - n.count)
        d.append(contentsOf: n); d.append(contentsOf: [UInt8(flags >> 8), UInt8(flags & 0xff)])
        return Resource(type: NovaType.desc, id: id, data: d)
    }

    private func game(_ resources: [Resource]) -> NovaGame {
        var c = ResourceCollection()
        for r in resources { c.add(r) }
        return NovaGame(c)
    }

    func testGateMovieIsTheDescWithTheSelectionsId() {
        let g = game([descResource(id: 140, movie: "Gate.mov", flags: 0x0006),
                      descResource(id: 141, movie: nil)])
        XCTAssertEqual(GateTravelMovie.descID(forTravelSelection: 140), 140)
        let d = g.gateTravelMovieDesc(selection: 140)
        XCTAssertEqual(d?.movieFilename, "Gate.mov")
        XCTAssertEqual(d?.movieDoubleSize, true)
        XCTAssertEqual(d?.movieFillsScreen, true)
        XCTAssertNil(g.gateTravelMovieDesc(selection: 141), "a dësc without a MovieFile plays nothing")
        XCTAssertNil(g.gateTravelMovieDesc(selection: 142), "no such dësc")
    }

    func testNoSelectionPlaysNothing() {
        // -1 + 0x80 = 127: below the first dësc id, so the original finds no movie either.
        let g = game([descResource(id: 127, movie: "Never.mov"), descResource(id: 128, movie: "A.mov")])
        XCTAssertNil(g.gateTravelMovieDesc(selection: nil))
        XCTAssertNil(g.gateTravelMovieDesc(selection: -1))
        XCTAssertNil(g.gateTravelMovieDesc(selection: 127))
        XCTAssertNotNil(g.gateTravelMovieDesc(selection: 128))
    }

    func testPoliticalOverlayBuildPaintsDiscsAndLeavesFarCellsEmpty() {
        let govt = { (id: Int) in Resource(type: NovaType.govt, id: id, data: Data(repeating: 0, count: 400)) }
        let g = game([govt(128), govt(129)])
        XCTAssertTrue(PoliticalOverlay.allied(g, 128, 128))
        XCTAssertFalse(PoliticalOverlay.allied(g, 128, 129))
        let discs = [PoliticalOverlay.Disc(cellX: 30, cellY: 30, govt: 128, small: false),
                     PoliticalOverlay.Disc(cellX: 80, cellY: 30, govt: 129, small: true)]
        let grid = PoliticalOverlay.build(width: 120, height: 60, unitsPerPixel: 1, discs: discs, game: g)
        XCTAssertEqual(grid.strongest(30, 30)?.govt, 128)
        XCTAssertEqual(grid.strongest(80, 30)?.govt, 129)
        XCTAssertNil(grid.strongest(0, 59))
        XCTAssertEqual(PoliticalOverlay.radius(zoom: 1, small: false), 34)
        XCTAssertEqual(PoliticalOverlay.radius(zoom: 1, small: true), 20)
        XCTAssertEqual(grid.rgba(game: g).count, 120 * 60 * 4)
    }

    func testNoSystemsNoDiscs() {
        let g = game([])
        let d = PoliticalOverlay.discs(game: g, systems: [], isKnown: { _ in true }, hasUsableStellar: { _ in true },
                                       plot: { ($0.doubleValue, $1.doubleValue) })
        XCTAssertTrue(d.isEmpty)
    }
}

private extension Int { var doubleValue: Double { Double(self) } }
