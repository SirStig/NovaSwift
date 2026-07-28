import XCTest
@testable import NovaSwiftKit

/// TEMPORARY scratch: dump armed spöbs from the real base data to verify the
/// `Weapon`@570 / `Strength`@572 offsets. Deleted after verification.
final class ScratchSpobWeaponDump: XCTestCase {
    func testDumpArmedSpobs() throws {
        let base = URL(fileURLWithPath: "/Users/joshuakac1/Projects/EV-NOVA/data/EV Nova/Nova Files")
        guard FileManager.default.fileExists(atPath: base.path) else { throw XCTSkip("no data") }
        let files = GameLibrary.discoverResourceFiles(in: base)
        let game = NovaGame(try GameLibrary.merge(baseFiles: files))
        var armed = 0, destructible = 0
        for s in game.spobs() {
            if let wid = s.defenseWeaponID {
                armed += 1
                let wname = game.weapon(wid)?.name ?? "MISSING WEAPON \(wid)"
                print("ARMED spob #\(s.id) \(s.name) govt=\(s.government) weapon=\(wid) '\(wname)' strength=\(s.strength) provokedOnly=\(s.firesWeaponOnlyWhenProvoked)")
            }
            if s.strength > 0 { destructible += 1 }
        }
        print("TOTAL armed=\(armed) destructible=\(destructible) of \(game.spobs().count) spobs")
    }
}
