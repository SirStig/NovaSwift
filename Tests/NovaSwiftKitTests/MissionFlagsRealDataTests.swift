import XCTest
@testable import NovaSwiftKit

/// Pins the mïsn Flags/Flags2/RefuseText/AvailShipType offsets against the real
/// stock data (the original reads them at 0x50/0x52/0x58/0x5A). Skips when the
/// user-supplied game data isn't present under `data/base`.
final class MissionFlagsRealDataTests: XCTestCase {

    private func stockGame() throws -> NovaGame {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = repo.appendingPathComponent("data/base")
        let files = GameLibrary.discoverResourceFiles(in: base)
        guard !files.isEmpty else { throw XCTSkip("No stock data under data/base") }
        return NovaGame(try GameLibrary.merge(baseFiles: files))
    }

    func testStockMissionFlagsDecodeAtOriginalOffsets() throws {
        let missions = try stockGame().missions()
        XCTAssertGreaterThan(missions.count, 700)

        // The unused word before Flags is zero everywhere; Flags itself is not.
        XCTAssertTrue(missions.contains { $0.flags1 != 0 })
        XCTAssertEqual(missions.filter(\.autoAbortWhenStarted).count, 44)
        // Only the 128+/1128+/2128+/3128+ bands restrict; other values are ignored.
        let restricted = missions.filter { $0.availShipType >= 128 }
        XCTAssertEqual(restricted.count, 86,
                       "\(Dictionary(grouping: missions, by: \.availShipType).mapValues(\.count))")
        XCTAssertTrue(missions.contains { $0.refuseText > 0 })
        // Flags2 only defines bits 0x0001/0x0002/0x0004.
        XCTAssertTrue(missions.allSatisfy { $0.flags2 & ~0x0007 == 0 })
    }
}
