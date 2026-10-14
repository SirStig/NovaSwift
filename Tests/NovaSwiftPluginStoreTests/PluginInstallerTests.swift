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

    // MARK: Hostile archives (zip-slip, symlinks, bombs)

    private func pythonZip(_ body: String) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", "-c", "import zipfile,sys\nz=zipfile.ZipFile(sys.argv[1],'w')\n" + body + "\nz.close()", out.path]
        try p.run(); p.waitUntilExit()
        return out
    }

    func testZipSlipPathIsRefusedAndNothingEscapes() throws {
        let zip = try pythonZip("z.writestr('../escaped.rez', b'x'*2000)\nz.writestr('ok.rez', b'y'*2000)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try PluginInstaller.install(archiveAt: zip, id: "evil", into: root)) { e in
            guard case PluginInstallError.unsafeArchive = e else { return XCTFail("\(e)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.rez").path))
        XCTAssertFalse(PluginInstaller.isInstalled(id: "evil", in: root))
    }

    func testAbsolutePathsAndSymlinksAreRefused() throws {
        let abs = try pythonZip("z.writestr('/tmp/abs.rez', b'x')")
        XCTAssertThrowsError(try PluginInstaller.validateZip(at: abs))
        let link = try pythonZip("i=zipfile.ZipInfo('link.rez'); i.create_system=3; i.external_attr=(0o120777<<16); z.writestr(i,'/etc/passwd')")
        XCTAssertThrowsError(try PluginInstaller.validateZip(at: link))
    }

    func testTooManyEntriesAreRefused() throws {
        let many = try pythonZip("for i in range(\(PluginInstaller.maxZipEntries + 5)): z.writestr('f%d.rez' % i, b'')")
        XCTAssertThrowsError(try PluginInstaller.validateZip(at: many))
    }

    func testNormalZipPassesValidation() throws {
        let ok = try pythonZip("z.writestr('Folder/a.rez', b'x'*100)")
        XCTAssertNoThrow(try PluginInstaller.validateZip(at: ok))
    }
}
