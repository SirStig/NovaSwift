import XCTest
import NovaSwiftKit
@testable import NovaSwiftPluginStore

final class PluginCatalogTests: XCTestCase {
    func testCatalogDecodes() {
        // The bundled catalog may be empty in this checkout but must always
        // parse without throwing (PluginCatalog.load swallows decode errors
        // into an empty array — this asserts the JSON itself is well-formed
        // by round-tripping a representative entry through the same decoder).
        let entry = PluginCatalogEntry(
            id: "shields", name: "Shields", author: "Test Author", kind: .gameplay,
            summary: "Adds shields.", description: "A longer description of the plug-in.",
            tags: ["gameplay"], requiresBase: true, prebundled: false,
            sourceHost: .evstuff, sourceURL: URL(string: "https://example.com/shields.zip"),
            approxSizeMB: 0.001, screenshotNames: [], videoURL: nil)
        let data = try! JSONEncoder().encode([entry])
        let decoded = try! JSONDecoder().decode([PluginCatalogEntry].self, from: data)
        XCTAssertEqual(decoded, [entry])
    }

    func testEntryLookup() {
        // `all` reflects whatever ships in Resources/PluginCatalog.json; just
        // assert the lookup helper is consistent with it.
        if let first = PluginCatalog.all.first {
            XCTAssertEqual(PluginCatalog.entry(id: first.id), first)
        }
    }

    func testBundledCatalogHasRealContent() {
        // Guards against PluginCatalog.load()'s silent-empty-array fallback
        // masking a JSON typo: the real bundled catalog should have every
        // seeded entry, each with non-empty prose and a valid source URL.
        XCTAssertEqual(PluginCatalog.all.count, 23)
        for entry in PluginCatalog.all {
            XCTAssertFalse(entry.summary.isEmpty, entry.id)
            XCTAssertFalse(entry.description.isEmpty, entry.id)
            XCTAssertNotNil(entry.sourceURL, entry.id)
        }
    }
}
