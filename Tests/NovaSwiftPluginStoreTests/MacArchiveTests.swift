import XCTest
@testable import NovaSwiftPluginStore

final class MacArchiveTests: XCTestCase {
    private let sampleData: [UInt8] = Array("plain data fork ".utf8) + [0x90, 0x90, 0x90, 0, 1, 2]
    private var sampleRsrc: [UInt8] {
        (0..<3000).map { UInt8(truncatingIfNeeded: ($0 * 7) ^ ($0 >> 3)) } + [UInt8](repeating: 0x41, count: 500)
    }

    private func rle(_ a: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []; var i = 0
        while i < a.count {
            var n = 1
            while i + n < a.count, a[i + n] == a[i], n < 255 { n += 1 }
            if a[i] == 0x90 { for _ in 0..<n { out += [0x90, 0] } }
            else if n >= 4 { out += [a[i], 0x90, UInt8(n)] }
            else { out += [UInt8](repeating: a[i], count: n) }
            i += n
        }
        return out
    }

    func testBinHexRoundTrip() throws {
        let f = MacFile(name: "My Plug", fileType: "rsrc", creator: "NOVA", data: sampleData, rsrc: sampleRsrc)
        let hqx = BinHex.encode(f, name: f.name)
        let back = try MacArchive.extract(Data(hqx), name: "x.hqx")
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].name, f.name)
        XCTAssertEqual(back[0].data, sampleData)
        XCTAssertEqual(back[0].rsrc, sampleRsrc)
        XCTAssertEqual(back[0].fileType, "rsrc")
    }

    func testMacBinaryRoundTrip() throws {
        let f = MacFile(name: "Thing", fileType: "rsrc", creator: "NOVA", data: sampleData, rsrc: sampleRsrc)
        let bin = MacBinary.encode(f, name: "Thing")
        let back = try MacArchive.extract(Data(bin), name: "Thing.bin")
        XCTAssertEqual(back.first?.data, sampleData)
        XCTAssertEqual(back.first?.rsrc, sampleRsrc)
    }

    func testStuffItMethods0And1WithFolders() throws {
        let sit = StuffIt.buildClassic([
            (name: "Plug", rsrcMethod: 0, rsrc: sampleRsrc, rsrcPacked: sampleRsrc,
             dataMethod: 1, data: sampleData, dataPacked: rle(sampleData)),
        ], folderNames: ["Folder"])
        let files = try MacArchive.extract(Data(sit), name: "a.sit")
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files[0].isFolder)
        XCTAssertEqual(files[1].folders, ["Folder"])
        XCTAssertEqual(files[1].rsrc, sampleRsrc)
        XCTAssertEqual(files[1].data, sampleData)
    }

    func testStuffItLZWMatchesSystemCompress() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/compress") else { throw XCTSkip("no compress") }
        // Enough varied data to cross 9 -> 14 bit code widths and the table-full state.
        var big: [UInt8] = []
        var x: UInt32 = 12345
        for i in 0..<120_000 {
            x = x &* 1664525 &+ 1013904223
            big.append(i % 5 == 0 ? UInt8(x >> 24) : UInt8(truncatingIfNeeded: (i / 3) % 40))
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("blob")
        try Data(big).write(to: src)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/compress")
        p.arguments = ["-b", "14", src.path]
        try p.run(); p.waitUntilExit()
        let z = [UInt8](try Data(contentsOf: dir.appendingPathComponent("blob.Z")))
        XCTAssertEqual(Array(z[0..<2]), [0x1F, 0x9D])
        let packed = Array(z[3...])
        let sit = StuffIt.buildClassic([(name: "Big", rsrcMethod: 0, rsrc: [], rsrcPacked: [],
                                         dataMethod: 2, data: big, dataPacked: packed)])
        let files = try MacArchive.extract(Data(sit), name: "a.sit")
        XCTAssertEqual(files.first?.data, big)
    }

    private func byteBits(_ v: Int) -> [Int] { (0..<8).map { (v >> (7 - $0)) & 1 } }

    func testStuffItHuffman() throws {
        // Tree: a=0, b=10, c=11 (bit 1 = leaf + 8-bit value, 0 = node; MSB-first).
        var bits: [Int] = [0, 1] + byteBits(0x61) + [0, 1] + byteBits(0x62) + [1] + byteBits(0x63)
        let text = Array("abcabcaabbcc".utf8)
        for c in text { bits += c == 0x61 ? [0] : c == 0x62 ? [1, 0] : [1, 1] }
        var packed = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
        for (i, b) in bits.enumerated() where b == 1 { packed[i / 8] |= UInt8(0x80 >> (i % 8)) }
        let sit = StuffIt.buildClassic([(name: "H", rsrcMethod: 0, rsrc: [], rsrcPacked: [],
                                         dataMethod: 3, data: text, dataPacked: packed)])
        XCTAssertEqual(try MacArchive.extract(Data(sit)).first?.data, text)
    }

    func testNestedHqxOfSitInstallsForkAsNdat() throws {
        let sit = StuffIt.buildClassic([
            (name: "Cool Plug", rsrcMethod: 0, rsrc: sampleRsrc, rsrcPacked: sampleRsrc, dataMethod: 0, data: [], dataPacked: []),
            (name: "Read Me", rsrcMethod: 0, rsrc: [], rsrcPacked: [], dataMethod: 0, data: Array("hi".utf8), dataPacked: Array("hi".utf8)),
        ], folderNames: ["Nova Files"])
        let hqx = BinHex.encode(MacFile(name: "Cool.sit", fileType: "SIT!", creator: "SIT!", data: sit), name: "Cool.sit")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("dl.tmp")
        try Data(hqx).write(to: file)
        let root = tmp.appendingPathComponent("plugins")
        let dir = try PluginInstaller.install(archiveAt: file, id: "cool", into: root, originalName: "Cool.sit.hqx")
        let ndat = dir.appendingPathComponent("Nova Files/Cool Plug.ndat")
        XCTAssertEqual([UInt8](try Data(contentsOf: ndat)), sampleRsrc)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Nova Files/Read Me").path))
    }

    func testStuffIt5ContainerWithFolderAndForks() throws {
        let sit = StuffIt.buildV5(folder: "Nova Files", files: [
            (name: "Plug", data: sampleData, rsrc: sampleRsrc),
            (name: "Notes", data: Array("read me".utf8), rsrc: []),
        ])
        let files = try MacArchive.extract(Data(sit), name: "p.sit")
        XCTAssertEqual(files.count, 3)
        XCTAssertTrue(files[0].isFolder)
        XCTAssertEqual(files[1].folders, ["Nova Files"])
        XCTAssertEqual(files[1].rsrc, sampleRsrc)
        XCTAssertEqual(files[1].data, sampleData)
        XCTAssertEqual(files[2].data, Array("read me".utf8))
    }

    /// Optional: point NOVASWIFT_TEST_ARCHIVE at a real .sit/.hqx/.bin to check it unpacks.
    func testRealArchiveFromEnvironment() throws {
        guard let path = ProcessInfo.processInfo.environment["NOVASWIFT_TEST_ARCHIVE"] else { throw XCTSkip("NOVASWIFT_TEST_ARCHIVE not set") }
        let url = URL(fileURLWithPath: path)
        let files = try MacArchive.extract(try Data(contentsOf: url), name: url.lastPathComponent)
        XCTAssertFalse(files.isEmpty)
    }

    func testSitXAndUnsupportedMethodsFailClearly() throws {
        let sitx = Array("StuffIt!".utf8) + [UInt8](repeating: 0, count: 64)
        XCTAssertThrowsError(try MacArchive.extract(Data(sitx))) { XCTAssertEqual($0 as? MacArchiveError, .stuffItX) }
        let sit = StuffIt.buildClassic([(name: "X", rsrcMethod: 0, rsrc: [], rsrcPacked: [],
                                         dataMethod: 13, data: [1, 2, 3], dataPacked: [9, 9, 9])])
        XCTAssertThrowsError(try MacArchive.extract(Data(sit))) { XCTAssertEqual($0 as? MacArchiveError, .unsupportedMethod(13)) }
    }
}
