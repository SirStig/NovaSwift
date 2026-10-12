import XCTest
@testable import NovaSwiftKit

/// Container writers, text codecs and the NCB syntax checker.
final class EditingCodecTests: XCTestCase {

    private func sample() -> ResourceCollection {
        var c = ResourceCollection()
        c.add(Resource(type: NovaType.ship, id: 128, name: "Shuttle", attributes: 0x20, data: Data([1, 2, 3, 4])))
        c.add(Resource(type: NovaType.ship, id: 129, name: "", data: Data()))
        c.add(Resource(type: NovaType.ship, id: 700, name: "Mïsn Çhar", data: Data(repeating: 0xAB, count: 3000)))
        c.add(Resource(type: NovaType.outfit, id: -5, name: "Negative id", data: Data([9])))
        c.add(Resource(type: NovaType.pict, id: 9000, name: String(repeating: "n", count: 255), data: Data((0..<255).map(UInt8.init))))
        c.add(Resource(type: NovaType.strList, id: 128, data: TextResourceCodec.encodeStringList(["a", "bé", ""])))
        return c
    }

    private func assertEqual(_ a: ResourceCollection, _ b: ResourceCollection, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.types, b.types, file: file, line: line)
        for t in a.types {
            let ra = a.resources(of: t), rb = b.resources(of: t)
            XCTAssertEqual(ra.map(\.id), rb.map(\.id), file: file, line: line)
            for (x, y) in zip(ra, rb) {
                XCTAssertEqual(x.data, y.data, "\(t) #\(x.id) data", file: file, line: line)
                XCTAssertEqual(x.name, y.name, "\(t) #\(x.id) name", file: file, line: line)
                XCTAssertEqual(x.attributes, y.attributes, "\(t) #\(x.id) attributes", file: file, line: line)
            }
        }
    }

    func testClassicForkRoundTrip() throws {
        let c = sample()
        let bytes = try ClassicForkWriter.write(c)
        XCTAssertEqual(ResourceFile.detectFormat(bytes), .classic)
        assertEqual(try ClassicResourceFork.parse(bytes), c)
        // Writing what was parsed gives the same bytes (deterministic layout).
        XCTAssertEqual(try ClassicForkWriter.write(try ClassicResourceFork.parse(bytes)), bytes)
    }

    func testClassicForkSingleResourceAndEmpty() throws {
        var c = ResourceCollection()
        c.add(Resource(type: NovaType.desc, id: 128, data: Data([0x41, 0])))
        assertEqual(try ClassicResourceFork.parse(try ClassicForkWriter.write(c)), c)
        XCTAssertThrowsError(try ClassicForkWriter.write(ResourceCollection()))
    }

    func testRezRoundTripOfEditableCollection() throws {
        let c = sample()
        var rezSafe = ResourceCollection() // BRGR stores a 16-bit id and no attributes
        for t in c.types { for r in c.resources(of: t) { rezSafe.add(Resource(type: t, id: r.id, name: r.name, data: r.data)) } }
        assertEqual(try RezContainer.parse(RezWriter.write(rezSafe)), rezSafe)
    }

    func testClassicForkRoundTripOfRealData() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = GameLibrary.discoverResourceFiles(in: repo.appendingPathComponent("data/base"))
        guard let first = files.first(where: { $0.lastPathComponent.contains("Data 2") }) ?? files.first else {
            throw XCTSkip("No stock data under data/base")
        }
        let c = try ResourceFile.read(contentsOf: first)
        let bytes = try ClassicForkWriter.write(c)
        assertEqual(try ClassicResourceFork.parse(bytes), c)
    }

    // MARK: Text

    func testStringListRoundTrip() {
        let items = ["Fédéral", "", String(repeating: "x", count: 255), "line\rbreak"]
        let data = TextResourceCodec.encodeStringList(items)
        XCTAssertEqual(TextResourceCodec.decodeStringList(data), items)
        XCTAssertEqual(TextResourceCodec.decodeStringList(Data()), [])
        // Over-long entries are clipped to a Pascal string.
        let clipped = TextResourceCodec.decodeStringList(TextResourceCodec.encodeStringList([String(repeating: "y", count: 400)]))
        XCTAssertEqual(clipped.first?.count, 255)
    }

    func testPascalStringAndDisplayHelpers() {
        XCTAssertEqual(TextResourceCodec.decodeString(TextResourceCodec.encodeString("Hello ï")), "Hello ï")
        XCTAssertEqual(TextResourceCodec.display("a\rb\r\nc"), "a\nb\nc")
        XCTAssertEqual(TextResourceCodec.stored("a\nb"), "a\rb")
    }

    func testDescRecordRoundTrip() {
        var d = DescRecord(text: "Hello\rWorld {b12 \"a\" \"b\"}", pictureID: 6094, movieFile: "Race 1.mov", flags: 5)
        let data = d.encode()
        XCTAssertEqual(data.count, "Hello\rWorld {b12 \"a\" \"b\"}".count + 1 + DescRecord.trailerSize)
        let back = DescRecord(data)
        XCTAssertEqual(back, d)
        XCTAssertEqual(back.encode(), data)
        d.movieFile = ""
        d.flags = 0
        XCTAssertEqual(DescRecord(d.encode()).pictureID, 6094)
        // A text-only legacy record (no trailer) keeps its shape.
        let legacy = Data([0x41, 0x42, 0x00])
        XCTAssertEqual(DescRecord(legacy).encode(), legacy)
        // A blank new record carries the full trailer.
        XCTAssertEqual(DescRecord().encode().count, 1 + DescRecord.trailerSize)
    }

    // MARK: NCB

    func testNCBTestSyntax() {
        XCTAssertTrue(NCBSyntax.checkTest("").isEmpty)
        XCTAssertTrue(NCBSyntax.checkTest("b13 & (b15 | !b72)").isEmpty)
        XCTAssertTrue(NCBSyntax.checkTest("!(B42 | B53) & b103").isEmpty)
        XCTAssertTrue(NCBSyntax.checkTest("o128 & e200 & g").isEmpty)
        XCTAssertFalse(NCBSyntax.checkTest("(b1 & b2").isEmpty)                       // missing )
        XCTAssertFalse(NCBSyntax.checkTest("b1 & b2)").isEmpty)                       // stray )
        XCTAssertFalse(NCBSyntax.checkTest("b1 &").isEmpty)                           // dangling operator
        XCTAssertFalse(NCBSyntax.checkTest("b & b2").isEmpty)                         // no number
        XCTAssertFalse(NCBSyntax.checkTest("b12000").isEmpty)                         // bit out of range
        XCTAssertFalse(NCBSyntax.checkTest("& b1").isEmpty)                           // bad start
        XCTAssertTrue(NCBSyntax.checkTest("b1 & b2 | b3").contains { $0.message.contains("unpredictable") })
        XCTAssertTrue(NCBSyntax.checkTest("b1 b2").contains { $0.message.contains("Missing") })
        XCTAssertTrue(NCBSyntax.checkTest("b1 & b2 # b3").contains { $0.severity == .warning })
    }

    func testNCBSetSyntaxAndOperands() {
        XCTAssertTrue(NCBSyntax.checkSet("b1 b2 !b3 ^b4").isEmpty)
        XCTAssertTrue(NCBSyntax.checkSet("b350 b6666 S781").isEmpty)
        XCTAssertTrue(NCBSyntax.checkSet("R(b2 !b3)").isEmpty)
        XCTAssertFalse(NCBSyntax.checkSet("S2000").isEmpty)            // mission out of range
        XCTAssertFalse(NCBSyntax.checkSet("b10000").isEmpty)           // bit out of range
        XCTAssertFalse(NCBSyntax.checkSet("S862S863").isEmpty)         // missing separator
        XCTAssertFalse(NCBSyntax.checkSet("Z5").isEmpty)               // unknown operator
        let ops = NCBSyntax.operands(set: "b1 S781 g200 K140 Y300 M150")
        XCTAssertEqual(ops.compactMap(\.resource), [
            ResourceKey(NovaType.mission, 781), ResourceKey(NovaType.outfit, 200), ResourceKey(NovaType.rank, 140),
            ResourceKey(NovaType.spob, 300), ResourceKey(NovaType.syst, 150),
        ])
        XCTAssertEqual(NCBSyntax.rewrite("b1 S781 g200 S781", kind: .set) { t, id in
            t == NovaType.mission && id == 781 ? 9000 : nil
        }, "b1 S9000 g200 S9000")
        XCTAssertEqual(NCBSyntax.operands(test: "o128 & e200 & b5").compactMap(\.resource),
                       [ResourceKey(NovaType.outfit, 128), ResourceKey(NovaType.syst, 200)])
    }
}
