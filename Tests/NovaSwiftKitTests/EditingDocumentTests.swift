import XCTest
@testable import NovaSwiftKit

final class EditingDocumentTests: XCTestCase {

    private let ship = NovaType.ship, outfit = NovaType.outfit, syst = NovaType.syst

    private func baseGame() -> ResourceCollection {
        var b = ResourceCollection()
        for id in 128...130 { b.add(Resource(type: ship, id: id, name: "Base \(id)", data: ResourceSchemas.schema(for: ship)!.makeDefault())) }
        var other = Resource(type: ship, id: 131, name: "From Other", data: ResourceSchemas.schema(for: ship)!.makeDefault())
        other.pluginID = "other.plugin"
        b.add(other)
        b.add(Resource(type: outfit, id: 128, name: "Base Outfit", data: ResourceSchemas.schema(for: outfit)!.makeDefault()))
        return b
    }

    private func doc() -> PluginDocument { PluginDocument(name: "Test", base: baseGame()) }

    func testProvenance() {
        let d = doc()
        XCTAssertEqual(d.provenance(ship, 128), .base)
        XCTAssertEqual(d.provenance(ship, 131), .otherPlugin("other.plugin"))
        XCTAssertNil(d.provenance(ship, 999))
        d.put(Resource(type: ship, id: 128, name: "Mine", data: Data(count: 4)))
        d.put(Resource(type: ship, id: 400, name: "New", data: Data(count: 4)))
        d.put(Resource(type: ship, id: 131, name: "Fork", data: Data(count: 4)))
        XCTAssertEqual(d.provenance(ship, 128), .override)
        XCTAssertEqual(d.provenance(ship, 400), .new)
        XCTAssertEqual(d.provenance(ship, 131), .override)
        XCTAssertEqual(d.provenance(ship, 129), .base)
        let list = d.browse(ship)
        XCTAssertEqual(list.map(\.key.id), [128, 129, 130, 131, 400])
        XCTAssertEqual(list.first?.name, "Mine")
    }

    func testEffectiveIsBaseOverlaidByLayerAndStaysInSync() {
        let d = doc()
        XCTAssertEqual(d.effective.resource(ship, 128)?.name, "Base 128")
        d.put(Resource(type: ship, id: 128, name: "Mine", data: Data([1])))
        XCTAssertEqual(d.effective.resource(ship, 128)?.name, "Mine")
        XCTAssertEqual(d.resource(ship, 129)?.name, "Base 129")
        XCTAssertEqual(d.layer.totalCount, 1)
        XCTAssertEqual(d.base.resource(ship, 128)?.name, "Base 128", "base must stay untouched")
        d.undo()
        XCTAssertEqual(d.effective.resource(ship, 128)?.name, "Base 128")
        XCTAssertEqual(d.layer.totalCount, 0)
        d.redo()
        XCTAssertEqual(d.effective.resource(ship, 128)?.name, "Mine")
        XCTAssertTrue(d.remove(ship, 128))
        XCTAssertEqual(d.effective.resource(ship, 128)?.name, "Base 128", "removing an override reveals the base")
        XCTAssertFalse(d.remove(ship, 129), "base resources can't be deleted")
    }

    func testNextFreeIDAvoidsBaseAndLayer() {
        let d = doc()
        XCTAssertEqual(d.nextFreeID(ship), 132)            // 128-131 are base
        d.put(Resource(type: ship, id: 132, data: Data()))
        d.put(Resource(type: ship, id: 133, data: Data()))
        XCTAssertEqual(d.nextFreeID(ship), 134)
        XCTAssertEqual(d.nextFreeID(ship, from: 500), 500)
        XCTAssertEqual(d.nextFreeID(NovaType.mission), 128)
        XCTAssertEqual(d.nextFreeID(ship, from: 130), 134)
    }

    func testUndoRedoAndChangeCounting() {
        let d = doc()
        var notified: [Set<ResourceKey>] = []
        d.onChange = { notified.append($0) }
        XCTAssertFalse(d.canUndo); XCTAssertFalse(d.isDirty); XCTAssertEqual(d.changeCount, 0)
        d.put(Resource(type: ship, id: 200, name: "A", data: Data([1])))
        d.put(Resource(type: ship, id: 200, name: "B", data: Data([2])))
        XCTAssertEqual(d.changeCount, 2); XCTAssertTrue(d.isDirty)
        XCTAssertEqual(notified.count, 2)
        XCTAssertEqual(notified[0], [ResourceKey(ship, 200)])
        XCTAssertTrue(d.undo())
        XCTAssertEqual(d.layerResource(ship, 200)?.name, "A")
        XCTAssertTrue(d.canRedo)
        XCTAssertTrue(d.undo())
        XCTAssertNil(d.layerResource(ship, 200))
        XCTAssertFalse(d.undo())
        XCTAssertTrue(d.redo()); XCTAssertTrue(d.redo())
        XCTAssertEqual(d.layerResource(ship, 200)?.name, "B")
        XCTAssertFalse(d.redo())
        XCTAssertEqual(notified.count, 6)          // 2 edits + 2 undos + 2 redos
        // A new edit clears the redo stack.
        d.undo()
        d.put(Resource(type: ship, id: 201, data: Data()))
        XCTAssertFalse(d.canRedo)
        // No-op edits don't pollute history.
        let before = d.changeCount
        d.put(d.layerResource(ship, 201)!)
        XCTAssertEqual(d.changeCount, before)
    }

    func testGroupsAndCoalescing() throws {
        let d = doc()
        d.withGroup("Batch") {
            d.put(Resource(type: ship, id: 300, data: Data([1])))
            d.put(Resource(type: ship, id: 301, data: Data([1])))
            d.put(Resource(type: ship, id: 300, data: Data([2])))
        }
        XCTAssertEqual(d.layer.totalCount, 2)
        d.undo()
        XCTAssertEqual(d.layer.totalCount, 0, "a group undoes as one step")
        d.redo()
        XCTAssertEqual(d.layerResource(ship, 300)?.data, Data([2]))

        // Typing into one field coalesces into a single undo step.
        let id = try d.create(ship)
        for v in [10, 20, 30, 40] { XCTAssertTrue(d.setValue(.int(v), field: "speed", of: ship, id)) }
        let schema = ResourceSchemas.schema(for: ship)!
        XCTAssertEqual(schema.read("speed", from: d.layerResource(ship, id)!.data), .int(40))
        d.undo()   // the coalesced edit
        XCTAssertEqual(schema.read("speed", from: d.layerResource(ship, id)!.data), .int(300), "back to the default speed")
        d.undo()   // the create
        XCTAssertNil(d.layerResource(ship, id))
    }

    func testSetValueCreatesOverrideFromBase() {
        let d = doc()
        XCTAssertTrue(d.setValue(.int(777), field: "speed", of: ship, 129))
        XCTAssertEqual(d.provenance(ship, 129), .override)
        XCTAssertEqual(ResourceSchemas.schema(for: ship)!.read("speed", from: d.resource(ship, 129)!.data), .int(777))
        XCTAssertEqual(ResourceSchemas.schema(for: ship)!.read("speed", from: d.base.resource(ship, 129)!.data), .int(300))
        XCTAssertFalse(d.setValue(.int(1), field: "nope", of: ship, 129))
    }

    func testDuplicateRevertAndRenumber() throws {
        let d = doc()
        let copy = try d.duplicate(ship, 128)
        XCTAssertEqual(copy, 132)
        XCTAssertEqual(d.provenance(ship, 132), .new)
        XCTAssertEqual(d.layerResource(ship, 132)?.name, "Base 128 copy")
        XCTAssertThrowsError(try d.duplicate(ship, 999))

        d.setValue(.int(1), field: "speed", of: ship, 129)
        XCTAssertTrue(d.revertToBase(ship, 129))
        XCTAssertEqual(d.provenance(ship, 129), .base)
        XCTAssertFalse(d.revertToBase(ship, 132), "new resources have no base to revert to")

        let report = try d.renumber(ship, from: 132, to: 500)
        XCTAssertEqual(report.to, ResourceKey(ship, 500))
        XCTAssertNil(d.layerResource(ship, 132)); XCTAssertNotNil(d.layerResource(ship, 500))
        XCTAssertThrowsError(try d.renumber(ship, from: 500, to: 128)) { XCTAssertEqual($0 as? PluginDocumentError, .idInUse(ResourceKey(ship, 128))) }
        XCTAssertThrowsError(try d.renumber(ship, from: 129, to: 700)) { XCTAssertEqual($0 as? PluginDocumentError, .notInPlugin(ResourceKey(ship, 129))) }
        d.undo()
        XCTAssertNotNil(d.layerResource(ship, 132)); XCTAssertNil(d.layerResource(ship, 500))
    }

    func testRenumberRewritesReferences() throws {
        let d = doc()
        // A mission that offers from, and a spöb whose weapon/links point at things we'll renumber.
        let m = try d.create(NovaType.mission)
        let ms = ResourceSchemas.schema(for: NovaType.mission)!
        d.setValue(.string("o150 & e300"), field: "availBits", of: NovaType.mission, m)
        d.setValue(.string("b1 S\(m)"), field: "onSuccess", of: NovaType.mission, m)
        d.setValue(.int(10130), field: "availStel", of: NovaType.mission, m)       // govt 130's stellars
        let w = try d.create(NovaType.weapon)
        let o = try d.create(outfit)
        d.setValue(.int(1), field: "modType", of: outfit, o)
        d.setValue(.int(w), field: "modValue", of: outfit, o)
        XCTAssertEqual(d.references.usedBy(ResourceKey(NovaType.weapon, w)).map(\.source), [ResourceKey(outfit, o)])

        let newW = 600
        let rep = try d.renumber(NovaType.weapon, from: w, to: newW, rewriteReferences: true)
        XCTAssertEqual(rep.rewritten, [ResourceKey(outfit, o)])
        let os = ResourceSchemas.schema(for: outfit)!
        XCTAssertEqual(os.read("modValue", from: d.layerResource(outfit, o)!.data), .int(newW))
        XCTAssertEqual(d.references.usedBy(ResourceKey(NovaType.weapon, newW)).count, 1)
        XCTAssertTrue(d.references.usedBy(ResourceKey(NovaType.weapon, w)).isEmpty)

        // Self-reference inside NCB survives renumbering the mission itself.
        try d.renumber(NovaType.mission, from: m, to: 650, rewriteReferences: true)
        XCTAssertEqual(ms.read("onSuccess", from: d.layerResource(NovaType.mission, 650)!.data), .string("b1 S650"))
        // One undo step reverts the move and every rewrite.
        d.undo()
        XCTAssertEqual(ms.read("onSuccess", from: d.layerResource(NovaType.mission, m)!.data), .string("b1 S\(m)"))
    }

    func testSaveAndOpenBothFormats() throws {
        let d = PluginDocument(name: "My Mod", author: "Me", version: "2.1", notes: "hi", base: baseGame())
        d.setValue(.int(555), field: "speed", of: ship, 128)
        let id = try d.create(NovaType.desc, name: "Blurb")
        d.put(Resource(type: NovaType.desc, id: id, name: "Blurb", data: DescRecord(text: "Hello").encode()))
        XCTAssertTrue(d.isDirty)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nsed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for (fmt, ext) in [(PluginFormat.rez, "rez"), (.classic, "ndat")] {
            let url = dir.appendingPathComponent("mod.\(ext)")
            try d.save(to: url, format: fmt)
            XCTAssertFalse(d.isDirty)
            let back = try PluginDocument.open(url: url, base: baseGame())
            XCTAssertEqual(back.name, "My Mod"); XCTAssertEqual(back.author, "Me")
            XCTAssertEqual(back.version, "2.1"); XCTAssertEqual(back.notes, "hi")
            XCTAssertFalse(back.isDirty)
            XCTAssertEqual(back.layer.totalCount, 2, "only the plug-in's own resources are saved")
            XCTAssertNil(back.layer.resource(ship, 129), "base data is never written by default")
            XCTAssertEqual(back.provenance(ship, 128), .override)
            XCTAssertEqual(back.layerResource(ship, 128)?.data, d.layerResource(ship, 128)?.data)
            XCTAssertEqual(DescRecord(back.layerResource(NovaType.desc, id)!.data).text, "Hello")
            d.setValue(.int(1), field: "speed", of: ship, 128)
            d.undo()   // dirty again
            XCTAssertTrue(d.isDirty)
        }

        // Full export is explicit and includes the base.
        let full = try PluginDocument.open(data: try d.exportData(format: .rez, includeBase: true))
        XCTAssertGreaterThan(full.layer.totalCount, 2)
        XCTAssertThrowsError(try d.exportFull(format: .rez, acknowledgingBaseRedistribution: false)) {
            XCTAssertEqual($0 as? PluginDocumentError, .fullExportNotConfirmed)
        }
        XCTAssertNoThrow(try d.exportFull(format: .classic, acknowledgingBaseRedistribution: true))
        // Plain export without metadata is just the layer.
        let plain = try PluginDocument.open(data: try d.exportData(format: .classic, embedMetadata: false), defaultName: "x")
        XCTAssertEqual(plain.name, "x")
        XCTAssertEqual(plain.layer.totalCount, 2)
    }

    func testMetadataEditsMarkDirtyWithoutUndo() {
        let d = doc()
        d.author = "Someone"
        XCTAssertTrue(d.isDirty)
        XCTAssertFalse(d.canUndo)
    }

    func testReferenceGraphUsedBy() throws {
        let d = doc()
        d.put(Resource(type: NovaType.shan, id: 128, data: ResourceSchemas.schema(for: NovaType.shan)!.makeDefault()))
        d.setValue(.int(1500), field: "baseSprite", of: NovaType.shan, 128)
        let refs = d.references
        XCTAssertTrue(refs.uses(ResourceKey(NovaType.shan, 128)).contains { $0.target == ResourceKey(NovaType.rleD, 1500) })
        XCTAssertEqual(refs.usedBy(ResourceKey(NovaType.rleD, 1500)).first?.fieldKey, "baseSprite")
        // The ship's companion shän is an implicit link.
        XCTAssertTrue(refs.uses(ResourceKey(ship, 128)).contains { $0.target == ResourceKey(NovaType.shan, 128) && $0.isOptional })
    }
}
