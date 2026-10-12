import XCTest
@testable import NovaSwiftKit

final class SystemLinkEditingTests: XCTestCase {
    private func doc() -> PluginDocument {
        let d = PluginDocument(name: "T")
        for _ in 0..<20 { _ = try? d.create(NovaType.syst, name: "S") }
        _ = try? d.create(NovaType.spob, name: "P")
        return d
    }

    func testLinkUnlinkBidirectionalAndSingleUndo() {
        let d = doc()
        XCTAssertEqual(SystemLinkEditing.link(d, 128, 129), .linked)
        XCTAssertEqual(SystemLinkEditing.links(of: d, 128), [129])
        XCTAssertEqual(SystemLinkEditing.links(of: d, 129), [128])
        XCTAssertEqual(SystemLinkEditing.link(d, 128, 129), .alreadyLinked)
        d.undo()
        XCTAssertEqual(SystemLinkEditing.links(of: d, 128), [])
        XCTAssertEqual(SystemLinkEditing.links(of: d, 129), [])
        SystemLinkEditing.link(d, 128, 129)
        XCTAssertTrue(SystemLinkEditing.unlink(d, 129, 128))
        XCTAssertEqual(SystemLinkEditing.links(of: d, 128), [])
    }

    func testFullAndStellars() {
        let d = doc()
        for i in 1...16 { XCTAssertEqual(SystemLinkEditing.link(d, 128, 128 + i), .linked) }
        XCTAssertEqual(SystemLinkEditing.link(d, 128, 145), .full(systemID: 128))
        XCTAssertEqual(SystemLinkEditing.links(of: d, 145), [])
        XCTAssertTrue(SystemLinkEditing.addStellar(d, system: 129, spob: 128))
        XCTAssertFalse(SystemLinkEditing.addStellar(d, system: 129, spob: 128))
        XCTAssertEqual(SystemLinkEditing.stellars(of: d, 129), [128])
        XCTAssertTrue(SystemLinkEditing.removeStellar(d, system: 129, spob: 128))
        XCTAssertEqual(SystemLinkEditing.stellars(of: d, 129), [])
    }
}
