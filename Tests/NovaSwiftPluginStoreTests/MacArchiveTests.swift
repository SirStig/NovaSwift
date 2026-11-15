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

    /// Real fork payloads: method 5 from a published StuffIt fixture, method 13 from
    /// a classic archive, method 15 from a StuffIt 5 archive. Plaintext is what unar produced.
    func testRealStuffItMethods5_13And15() throws {
        func roundTrip(method: Int, packed: [UInt8], plain: [UInt8]) throws {
            let sit = StuffIt.buildClassic([(name: "F", rsrcMethod: 0, rsrc: [], rsrcPacked: [],
                                             dataMethod: method, data: plain, dataPacked: packed)])
            let files = try MacArchive.extract(Data(sit))
            XCTAssertEqual(files.first?.data, plain)
        }
        let lzahPacked: [UInt8] = [
        198, 98, 227, 112, 198, 0, 253, 24, 32, 72, 208, 31, 155, 105, 236, 201, 117, 63, 81, 111, 134, 187, 110, 255,
        67, 49, 103, 135, 29, 248, 170, 227, 145, 187, 203, 91, 6, 218, 234, 251, 64, 63, 203, 191, 110, 155, 155, 77,
        54, 192, 19, 89, 190, 221, 111, 40, 122, 95, 89, 31, 25, 0, 74, 40, 127, 244, 94, 244, 26, 127, 132, 174,
        204, 151, 108, 102, 16, 17, 199, 224, 232, 249, 34, 162, 251, 150, 141, 80, 129, 159, 0, 1, 124, 0, 62, 12,
        107, 200, 131, 176, 90, 161, 6, 81, 197, 40, 179, 42, 128, 190, 113, 39, 118, 72, 200, 147, 177, 71, 196, 75,
        85, 83, 117, 97, 124, 191, 10, 199, 149, 100, 239, 45, 24, 254, 89, 201, 117, 70, 186, 113, 145, 54, 60, 118,
        24, 145, 19, 136, 233, 170, 45, 231, 174, 27, 113, 119, 148, 160, 0, 165, 148, 249, 228, 58, 217, 207, 146, 129,
        214, 7, 53, 5, 142, 152, 182, 9, 218, 75, 33, 31, 79, 239, 24, 18, 188, 232, 217, 235, 194, 2, 56, 38,
        231, 93, 75, 69, 250, 0, 229, 154, 188, 128, 239, 211, 216, 182, 196, 196, 137, 67, 42, 38, 204, 80, 79, 155,
        92, 115, 140, 219, 245, 36, 208, 142, 115, 42, 32, 11, 126, 228, 84, 17, 142, 247, 84, 11, 116, 62, 161, 128,
        12, 211, 187, 130, 158, 108, 0, 12, 186, 128, 204, 78, 84, 83, 63, 7, 113, 75, 96, 62, 230, 15, 96, 2,
        185, 152, 144, 14, 72, 182, 254, 50, 245, 17, 199, 14, 0, 78, 0, 0, 188, 145, 51, 187, 28, 192, 5, 246,
        104, 255, 226, 234, 0, 28, 213, 251, 168, 111, 43, 96, 61, 0, 100, 151, 41, 119, 234, 243, 62, 96, 93, 47,
        128, 91, 2, 192, 45, 195, 176, 44
        ]
        let lzahPlain: [UInt8] = [
        0, 0, 1, 0, 0, 0, 1, 92, 0, 0, 0, 92, 0, 0, 0, 90, 40, 96, 6, 72, 110, 255, 240, 169,
        42, 83, 68, 12, 68, 0, 2, 108, 0, 255, 60, 47, 10, 169, 129, 42, 31, 78, 117, 112, 6, 97, 26, 65,
        26, 68, 108, 120, 32, 50, 46, 48, 32, 70, 105, 108, 101, 32, 70, 105, 120, 101, 114, 32, 82, 101, 97, 100,
        32, 77, 101, 101, 2, 0, 0, 0, 0, 0, 84, 69, 88, 84, 77, 80, 83, 32, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 163, 169, 119, 53, 0, 0,
        5, 123, 0, 0, 1, 182, 128, 65, 238, 253, 210, 112, 127, 66, 152, 81, 200, 255, 252, 76, 223, 1, 1, 78,
        117, 72, 231, 128, 128, 65, 238, 253, 178, 112, 7, 96, 232, 3, 63, 63, 63, 97, 0, 250, 58, 72, 231, 127,
        248, 97, 158, 97, 206, 71, 238, 253, 210, 67, 248, 2, 252, 66, 153, 66, 153, 66, 153, 32, 8, 103, 4, 74,
        16, 102, 4, 65, 250, 255, 216, 67, 235, 0, 36, 16, 24, 12, 0, 0, 27, 99, 4, 16, 60, 0, 27, 18,
        192, 18, 24, 12, 1, 0, 58, 102, 4, 18, 60, 0, 32, 18, 193, 83, 0, 102, 238, 97, 164, 65, 235, 0,
        36, 67, 238, 253, 178, 112, 32, 160, 46, 12, 174, 0, 0, 3, 32, 255, 0, 0, 0, 64, 0, 9, 6, 77,
        111, 110, 97, 99, 111, 0, 0, 2, 0, 0, 32, 16, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0, 0, 0,
        0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 33, 0, 0, 0, 30, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 0, 6, 0, 8, 0, 0, 0, 12,
        0, 0, 0, 0, 0, 0, 2, 234, 0, 0, 2, 234, 0, 0, 1, 0, 0, 0, 1, 92, 0, 0, 0, 92,
        0, 0, 0, 90, 0, 9, 253, 88, 3, 80, 0, 0, 0, 28, 0, 90, 0, 2, 69, 70, 78, 84, 0, 0,
        0, 26, 69, 84, 65, 66, 0, 0, 0, 38, 69, 80, 79, 83, 0, 0, 0, 50, 3, 235, 255, 255, 0, 0,
        0, 0, 0, 0, 0, 0, 3, 236, 255, 255, 0, 0, 0, 68, 0, 0, 0, 0, 3, 237, 255, 255, 0, 0,
        0, 76, 0, 0, 0, 0
        ]
        let lzhPacked: [UInt8] = [
        17, 0, 8, 28, 204, 119, 8, 162, 226, 224, 233, 87, 94, 158, 57, 1, 128, 124, 224, 133, 98, 16, 114, 120,
        244, 89, 151, 209, 220, 185, 107, 8, 85, 133, 81, 80, 74, 95, 73, 159, 28, 154, 238, 184, 68, 24, 165, 148,
        206, 114, 87, 105, 243, 138, 5, 0, 0
        ]
        let lzhPlain: [UInt8] = [
        0, 0, 1, 0, 0, 0, 1, 26, 0, 0, 0, 26, 0, 0, 0, 50, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 22, 0, 1, 0, 0,
        0, 0, 0, 12, 0, 9, 0, 21, 0, 84, 0, 12, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0,
        1, 26, 0, 0, 0, 26, 0, 0, 0, 50, 83, 79, 82, 84, 1, 42, 0, 128, 0, 28, 0, 50, 0, 0,
        115, 116, 121, 108, 0, 0, 0, 10, 0, 128, 255, 255, 0, 0, 0, 0, 8, 41, 70, 244
        ]
        let arsenicPacked: [UInt8] = [
        66, 193, 213, 4, 164, 77, 11, 67, 174, 63, 122, 225, 87, 77, 85, 164, 13, 132, 89, 59, 193, 142, 65, 108,
        213, 137, 104, 214, 140, 223, 38, 213, 200, 180, 201, 44, 133, 95, 197, 31, 212, 153, 145, 253, 53, 9, 95, 24,
        80, 113, 102, 103, 247, 78, 232, 40, 116, 220, 73, 137, 206, 142, 173, 29, 28, 47, 14, 7, 26, 231, 159, 156,
        254, 183, 99, 244, 153, 107, 254, 148, 59, 24, 17, 2, 7, 174, 202, 210, 180
        ]
        let arsenicPlain: [UInt8] = [
        84, 104, 105, 115, 32, 115, 105, 109, 112, 108, 121, 32, 109, 97, 120, 101, 115, 32, 121, 111, 117, 114, 32, 99,
        97, 115, 104, 32, 45, 32, 49, 46, 54, 32, 43, 32, 66, 105, 108, 108, 105, 111, 110, 33, 33, 33, 33, 33,
        33, 33, 13, 73, 32, 104, 97, 118, 101, 32, 110, 101, 118, 101, 114, 32, 117, 115, 101, 100, 32, 97, 108, 108,
        32, 111, 102, 32, 116, 104, 105, 115, 32, 109, 111, 110, 101, 121, 32, 45, 32, 105, 116, 32, 105, 115, 32, 116,
        111, 111, 32, 109, 117, 99, 104, 33
        ]

        try roundTrip(method: 5, packed: lzahPacked, plain: lzahPlain)
        try roundTrip(method: 13, packed: lzhPacked, plain: lzhPlain)
        try roundTrip(method: 15, packed: arsenicPacked, plain: arsenicPlain)
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
        // Method 14 ("Installer") has no published decoder here. Method 13 is a real codec.
        let sit = StuffIt.buildClassic([(name: "X", rsrcMethod: 0, rsrc: [], rsrcPacked: [],
                                         dataMethod: 14, data: [1, 2, 3], dataPacked: [9, 9, 9])])
        XCTAssertThrowsError(try MacArchive.extract(Data(sit))) { XCTAssertEqual($0 as? MacArchiveError, .unsupportedMethod(14)) }
    }

    func testHeaderClaimingAHugeForkIsRefusedBeforeAllocating() throws {
        var sit = StuffIt.buildClassic([(name: "Bomb", rsrcMethod: 0, rsrc: [], rsrcPacked: [],
                                         dataMethod: 0, data: [1, 2, 3], dataPacked: [1, 2, 3])])
        // First entry header starts at 22; its data-fork length is at +88. Claim 2 GB.
        let at = 22 + 88
        sit[at] = 0x7F; sit[at + 1] = 0xFF; sit[at + 2] = 0xFF; sit[at + 3] = 0xFF
        XCTAssertThrowsError(try MacArchive.extract(Data(sit))) { error in
            guard case .corrupt(let why)? = error as? MacArchiveError else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("unpack"), why)
        }
    }

    func testUnpackBudgetIsSharedAndEnforced() throws {
        let sit = StuffIt.buildClassic([(name: "A", rsrcMethod: 0, rsrc: [9, 9], rsrcPacked: [9, 9],
                                         dataMethod: 0, data: [1, 2, 3], dataPacked: [1, 2, 3])])
        XCTAssertNoThrow(try StuffIt.extract(sit, budget: 5), "both forks fit exactly")
        XCTAssertThrowsError(try StuffIt.extract(sit, budget: 4), "the forks together are over budget")
        // A wrapper's output counts against the same budget as the archive inside it.
        let hqx = BinHex.encode(MacFile(name: "A.sit", fileType: "SIT!", creator: "SIT!", data: sit), name: "A.sit")
        XCTAssertThrowsError(try BinHex.decode(hqx, budget: 16)) { error in
            guard case .corrupt(let why)? = error as? MacArchiveError else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("unpack"), why)
        }
        XCTAssertNoThrow(try BinHex.decode(hqx))
    }

    /// Archives come from the internet: every codec must either throw or return
    /// the length asked for on garbage and truncated input, never trap or hang.
    func testCodecsSurviveMalformedInput() {
        var rng = SystemRandomNumberGenerator()
        let methods = [0, 1, 2, 3, 5, 13, 15]
        for method in methods {
            for round in 0..<200 {
                let n = round < 20 ? round : Int.random(in: 0...600, using: &rng)
                var bytes = (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
                // Method 13 reads a mode byte first; aim some rounds at its preset tables.
                if method == 13, !bytes.isEmpty, round % 3 == 0 { bytes[0] = UInt8(0x10 * Int.random(in: 1...5, using: &rng)) }
                let outLen = Int.random(in: 0...4096, using: &rng)
                if let out = try? StuffItCodecs.decode(method: method, bytes[...], outLen: outLen) {
                    XCTAssertLessThanOrEqual(out.count, outLen, "method \(method) wrote past the length it was asked for")
                }
            }
        }
    }
}
