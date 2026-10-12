import XCTest
import Foundation
@testable import NovaSwiftKit

/// Renumber-with-companions, off-main export snapshots, and copying a bundle's other files.
final class EditingGapsTests: XCTestCase {

    private let ship = NovaType.ship, shan = NovaType.shan, pict = NovaType.pict

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("nsgaps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func shipDoc() -> PluginDocument {
        let d = PluginDocument()
        d.put(Resource(type: ship, id: 130, name: "S", data: ResourceSchemas.schema(for: ship)!.makeDefault()))
        d.put(Resource(type: shan, id: 130, name: "Sh", data: Data([1, 2, 3])))
        d.put(Resource(type: pict, id: 2872 + 130, name: "Target", data: Data([9])))
        return d
    }

    func testRenumberReportsCompanionsByDefault() throws {
        let d = shipDoc()
        let r = try d.renumber(ship, from: 130, to: 140)
        XCTAssertTrue(r.implicitRelatives.contains(ResourceKey(shan, 130)))
        XCTAssertTrue(r.implicitRelatives.contains(ResourceKey(pict, 3002)))
        XCTAssertTrue(r.movedCompanions.isEmpty)
        XCTAssertNotNil(d.layerResource(shan, 130))
    }

    func testRenumberMovesCompanionsInOneUndoStep() throws {
        let d = shipDoc()
        let plan = d.companionPlan(ship, from: 130, to: 140)
        XCTAssertEqual(plan.filter(\.movable).map(\.to), [ResourceKey(shan, 140), ResourceKey(pict, 3012)])

        let r = try d.renumber(ship, from: 130, to: 140, rewriteReferences: true, moveCompanions: true)
        XCTAssertEqual(Set(r.movedCompanions), [ResourceKey(shan, 130), ResourceKey(pict, 3002)])
        XCTAssertTrue(r.implicitRelatives.isEmpty)
        XCTAssertNil(d.layerResource(shan, 130)); XCTAssertEqual(d.layerResource(shan, 140)?.data, Data([1, 2, 3]))
        XCTAssertNil(d.layerResource(pict, 3002)); XCTAssertEqual(d.layerResource(pict, 3012)?.name, "Target")
        XCTAssertNotNil(d.layerResource(ship, 140))

        XCTAssertTrue(d.undo())
        XCTAssertNotNil(d.layerResource(ship, 130)); XCTAssertNotNil(d.layerResource(shan, 130))
        XCTAssertNotNil(d.layerResource(pict, 3002))
        XCTAssertNil(d.layerResource(shan, 140)); XCTAssertNil(d.layerResource(pict, 3012))
    }

    func testBlockedCompanionStaysPut() throws {
        let d = shipDoc()
        d.put(Resource(type: shan, id: 140, name: "Occupied", data: Data([7])))     // target taken
        let plan = d.companionPlan(ship, from: 130, to: 140)
        XCTAssertEqual(plan.first { $0.from == ResourceKey(shan, 130) }?.blockedReason, "target id in use")
        let r = try d.renumber(ship, from: 130, to: 140, moveCompanions: true)
        XCTAssertEqual(r.blockedCompanions, [ResourceKey(shan, 130)])
        XCTAssertEqual(r.movedCompanions, [ResourceKey(pict, 3002)])
        XCTAssertNotNil(d.layerResource(shan, 130))
        XCTAssertEqual(d.layerResource(shan, 140)?.name, "Occupied")
    }

    func testExportJobMatchesExportData() throws {
        let d = shipDoc()
        d.name = "Job Test"
        let job = d.makeExportJob(format: .rez)
        let a = try job.encode(), b = try d.exportData(format: .rez)
        XCTAssertEqual(a, b)
        let back = try PluginDocument.open(data: a)
        XCTAssertEqual(back.name, "Job Test")
        XCTAssertNotNil(back.layerResource(shan, 130))

        // Dirty tracking: markSaved(atChangeCount:) only covers edits up to the snapshot.
        XCTAssertTrue(d.isDirty)
        d.markSaved(atChangeCount: job.changeCount)
        XCTAssertFalse(d.isDirty)
        d.put(Resource(type: pict, id: 200, name: "later", data: Data([1])))
        XCTAssertTrue(d.isDirty)

        // Excluding HD drops the NSgx/NSbl layers; everything else stays.
        d.put(Resource(type: GraphicsEnhancementType.descriptor, id: 5, name: "hd", data: Data([1])))
        let plain = try PluginDocument.open(data: try d.makeExportJob(format: .rez, embedMetadata: false, excludeHD: true).encode())
        XCTAssertNil(plain.layerResource(GraphicsEnhancementType.descriptor, 5))
        XCTAssertNotNil(plain.layerResource(pict, 200))
    }

    func testFullExportJobIncludesBase() throws {
        var base = ResourceCollection()
        base.add(Resource(type: ship, id: 128, name: "Base", data: Data([1])))
        let d = PluginDocument(base: base)
        d.put(Resource(type: ship, id: 129, name: "Mine", data: Data([2])))
        let full = try PluginDocument.open(data: try d.makeExportJob(format: .rez, includeBase: true).encode())
        XCTAssertNotNil(full.layerResource(ship, 128)); XCTAssertNotNil(full.layerResource(ship, 129))
        let lean = try PluginDocument.open(data: try d.makeExportJob(format: .rez).encode())
        XCTAssertNil(lean.layerResource(ship, 128))
    }

    func testCopyBundleFilesKeepsRelativePathsAndNeverOverwrites() throws {
        let src = try tempDir(), dst = try tempDir()
        let fm = FileManager.default
        try fm.createDirectory(at: src.appendingPathComponent("Music/Sub"), withIntermediateDirectories: true)
        let files = [src.appendingPathComponent("readme.txt"), src.appendingPathComponent("Music/Sub/song.mp3"),
                     src.appendingPathComponent("Music/missing.mp3")]
        try Data("hi".utf8).write(to: files[0]); try Data("mp3".utf8).write(to: files[1])
        // Pre-existing destination file must survive.
        try Data("keep".utf8).write(to: dst.appendingPathComponent("readme.txt"))

        let r = PluginBundleLoader.copyBundleFiles(files, from: src, to: dst)
        XCTAssertEqual(r.copiedCount, 1)
        XCTAssertEqual(r.failed.count, 1)
        XCTAssertEqual(r.present.map { PluginBundleLoader.relativePath($0, from: dst) }, ["readme.txt", "Music/Sub/song.mp3"])
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("readme.txt")), "keep")
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("Music/Sub/song.mp3")), "mp3")
        // Same folder: nothing to do, nothing copied.
        let same = PluginBundleLoader.copyBundleFiles([files[0]], from: src, to: src)
        XCTAssertEqual(same.copiedCount, 0); XCTAssertEqual(same.present.count, 1)
    }

    func testRestoreFlagsMarkAllSourcesModified() throws {
        let dir = try tempDir()
        var a = ResourceCollection(); a.add(Resource(type: ship, id: 128, name: "A", data: Data([1])))
        var b = ResourceCollection(); b.add(Resource(type: ship, id: 129, name: "B", data: Data([2])))
        try RezWriter.write(a).write(to: dir.appendingPathComponent("A.rez"))
        try RezWriter.write(b).write(to: dir.appendingPathComponent("B.rez"))
        let layout = try XCTUnwrap(PluginBundleLoader.layout(ofFolder: dir))
        let doc = PluginDocument.open(files: try PluginBundleLoader.load(layout).files, defaultName: "X")
        XCTAssertTrue(doc.makeSavePlan().isEmpty)
        doc.markAllSourcesModified()
        XCTAssertEqual(Set(doc.makeSavePlan().dataFiles.map(\.relativePath)), ["A.rez", "B.rez"])
    }
}
