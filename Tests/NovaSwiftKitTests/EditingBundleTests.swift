import XCTest
@testable import NovaSwiftKit

/// Multi-file plug-ins and `.nsx` packs in the editor's document (source tracking + folder save).
final class EditingBundleTests: XCTestCase {

    private let ship = NovaType.ship, outfit = NovaType.outfit

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("nsbundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func res(_ t: FourCharCode, _ id: Int, _ name: String, _ bytes: [UInt8]) -> Resource {
        Resource(type: t, id: id, name: name, data: Data(bytes))
    }

    private func writeRez(_ c: ResourceCollection, to url: URL) throws {
        try RezWriter.write(c).write(to: url)
    }

    func testMultiFileOpenTracksSourcesAndKeepsShadowedResourcesOnSave() throws {
        let dsig = try XCTUnwrap(FourCharCode("dsïg"))
        let dir = try tempDir()
        var a = ResourceCollection()
        a.add(res(ship, 128, "A128", [1])); a.add(res(dsig, 128, "", [0, 0]))
        var b = ResourceCollection()
        b.add(res(ship, 128, "B128", [2])); b.add(res(ship, 129, "B129", [3])); b.add(res(dsig, 128, "", [3, 0x52, 2, 0x8A]))
        let p1 = dir.appendingPathComponent("P 1.rez"), p2 = dir.appendingPathComponent("P 2.rez")
        try writeRez(a, to: p1); try writeRez(b, to: p2)

        let layout = try XCTUnwrap(PluginBundleLoader.layout(ofFolder: dir))
        XCTAssertEqual(layout.dataFiles.map(\.lastPathComponent), ["P 1.rez", "P 2.rez"])
        XCTAssertFalse(layout.isTotalConversion)
        let loaded = try PluginBundleLoader.load(layout)
        let doc = PluginDocument.open(files: loaded.files, defaultName: "P")

        XCTAssertEqual(doc.sourceFiles, ["P 1.rez", "P 2.rez"])
        XCTAssertTrue(doc.usesFolderLayout)
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(doc.layerResource(ship, 128)?.name, "B128")            // later file wins
        XCTAssertEqual(doc.sourceFile(of: ResourceKey(ship, 128)), "P 2.rez")
        XCTAssertEqual(doc.sourceFile(of: ResourceKey(ship, 129)), "P 2.rez")
        XCTAssertEqual(doc.fileFormats["P 1.rez"], .rez)

        // Editing one resource rewrites only its file; the other stays byte-identical.
        let before1 = try Data(contentsOf: p1)
        doc.put(res(ship, 129, "B129 edited", [9]))
        XCTAssertTrue(doc.isDirty)
        let plan1 = doc.makeSavePlan()
        XCTAssertEqual(plan1.dataFiles.map(\.relativePath), ["P 2.rez"])
        try plan1.write(to: dir)
        doc.didSave(plan1)
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(try Data(contentsOf: p1), before1)
        XCTAssertEqual(try ResourceFile.read(contentsOf: p2).resource(ship, 129)?.name, "B129 edited")

        // A new resource defaults to the primary (first) file; that file keeps what B shadowed.
        doc.put(res(outfit, 500, "New", [5]))
        XCTAssertEqual(doc.sourceFile(of: ResourceKey(outfit, 500)), "P 1.rez")
        let plan2 = doc.makeSavePlan()
        XCTAssertEqual(Set(plan2.dataFiles.map(\.relativePath)), ["P 1.rez"])
        try plan2.write(to: dir)
        doc.didSave(plan2)
        let back1 = try ResourceFile.read(contentsOf: p1)
        XCTAssertEqual(back1.resource(ship, 128)?.name, "A128")               // shadowed copy preserved
        XCTAssertEqual(back1.resource(dsig, 128)?.data, Data([0, 0]))         // per-file editor signature
        XCTAssertEqual(back1.resource(outfit, 500)?.name, "New")
        XCTAssertNotNil(back1.resource(PluginDocument.metadataType, 128))     // metadata only in the primary file
        XCTAssertNil(try ResourceFile.read(contentsOf: p2).resource(PluginDocument.metadataType, 128))
        XCTAssertEqual(try ResourceFile.read(contentsOf: p2).resource(dsig, 128)?.data, Data([3, 0x52, 2, 0x8A]))
    }

    func testSetSourceFileIsUndoableAndMarksBothFiles() throws {
        let dir = try tempDir()
        var a = ResourceCollection(); a.add(res(ship, 128, "A", [1]))
        var b = ResourceCollection(); b.add(res(ship, 129, "B", [2]))
        try writeRez(a, to: dir.appendingPathComponent("A.rez")); try writeRez(b, to: dir.appendingPathComponent("B.rez"))
        let layout = try XCTUnwrap(PluginBundleLoader.layout(ofFolder: dir))
        let doc = PluginDocument.open(files: try PluginBundleLoader.load(layout).files, defaultName: "X")
        let key = ResourceKey(ship, 128)
        XCTAssertFalse(doc.setSourceFile("nope.rez", for: key))
        XCTAssertTrue(doc.setSourceFile("B.rez", for: key))
        XCTAssertEqual(doc.sourceFile(of: key), "B.rez")
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(Set(doc.makeSavePlan().dataFiles.map(\.relativePath)), ["A.rez", "B.rez"])
        XCTAssertTrue(doc.undo())
        XCTAssertEqual(doc.sourceFile(of: key), "A.rez")
        XCTAssertTrue(doc.redo())
        XCTAssertEqual(doc.sourceFile(of: key), "B.rez")
    }

    func testGraphicsPackLoadsAsNSgxAndSavesBackAsPack() throws {
        let dir = try tempDir()
        let pack = dir.appendingPathComponent("Look.nsx", isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])
        try png.write(to: pack.appendingPathComponent("a.png"))
        let manifest = GraphicsPackManifest(name: "Look", author: "me", graphics: [
            GraphicsEnhancement(kind: .sprite, sprite: 130, file: "a.png"),
            GraphicsEnhancement(kind: .sprite, sprite: 131, file: "a.png"),
        ])
        try JSONEncoder().encode(manifest).write(to: pack.appendingPathComponent(GraphicsPackManifest.fileName))

        let layout = try XCTUnwrap(PluginBundleLoader.layout(ofFolder: dir))
        XCTAssertTrue(layout.dataFiles.isEmpty)
        XCTAssertEqual(layout.graphicsPacks.map(\.lastPathComponent), ["Look.nsx"])
        let loaded = try PluginBundleLoader.load(layout)
        let doc = PluginDocument.open(files: loaded.files, defaultName: "Look")
        XCTAssertEqual(doc.sourceFiles, ["pack:Look.nsx"])
        XCTAssertEqual(doc.layer.resources(of: GraphicsEnhancementType.descriptor).map(\.id), [130, 131])
        XCTAssertEqual(doc.layer.resources(of: GraphicsEnhancementType.blob).count, 1)   // shared file, one blob
        XCTAssertEqual(doc.sourceFile(of: ResourceKey(GraphicsEnhancementType.descriptor, 130)), "pack:Look.nsx")

        // Untouched: nothing to write. Touched: the pack is rewritten as a pack, no .rez appears.
        XCTAssertTrue(doc.makeSavePlan().isEmpty)
        doc.put(res(GraphicsEnhancementType.descriptor, 130, "x", Array((try JSONEncoder().encode(
            GraphicsEnhancement(kind: .sprite, blob: doc.layer.resources(of: GraphicsEnhancementType.blob)[0].id))))))
        let plan = doc.makeSavePlan()
        XCTAssertTrue(plan.dataFiles.isEmpty)
        XCTAssertEqual(plan.packs.map(\.relativePath), ["Look.nsx"])
        try plan.write(to: dir)
        let data = try Data(contentsOf: pack.appendingPathComponent(GraphicsPackManifest.fileName))
        let written = try JSONDecoder().decode(GraphicsPackManifest.self, from: data)
        XCTAssertEqual(written.author, "me")                                   // details carried over
        XCTAssertEqual(written.graphics.compactMap(\.sprite).sorted(), [130, 131])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Look.rez").path))

        // "Embed HD in plug-in file": NSgx/NSbl go to a data file, the pack isn't written.
        let embedded = doc.makeSavePlan(embedPacksInFile: true)
        XCTAssertTrue(embedded.packs.isEmpty)
        XCTAssertEqual(embedded.dataFiles.count, 1)
        XCTAssertEqual(embedded.dataFiles[0].collection.resources(of: GraphicsEnhancementType.descriptor).count, 2)
        XCTAssertEqual(embedded.dataFiles[0].collection.resources(of: GraphicsEnhancementType.blob).count, 1)
    }

    func testTotalConversionLayoutUsesItsOwnNovaFilesThenPlugIns() throws {
        let dir = try tempDir()
        let nova = dir.appendingPathComponent("Nova Files", isDirectory: true)
        let plug = dir.appendingPathComponent("Plug-Ins", isDirectory: true)
        try FileManager.default.createDirectory(at: nova, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plug, withIntermediateDirectories: true)
        var c = ResourceCollection(); c.add(res(ship, 128, "TC ship", [1]))
        try writeRez(c, to: nova.appendingPathComponent("TC Data.rez"))
        var p = ResourceCollection(); p.add(res(ship, 128, "Patched", [2]))
        try writeRez(p, to: plug.appendingPathComponent("Patch.rez"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("Readme.txt"))

        let layout = try XCTUnwrap(PluginBundleLoader.layout(ofFolder: dir))
        XCTAssertTrue(layout.isTotalConversion)
        XCTAssertEqual(layout.dataFiles.map(\.lastPathComponent), ["TC Data.rez", "Patch.rez"])
        XCTAssertEqual(layout.novaFiles.map(\.lastPathComponent), ["TC Data.rez"])
        XCTAssertEqual(layout.otherFiles.map(\.lastPathComponent), ["Readme.txt"])
        let doc = PluginDocument.open(files: try PluginBundleLoader.load(layout).files, defaultName: "TC")
        XCTAssertEqual(doc.sourceFiles, ["Nova Files/TC Data.rez", "Plug-Ins/Patch.rez"])
        XCTAssertTrue(doc.base.byType.isEmpty)                                 // never the stock game
        XCTAssertEqual(doc.layerResource(ship, 128)?.name, "Patched")

        doc.put(res(ship, 128, "Patched twice", [3]))
        try doc.makeSavePlan().write(to: dir)
        XCTAssertEqual(try ResourceFile.read(contentsOf: plug.appendingPathComponent("Patch.rez")).resource(ship, 128)?.name, "Patched twice")
        XCTAssertEqual(try ResourceFile.read(contentsOf: nova.appendingPathComponent("TC Data.rez")).resource(ship, 128)?.name, "TC ship")
    }

    func testEditorSignatureTypeIsRegisteredAsRaw() throws {
        let dsig = try XCTUnwrap(FourCharCode("dsïg"))
        XCTAssertEqual(ResourceSchemas.displayName(for: dsig), "Editor Signature")
        XCTAssertEqual(ResourceSchemas.editorKind(for: dsig), .raw)
    }
}
