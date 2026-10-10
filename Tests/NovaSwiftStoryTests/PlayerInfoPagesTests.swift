import XCTest
import NovaSwiftKit
@testable import NovaSwiftStory

/// UI-13: the Player Info stat grid reads STR# 2002 and the original's display
/// scales.
final class PlayerInfoPagesTests: XCTestCase {

    private func strList(_ id: Int, _ items: [String]) -> Resource {
        var b: [UInt8] = [UInt8(items.count >> 8), UInt8(items.count & 0xff)]
        for s in items { let bytes = Array(s.utf8); b.append(UInt8(bytes.count)); b += bytes }
        return Resource(type: NovaType.strList, id: id, name: "STR#\(id)", data: Data(b))
    }

    private func game() -> NovaGame {
        var misc = (1...400).map { "#\($0)" }
        misc[33 - 1] = "credits"
        misc[257 - 1] = "Turn Rate:"
        misc[258 - 1] = " deg/sec"   // ASCII: the builder writes UTF-8, the decoder reads MacRoman
        misc[259 - 1] = "Accel Rate:"
        misc[260 - 1] = "Max Speed:"
        misc[239 - 1] = "jump"; misc[240 - 1] = "jumps"
        misc[262 - 1] = "plus"; misc[263 - 1] = "only"; misc[9 - 1] = "maneuvering energy"
        return makeGame([strList(2002, misc)])
    }

    private func figures(speedPerTick: Double) -> PlayerInfoPages.ShipFigures {
        .init(turnDegPerTick: 3, thrustPerTick2: 0.1, maxSpeedPerTick: speedPerTick,
              shield: 50, maxShield: 100, armor: 100, maxArmor: 100, destroyed: false, fuel: 250)
    }

    func testNonStrictMaxSpeedShowsTheHullSpeed() {
        // shïp Speed 250 is 2.5 px/tick; a non-strict pilot flies it ×1.5, and the
        // grid's ×100 × 2/3 brings it back to 250.
        let player = PlayerState(currentSystem: 128)
        let rows = PlayerInfoPages(game: game(), player: player).rightColumn(figures(speedPerTick: 3.75))
        XCTAssertTrue(rows.contains(.init(label: "Max Speed:", value: "250")))
        XCTAssertTrue(rows.contains(.init(label: "Turn Rate:", value: "90 deg/sec")))
        XCTAssertTrue(rows.contains(.init(label: "Accel Rate:", value: "250")))
        XCTAssertEqual(rows.last, .init(label: "Credits:", value: OriginalText.grouped(player.credits)))
    }

    func testStrictMaxSpeedIsUnscaled() {
        var player = PlayerState(currentSystem: 128)
        player.strictPlay = true
        let rows = PlayerInfoPages(game: game(), player: player).rightColumn(figures(speedPerTick: 2.5))
        XCTAssertTrue(rows.contains(.init(label: "Max Speed:", value: "250")))
    }

    func testEnergyWording() {
        let pages = PlayerInfoPages(game: game(), player: PlayerState(currentSystem: 128))
        XCTAssertEqual(pages.energy(250), "2 jumps plus maneuvering energy")
        XCTAssertEqual(pages.energy(100), "1 jump")
        XCTAssertEqual(pages.energy(40), "maneuvering energy only")
    }
}
