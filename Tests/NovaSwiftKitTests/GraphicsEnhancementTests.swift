import XCTest
import Foundation
@testable import NovaSwiftKit

final class GraphicsEnhancementTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("novaswift-gx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func json(_ e: GraphicsEnhancement) -> Data { try! JSONEncoder().encode(e) }

    private func write(_ data: Data, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func pack(_ path: String, _ entries: [GraphicsEnhancement], files: [String: Data]) throws -> URL {
        let manifest = GraphicsPackManifest(name: "Test", graphics: entries)
        _ = try write(try JSONEncoder().encode(manifest), path + "/manifest.json")
        for (name, data) in files { _ = try write(data, path + "/" + name) }
        return root.appendingPathComponent(path)
    }

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])

    // MARK: Rez writer

    func testRezWriterRoundTrips() throws {
        var c = ResourceCollection()
        c.add(Resource(type: GraphicsEnhancementType.descriptor, id: 1010, name: "HD courier",
                       data: json(GraphicsEnhancement(kind: .model, blob: 30000))))
        c.add(Resource(type: GraphicsEnhancementType.blob, id: 30000, name: "courier.usdz", data: Data(repeating: 7, count: 5000)))
        c.add(Resource(type: NovaType.ship, id: 128, name: "Shüttle", data: Data([1, 2, 3])))
        let bytes = RezWriter.write(c)
        XCTAssertEqual(ResourceFile.detectFormat(bytes), .rez)
        let back = try ResourceFile.read(bytes)
        XCTAssertEqual(back.totalCount, 3)
        for type in c.types {
            for r in c.resources(of: type) {
                let got = try XCTUnwrap(back.resource(type, r.id))
                XCTAssertEqual(got.data, r.data)
                XCTAssertEqual(got.name, r.name)
            }
        }
    }

    /// A real shipping plug-in re-written by `RezWriter` parses to the same
    /// resources (skipped when the local data isn't present).
    func testRezWriterMatchesRealPlugin() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("data/plugins/Collision Damage.rez")
        guard let original = try? Data(contentsOf: url) else { throw XCTSkip("no local plug-in data") }
        let parsed = try ResourceFile.read(original)
        let rewritten = RezWriter.write(parsed)
        // Same header shape as the shipping file: headerLength and entry count.
        XCTAssertEqual(rewritten.prefix(24), original.prefix(24))
        let again = try ResourceFile.read(rewritten)
        XCTAssertEqual(again.totalCount, parsed.totalCount)
        for type in parsed.types {
            for r in parsed.resources(of: type) { XCTAssertEqual(again.resource(type, r.id)?.data, r.data) }
        }
    }

    // MARK: Catalog

    func testInFileDescriptorUsesItsBlob() {
        var c = ResourceCollection()
        c.add(Resource(type: GraphicsEnhancementType.descriptor, id: 2002,
                       data: json(GraphicsEnhancement(kind: .sprite, blob: 30001, scale: 4))))
        c.add(Resource(type: GraphicsEnhancementType.blob, id: 30001, data: png))
        c.add(Resource(type: GraphicsEnhancementType.descriptor, id: 2003,
                       data: json(GraphicsEnhancement(kind: .sprite, blob: 39999))))
        c.add(Resource(type: GraphicsEnhancementType.descriptor, id: 2004, data: Data("not json".utf8)))
        var cat = GraphicsEnhancementCatalog()
        cat.addInFile(from: c)
        XCTAssertEqual(cat[2002]?.source, .blob(png))
        XCTAssertEqual(cat[2002]?.descriptor.sprite, 2002)
        XCTAssertEqual(cat[2002]?.descriptor.effectiveScale, 4)
        XCTAssertEqual(cat[2002]?.source.fileExtension, "png")
        XCTAssertNil(cat[2003])
        XCTAssertNil(cat[2004])
        XCTAssertEqual(cat.problems.count, 2)
    }

    func testSidecarRejectsMissingAndEscapingFiles() throws {
        let p = try pack("Packs/Demo.nsx", [
            GraphicsEnhancement(kind: .sprite, sprite: 1, file: "a.png"),
            GraphicsEnhancement(kind: .sprite, sprite: 2, file: "missing.png"),
            GraphicsEnhancement(kind: .sprite, sprite: 3, file: "../outside.png"),
            GraphicsEnhancement(kind: .sprite, file: "a.png"),
        ], files: ["a.png": png])
        _ = try write(png, "Packs/outside.png")
        var cat = GraphicsEnhancementCatalog()
        cat.addSidecar(p, origin: "Demo")
        XCTAssertNotNil(cat[1])
        XCTAssertNil(cat[2])
        XCTAssertNil(cat[3])
        XCTAssertEqual(cat.problems.count, 3)
    }

    func testDefaults() {
        let model = GraphicsEnhancement(kind: .model)
        XCTAssertTrue(model.hidesClassicOverlays)
        XCTAssertTrue(model.allowsLive)
        let sprite = GraphicsEnhancement(kind: .sprite)
        XCTAssertFalse(sprite.hidesClassicOverlays)
        XCTAssertFalse(sprite.allowsLive)
        XCTAssertEqual(sprite.effectiveScale, 2)
        XCTAssertEqual(sprite.effectiveColumns, 6)
    }

    func testEffectLayersAndEmittersDecode() throws {
        let json = """
        { "kind": "model", "sprite": 1010, "file": "s.usdz",
          "layers": { "engine": ["Nozzle"] },
          "effects": [ { "layer": "engine", "at": [0.1, 0, -0.9], "radius": 0.08, "color": [0.6, 0.8, 1] },
                       { "layer": "lights", "at": [0.6, 0, -0.5] } ] }
        """
        let d = try JSONDecoder().decode(GraphicsEnhancement.self, from: Data(json.utf8))
        XCTAssertEqual(d.nameMatches(.engine), ["nozzle"])                       // override, lowercased
        XCTAssertEqual(d.nameMatches(.lights), ["light", "beacon", "nav_"])      // default
        XCTAssertEqual(d.effects?.count, 2)
        XCTAssertEqual(d.effects?.first?.layer, .engine)
        XCTAssertNil(d.effects?.last?.radius)
        XCTAssertThrowsError(try JSONDecoder().decode(GraphicsEnhancement.self, from: Data(
            #"{ "kind": "model", "effects": [ { "layer": "smoke", "at": [0,0,0] } ] }"#.utf8)))
    }

    /// Owned packs follow their plug-in's switch and load order; standalone
    /// packs apply last; a later layer wins the same sprite id.
    func testCatalogLayering() throws {
        let plugins = root.appendingPathComponent("Plug-ins")
        // Loose plug-in "Alpha.rez" with a sibling "Alpha.nsx".
        let alpha = try write(RezWriter.write(ResourceCollection()), "Plug-ins/Alpha.rez")
        _ = try pack("Plug-ins/Alpha.nsx", [GraphicsEnhancement(kind: .sprite, sprite: 10, file: "a.png"),
                                           GraphicsEnhancement(kind: .sprite, sprite: 11, file: "a.png")],
                     files: ["a.png": png])
        // Folder plug-in "Beta" whose pack overrides sprite 10.
        let beta = try write(RezWriter.write(ResourceCollection()), "Plug-ins/Beta/Beta.rez")
        _ = try pack("Plug-ins/Beta/Beta HD.nsx", [GraphicsEnhancement(kind: .model, sprite: 10, file: "b.usdz")],
                     files: ["b.usdz": Data([0x50, 0x4B, 0x03, 0x04])])
        // Standalone pack overriding sprite 11.
        _ = try pack("Plug-ins/Zeta.nsx", [GraphicsEnhancement(kind: .sprite, sprite: 11, file: "z.png")],
                     files: ["z.png": png])

        let packs = GameLibrary.discoverGraphicsPacks(in: [plugins])
        XCTAssertEqual(packs.map(\.lastPathComponent), ["Alpha.nsx", "Beta HD.nsx", "Zeta.nsx"])

        let bundles = [
            PluginBundle(id: "Alpha.rez", name: "Alpha", fileURLs: [alpha], isEnabled: true),
            PluginBundle(id: "Beta", name: "Beta", fileURLs: [beta], isEnabled: true),
        ]
        let cat = GameLibrary.graphicsCatalog(resources: ResourceCollection(), plugins: bundles, graphicsPacks: packs)
        XCTAssertEqual(cat[10]?.descriptor.kind, .model)        // Beta loads after Alpha
        XCTAssertEqual(cat[10]?.origin, "Beta")
        XCTAssertEqual(cat[11]?.origin, "Zeta.nsx")            // standalone applies last

        var betaOff = bundles; betaOff[1].isEnabled = false
        let cat2 = GameLibrary.graphicsCatalog(resources: ResourceCollection(), plugins: betaOff, graphicsPacks: packs)
        XCTAssertEqual(cat2[10]?.origin, "Alpha.rez")
        XCTAssertEqual(cat2[10]?.descriptor.kind, .sprite)
    }

    /// The original never descends into folders and only loads resource
    /// files, so a `.nsx` pack never shows up as (or inside) a plug-in.
    func testPacksAreNotPlugins() throws {
        _ = try write(RezWriter.write(ResourceCollection()), "Plug-ins/Alpha.rez")
        _ = try pack("Plug-ins/Alpha.nsx", [GraphicsEnhancement(kind: .sprite, sprite: 10, file: "a.png")],
                     files: ["a.png": png])
        let found = GameLibrary.discoverPlugins(in: root.appendingPathComponent("Plug-ins"))
        XCTAssertEqual(found.map(\.id), ["Alpha.rez"])
    }

    func testSpriteLoaderTagsSourceID() throws {
        var c = ResourceCollection()
        // 1×1, 1-frame, 16-bit rlëD: header, line start, one pixel, EOF.
        var rle = Data()
        func be16(_ v: Int) { rle.append(UInt8((v >> 8) & 0xFF)); rle.append(UInt8(v & 0xFF)) }
        be16(1); be16(1); be16(16); be16(0); be16(1); rle.append(contentsOf: [UInt8](repeating: 0, count: 6))
        rle.append(contentsOf: [0x01, 0, 0, 4, 0x02, 0, 0, 2, 0x7F, 0xFF, 0, 0, 0x00, 0, 0, 0])
        c.add(Resource(type: NovaType.rleD, id: 4242, data: rle))
        let game = NovaGame(c)
        let sheet = try XCTUnwrap(game.spriteSheet(spriteID: 4242, maskID: 0, frameWidth: 0, frameHeight: 0, frameCount: 0))
        XCTAssertEqual(sheet.sourceSpriteID, 4242)
    }
}
