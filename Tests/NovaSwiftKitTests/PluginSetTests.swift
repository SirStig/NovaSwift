import XCTest
@testable import NovaSwiftKit

final class PluginSetTests: XCTestCase {
    private func bundle(_ id: String, tc: Bool = false, optional: Bool = false) -> PluginBundle {
        let f = URL(fileURLWithPath: "/tmp/\(id).rez")
        return PluginBundle(id: id, name: id, fileURLs: [f], novaFilesURLs: tc ? [f] : [], isOptional: optional)
    }

    func testOriginalRuleLoadsAllAlphabetically() {
        let out = PluginSet.arrange(discovered: [bundle("b"), bundle("A"), bundle("sub", optional: true)],
                                    persisted: [], manual: false)
        XCTAssertEqual(out.map(\.id), ["A", "b", "sub"])
        XCTAssertEqual(out.map(\.isEnabled), [true, true, false])
    }

    func testManualKeepsPersistedOrderAndEnabled() {
        let persisted = [PluginEnableState(id: "z", isEnabled: true), PluginEnableState(id: "a", isEnabled: false)]
        let out = PluginSet.arrange(discovered: [bundle("a"), bundle("z"), bundle("new")], persisted: persisted, manual: true)
        XCTAssertEqual(out.map(\.id), ["z", "a", "new"])
        XCTAssertEqual(out.map(\.isEnabled), [true, false, false])
    }

    func testManualOneTotalConversion() {
        let persisted = [PluginEnableState(id: "t1", isEnabled: true), PluginEnableState(id: "t2", isEnabled: true)]
        let out = PluginSet.arrange(discovered: [bundle("t1", tc: true), bundle("t2", tc: true)], persisted: persisted, manual: true)
        XCTAssertEqual(out.filter(\.isEnabled).count, 1)
    }

    func testSetEnabledAndMoveRules() {
        var p = [bundle("a"), bundle("b"), bundle("tc", tc: true)]
        XCTAssertFalse(PluginSet.setEnabled(&p, id: "a", enabled: true, manual: false))
        XCTAssertTrue(PluginSet.setEnabled(&p, id: "tc", enabled: true, manual: false))
        XCTAssertTrue(PluginSet.setEnabled(&p, id: "a", enabled: true, manual: true))
        XCTAssertFalse(PluginSet.move(&p, id: "a", by: -1, manual: true))
        XCTAssertTrue(PluginSet.move(&p, id: "a", by: 1, manual: true))
        XCTAssertEqual(p.map(\.id), ["b", "a", "tc"])
        XCTAssertFalse(PluginSet.move(&p, id: "a", by: 1, manual: false))
    }
}
