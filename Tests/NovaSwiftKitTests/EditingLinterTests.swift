import XCTest
@testable import NovaSwiftKit

final class EditingLinterTests: XCTestCase {

    private func lint(_ d: PluginDocument) -> [LintIssue] { PluginLinter.lint(d) }
    private func has(_ issues: [LintIssue], _ code: String, _ key: ResourceKey? = nil) -> Bool {
        issues.contains { $0.code == code && (key == nil || $0.key == key) }
    }

    func testCleanDocumentHasNoErrors() throws {
        let d = PluginDocument()
        let spob = try d.create(NovaType.spob)
        let sys = try d.create(NovaType.syst)
        d.setValue(.array([.int(spob)] + Array(repeating: .int(-1), count: 15)), field: "navDefaults", of: NovaType.syst, sys)
        let issues = lint(d)
        XCTAssertTrue(issues.filter { $0.severity == .error }.isEmpty, "\(issues)")
    }

    func testDanglingReferences() throws {
        let d = PluginDocument()
        let shan = try d.create(NovaType.shan)
        d.setValue(.int(9999), field: "baseSprite", of: NovaType.shan, shan)
        var issues = lint(d)
        XCTAssertTrue(has(issues, "dangling-ref", ResourceKey(NovaType.shan, shan)))
        // Supplying the sprite (as a PICT sheet is also accepted) clears it.
        d.put(Resource(type: NovaType.pict, id: 9999, data: Data([0])))
        issues = lint(d)
        XCTAssertFalse(has(issues, "dangling-ref", ResourceKey(NovaType.shan, shan)))

        // Range-encoded and contextual references dangle too.
        let m = try d.create(NovaType.mission)
        d.setValue(.int(10200), field: "availStel", of: NovaType.mission, m)         // govt 328
        XCTAssertTrue(lint(d).contains { $0.code == "dangling-ref" && $0.fieldKey == "availStel" })
        d.setValue(.string("b1 S999"), field: "onAccept", of: NovaType.mission, m)
        XCTAssertTrue(lint(d).contains { $0.code == "dangling-script-ref" && $0.fieldKey == "onAccept" })
    }

    func testIdRangesAndShortRecords() {
        let d = PluginDocument()
        d.put(Resource(type: NovaType.ship, id: 100, name: "Too low", data: Data(count: 1860)))
        d.put(Resource(type: NovaType.ship, id: 128 + 0x300, name: "Too high", data: Data(count: 1860)))
        d.put(Resource(type: NovaType.ship, id: 128, name: "Short", data: Data(count: 100)))
        let issues = lint(d)
        XCTAssertTrue(has(issues, "id-range", ResourceKey(NovaType.ship, 100)))
        XCTAssertTrue(has(issues, "id-range", ResourceKey(NovaType.ship, 128 + 0x300)))
        XCTAssertTrue(has(issues, "short-record", ResourceKey(NovaType.ship, 128)))
        XCTAssertFalse(has(issues, "id-range", ResourceKey(NovaType.ship, 128)))
    }

    func testStringOverflowAndNCBSyntax() throws {
        let d = PluginDocument()
        let m = try d.create(NovaType.mission)
        var data = d.layerResource(NovaType.mission, m)!.data
        let f = ResourceSchemas.schema(for: NovaType.mission)!.field("availBits")!
        for i in 0..<255 { data[f.offset + i] = UInt8(ascii: "b") }          // no terminator
        d.put(Resource(type: NovaType.mission, id: m, data: data))
        XCTAssertTrue(lint(d).contains { $0.code == "string-length" && $0.fieldKey == "availBits" })

        d.setValue(.string("(b1 & b2"), field: "availBits", of: NovaType.mission, m)
        XCTAssertTrue(lint(d).contains { $0.code == "ncb-syntax" && $0.severity == .error })
        d.setValue(.string("b1 & b2"), field: "availBits", of: NovaType.mission, m)
        XCTAssertFalse(lint(d).contains { $0.code == "ncb-syntax" })
        d.setValue(.string("b1 !b2 Z4"), field: "onAccept", of: NovaType.mission, m)
        XCTAssertTrue(lint(d).contains { $0.code == "ncb-syntax" && $0.fieldKey == "onAccept" })
    }

    func testOneWayHyperlinkAndUnplacedStellar() throws {
        let d = PluginDocument()
        let a = try d.create(NovaType.syst), b = try d.create(NovaType.syst)
        let links = { (id: Int) -> FieldValue in .array([.int(id)] + Array(repeating: .int(-1), count: 15)) }
        d.setValue(links(b), field: "links", of: NovaType.syst, a)
        var issues = lint(d)
        XCTAssertTrue(has(issues, "one-way-link", ResourceKey(NovaType.syst, a)))
        d.setValue(links(a), field: "links", of: NovaType.syst, b)
        issues = lint(d)
        XCTAssertFalse(has(issues, "one-way-link"))

        let planet = try d.create(NovaType.spob)
        XCTAssertTrue(has(lint(d), "stellar-unplaced", ResourceKey(NovaType.spob, planet)))
        d.setValue(.array([.int(planet)] + Array(repeating: .int(-1), count: 15)), field: "navDefaults", of: NovaType.syst, a)
        XCTAssertFalse(has(lint(d), "stellar-unplaced"))
    }

    func testShipWithoutSpriteAndWeaponWithoutOutfit() throws {
        let d = PluginDocument()
        let s = try d.create(NovaType.ship)
        XCTAssertTrue(has(lint(d), "ship-no-sprite", ResourceKey(NovaType.ship, s)))
        d.put(Resource(type: NovaType.shan, id: s, data: ResourceSchemas.schema(for: NovaType.shan)!.makeDefault()))
        XCTAssertTrue(has(lint(d), "ship-no-sprite"), "shän exists but its sprite doesn't")
        d.setValue(.int(2000), field: "baseSprite", of: NovaType.shan, s)
        d.put(Resource(type: NovaType.rleD, id: 2000, data: Data([0])))
        XCTAssertFalse(has(lint(d), "ship-no-sprite"))

        let w = try d.create(NovaType.weapon)
        XCTAssertTrue(has(lint(d), "weapon-no-outfit", ResourceKey(NovaType.weapon, w)))
        let o = try d.create(NovaType.outfit)
        d.setValue(.int(1), field: "modType", of: NovaType.outfit, o)
        d.setValue(.int(w), field: "modValue", of: NovaType.outfit, o)
        XCTAssertFalse(has(lint(d), "weapon-no-outfit"))
    }

    func testRedundantOverrideAndStringListChecks() throws {
        var base = ResourceCollection()
        base.add(Resource(type: NovaType.ship, id: 128, name: "S", data: ResourceSchemas.schema(for: NovaType.ship)!.makeDefault()))
        let d = PluginDocument(base: base)
        d.put(base.resource(NovaType.ship, 128)!)
        XCTAssertTrue(has(lint(d), "redundant-override"))
        d.put(Resource(type: NovaType.strList, id: 200, data: Data([0, 5, 1, 65])))     // says 5, holds 1
        XCTAssertTrue(has(lint(d), "str-malformed"))
    }

    func testValueRangeWarnings() throws {
        let d = PluginDocument()
        let p = try d.create(NovaType.pers)
        d.setValue(.int(150), field: "coward", of: NovaType.pers, p)
        XCTAssertTrue(lint(d).contains { $0.code == "value-range" && $0.fieldKey == "coward" })
    }

    /// The shipped game is the reference for "valid": linting all of it must
    /// raise no errors (warnings flag real oddities in the stock data, e.g.
    /// one-way hyperlinks, but nothing the game itself rejects).
    func testStockDataLintsWithoutErrors() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = GameLibrary.discoverResourceFiles(in: repo.appendingPathComponent("data/base"))
        guard !files.isEmpty else { throw XCTSkip("No stock data under data/base") }
        var c = try GameLibrary.merge(baseFiles: files)
        c.normalizeScenarioRecords()
        let issues = PluginLinter.lint(layer: c, effective: c)
        let errors = issues.filter { $0.severity == .error }
        XCTAssertTrue(errors.isEmpty, errors.prefix(10).map { "\($0.key) \($0.code): \($0.message)" }.joined(separator: "\n"))
    }
}
