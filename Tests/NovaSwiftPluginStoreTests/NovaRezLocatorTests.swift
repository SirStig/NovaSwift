import XCTest
import Foundation
@testable import NovaSwiftPluginStore
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

/// `NovaRezLocator` against the real dialog archive (skipped without local data).
final class NovaRezLocatorTests: XCTestCase {
    private var realNovaRez: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("data/EV Nova/Nova.rez")
    }

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("rezloc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    /// A WineNova install: `EV Nova/` holds Nova Files and EV Nova.app, and
    /// Nova.rez exists only inside the app's SharedSupport.zip.
    func testFindsNovaRezInsideAWineNovaApp() throws {
        #if canImport(ZIPFoundation)
        guard FileManager.default.fileExists(atPath: realNovaRez.path) else {
            throw XCTSkip("no local data/EV Nova/Nova.rez")
        }
        let root = try tempDir().appendingPathComponent("EV Nova")
        let staging = try tempDir()
        let inner = staging.appendingPathComponent("SharedSupport/prefix/drive_c/Program Files/EV Nova")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: realNovaRez, to: inner.appendingPathComponent("Nova.rez"))
        let zips = root.appendingPathComponent("EV Nova.app/Contents/Resources/Zips")
        try FileManager.default.createDirectory(at: zips, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Nova Files"),
                                                withIntermediateDirectories: true)
        try FileManager().zipItem(at: staging.appendingPathComponent("SharedSupport"),
                                  to: zips.appendingPathComponent("SharedSupport.zip"))

        let found = try XCTUnwrap(NovaRezLocator.locate(in: root))
        XCTAssertEqual(found.lastPathComponent, "Nova.rez")
        XCTAssertTrue(NovaRezLocator.holdsDialogs(found))
        #else
        throw XCTSkip("no zip support on this platform")
        #endif
    }

    /// A Windows import of just Nova Files: Nova.rez is one folder up.
    func testFindsNovaRezBesideAPickedNovaFilesFolder() throws {
        guard FileManager.default.fileExists(atPath: realNovaRez.path) else {
            throw XCTSkip("no local data/EV Nova/Nova.rez")
        }
        let game = try tempDir()
        let novaFiles = game.appendingPathComponent("Nova Files")
        try FileManager.default.createDirectory(at: novaFiles, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: realNovaRez, to: game.appendingPathComponent("Nova.rez"))
        XCTAssertEqual(NovaRezLocator.locate(in: novaFiles)?.lastPathComponent, "Nova.rez")
    }

    /// The original Mac release: a classic app file whose resources (the
    /// dialogs) are in its resource fork. They come out as a plain Nova.rez.
    func testFindsDialogsInAClassicAppResourceFork() throws {
        #if os(macOS)
        guard FileManager.default.fileExists(atPath: realNovaRez.path) else {
            throw XCTSkip("no local data/EV Nova/Nova.rez")
        }
        let root = try tempDir()
        let app = root.appendingPathComponent("EV Nova")
        try Data().write(to: app)
        try Data(contentsOf: realNovaRez).write(to: app.appendingPathComponent("..namedfork/rsrc"))
        let found = try XCTUnwrap(NovaRezLocator.locate(in: root))
        XCTAssertEqual(found.lastPathComponent, "Nova.rez")
        XCTAssertNotEqual(found.deletingLastPathComponent(), root)
        XCTAssertTrue(NovaRezLocator.holdsDialogs(found))
        #else
        throw XCTSkip("resource forks are macOS-only")
        #endif
    }

    /// A file that merely carries the name is not taken for the dialogs.
    func testRejectsAFileWithoutDialogs() throws {
        let f = try tempDir().appendingPathComponent("Nova.rez")
        try Data("not a resource file".utf8).write(to: f)
        XCTAssertFalse(NovaRezLocator.holdsDialogs(f))
    }
}
