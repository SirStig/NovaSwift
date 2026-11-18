import XCTest
import Foundation
@testable import NovaSwiftKit

/// The built-in fallback layouts must match the shipped DLOG/DITL exactly.
final class StockDialogsTests: XCTestCase {
    func testStockLayoutsMatchNovaRez() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("data/EV Nova/Nova.rez")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no local data/EV Nova/Nova.rez") }
        let c = try ResourceFile.read(contentsOf: url)
        for id in [3001, 3002, 3101, 3102] {
            let stock = try XCTUnwrap(StockDialogs.dialog(id), "\(id)")
            let dlog = DLOGRes(try XCTUnwrap(c.resource(NovaType.dlog, id)))
            let ditl = DITLRes(try XCTUnwrap(c.resource(NovaType.ditl, id)))
            XCTAssertEqual(stock.window?.bounds.width, dlog.bounds.width, "\(id) width")
            XCTAssertEqual(stock.window?.bounds.height, dlog.bounds.height, "\(id) height")
            XCTAssertEqual(stock.items.items.count, ditl.items.count, "\(id) item count")
            for (a, b) in zip(stock.items.items, ditl.items) {
                XCTAssertEqual(a.index, b.index)
                XCTAssertEqual(a.rect, b.rect, "\(id)[\(a.index)] rect")
                XCTAssertEqual(a.kind, b.kind, "\(id)[\(a.index)] kind")
                XCTAssertEqual(a.isEnabled, b.isEnabled, "\(id)[\(a.index)] enabled")
                XCTAssertEqual(a.text, b.text, "\(id)[\(a.index)] text")
                XCTAssertEqual(a.resourceID, b.resourceID, "\(id)[\(a.index)] res")
            }
        }
    }

    /// No DLOG/DITL in the data: `dialog(_:)` serves the stock layout.
    func testDataWithoutNovaRezGetsTheStockPrompt() {
        let game = NovaGame(ResourceCollection())
        XCTAssertTrue(game.hasDialogItems(3001, [0, 2, 4, 5]))
        XCTAssertTrue(game.hasDialogItems(3102, [0, 1, 3, 7, 8, 10]))
        XCTAssertNil(game.dialog(4003))
    }
}
