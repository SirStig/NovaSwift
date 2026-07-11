import XCTest
@testable import NovaSwiftPluginStore

final class PluginInstallerTests: XCTestCase {
    private func makeFixtureZip() throws -> URL {
        // Build a tiny real zip on disk (via `zip` on the test host) containing
        // one file nested inside an arbitrary top-level folder, to prove the
        // installer ignores the archive's internal folder name.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inner = tmp.appendingPathComponent("SomeOtherName/Nova Files", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("fake resource bytes".utf8).write(to: inner.appendingPathComponent("Data.rez"))

        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-qr", zipURL.path, "SomeOtherName"]
        process.currentDirectoryURL = tmp
        try process.run()
        process.waitUntilExit()
        return zipURL
    }

    func testInstallExtractsUnderCatalogID() throws {
        let zipURL = try makeFixtureZip()
        let destRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destRoot) }

        let installedDir = try PluginInstaller.install(archiveAt: zipURL, id: "shields", into: destRoot)

        XCTAssertEqual(installedDir, destRoot.appendingPathComponent("shields", isDirectory: true))
        XCTAssertTrue(PluginInstaller.isInstalled(id: "shields", in: destRoot))
        // The archive's own "SomeOtherName" folder name must not leak into the id.
        let nested = installedDir.appendingPathComponent("SomeOtherName/Nova Files/Data.rez")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func testDeleteRefusesPrebundled() throws {
        let destRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try PluginInstaller.delete(id: "anything", from: destRoot, prebundled: true))
    }

    func testDeleteRemovesInstalled() throws {
        let zipURL = try makeFixtureZip()
        let destRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destRoot) }

        _ = try PluginInstaller.install(archiveAt: zipURL, id: "shields", into: destRoot)
        try PluginInstaller.delete(id: "shields", from: destRoot, prebundled: false)
        XCTAssertFalse(PluginInstaller.isInstalled(id: "shields", in: destRoot))
    }
}
