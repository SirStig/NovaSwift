import XCTest
import NovaSwiftKit
@testable import NovaSwiftStory

/// The pilot converter, against SYNTHETIC pilots only: the writer below is the
/// test's own encoder (the layout of `PilotFile_SaveGameCore` 0x004c7dd0), never
/// a real player's file. Needs the stock game data under `data/base` to resolve
/// ids; skips without it.
final class EVNovaPilotImportTests: XCTestCase {

    private func stockGame() throws -> NovaGame {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = GameLibrary.discoverResourceFiles(in: repo.appendingPathComponent("data/base"))
        guard !files.isEmpty else { throw XCTSkip("No stock data under data/base") }
        return NovaGame(try GameLibrary.merge(baseFiles: files))
    }

    // MARK: Synthetic pilot spec + encoder

    struct Spec {
        var shipIdx = 0
        var jumpIdx = 0
        var credits: UInt32 = 123_456
        var month = 3, day = 14, year = 1180
        var fuel = 250
        var cargo = [5, 0, 7, 0, 0, 1]
        var outfits: [Int: Int] = [:]          // outfit index → count
        var junk: [Int: Int] = [:]
        var discovery: [Int: Int] = [:]        // system index → level
        var reputation: [Int: Int] = [:]       // system index → signed
        var bits: [Int] = []
        var rating: UInt32 = 4321
        var escorts: [(cls: Int, upgrade: Int, sale: Int)] = []
        var missionSlot: (idx: Int, travel: Int, ret: Int, days: Int, cargoType: Int, qty: Int)?
        var cron: (idx: Int, dur: Int, hold: Int)?
        var rank: Int?
        var dominated: Int?
        var nick = "Ace"
        var prefix = ""
        var suffix = " NC"
        var strict = true
        var male = false
        var ship = "Serenity"
        var persDead: Int?
        var persGrudge: Int?
    }

    private func put16(_ b: inout [UInt8], _ o: Int, _ v: Int, _ big: Bool) {
        let u = UInt16(truncatingIfNeeded: v)
        b[o] = UInt8(big ? u >> 8 : u & 0xFF); b[o + 1] = UInt8(big ? u & 0xFF : u >> 8)
    }
    private func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32, _ big: Bool) {
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: v >> UInt32(8 * $0)) }
        for i in 0..<4 { b[o + i] = big ? bytes[3 - i] : bytes[i] }
    }
    private func putText(_ b: inout [UInt8], _ o: Int, _ s: String, pascal: Bool) {
        let t = Array(s.utf8)
        if pascal { b[o] = UInt8(t.count); for (i, c) in t.enumerated() { b[o + 1 + i] = c } }
        else { for (i, c) in t.enumerated() { b[o + i] = c } }
    }

    /// Windows-layout plaintext blocks (block 1, block 2).
    private func encode(_ s: Spec, big: Bool, pascal: Bool) -> ([UInt8], [UInt8]) {
        var b1 = [UInt8](repeating: 0, count: EVNovaPilotFile.block1Size)
        var b2 = [UInt8](repeating: 0, count: EVNovaPilotFile.block2Size)
        put16(&b1, 0, s.jumpIdx, big); put16(&b1, 2, s.shipIdx, big)
        for (i, c) in s.cargo.enumerated() { put16(&b1, 4 + 2 * i, c, big) }
        put16(&b1, 0x10, 77, big); put16(&b1, 0x12, s.fuel, big)
        put16(&b1, 0x14, s.month, big); put16(&b1, 0x16, s.day, big); put16(&b1, 0x18, s.year, big)
        for (k, v) in s.discovery { put16(&b1, 0x1A + 2 * k, v, big) }
        for (k, v) in s.outfits { put16(&b1, 0x101A + 2 * k, v, big) }
        for (k, v) in s.reputation { put16(&b1, 0x141A + 2 * k, v, big) }
        put32(&b1, 0x281A, s.credits, big)
        for i in s.bits { b1[0xB7BE + i] = 1 }
        if let d = s.dominated { b1[0xDECE + d] = 1 }
        for (i, e) in s.escorts.enumerated() {
            put16(&b1, 0xE6CE + 2 * i, e.cls, big); put16(&b1, 0xE7CE + 2 * i, e.upgrade, big)
            put16(&b1, 0xE84E + 2 * i, e.sale, big)
        }
        for i in s.escorts.count..<0x40 { put16(&b1, 0xE6CE + 2 * i, -1, big) }
        for i in 0..<0x40 { put16(&b1, 0xE74E + 2 * i, -1, big); put16(&b1, 0xE8CE + 2 * i, -1, big) }
        put32(&b1, 0xE94E, s.rating, big)
        if let m = s.missionSlot {
            b1[0x281E] = 1; b1[0x281F] = 1
            let o = 0x295E
            put16(&b1, o, m.travel, big); put16(&b1, o + 4, m.ret, big)
            put16(&b1, o + 0x12, m.cargoType, big); put16(&b1, o + 0x14, m.qty, big)
            put16(&b1, o + 0x45, m.days, big); put16(&b1, o + 0x4D, m.idx, big)
            b1[o + 0x33] = 1
        }
        put16(&b2, 0, 300, big); put16(&b2, 2, s.strict ? 1 : 0, big); put16(&b2, 4, s.male ? 1 : 0, big)
        for i in 0..<0x200 { put16(&b2, 0x3590 + 2 * i, -1, big); put16(&b2, 0x3990 + 2 * i, -1, big) }
        for i in 0..<0x400 { put16(&b2, 0x1006 + 2 * i, 1, big) }
        if let p = s.persDead { put16(&b2, 0x1006 + 2 * p, 0, big) }
        if let p = s.persGrudge { put16(&b2, 0x1806 + 2 * p, 1, big) }
        if let c = s.cron { put16(&b2, 0x3590 + 2 * c.idx, c.dur, big); put16(&b2, 0x3990 + 2 * c.idx, c.hold, big) }
        if let r = s.rank { put16(&b2, 0x5DDE + 2 * r, 1, big) }
        for i in 0..<0x4 { put16(&b2, 0x5D90 + 2 * i, -1, big) }
        putText(&b2, 0x5D98, s.nick, pascal: pascal)
        putText(&b2, 0x5EDE, s.prefix, pascal: pascal); putText(&b2, 0x5EEE, s.suffix, pascal: pascal)
        return (b1, b2)
    }

    private func windowsFile(_ s: Spec, encrypt: Bool = true) -> Data {
        let (b1, b2) = encode(s, big: false, pascal: false)
        var out = [UInt8]()
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        out += le32(b1.count) + (encrypt ? EVNovaPilotFile.crypt(b1) : b1)
        out += le32(b2.count) + (encrypt ? EVNovaPilotFile.crypt(b2) : b2)
        out += Array(s.ship.utf8) + [0]
        return Data(out)
    }

    /// Mac block 1: insert the six padding bytes into each mission record.
    private func macPad(_ b1: [UInt8]) -> [UInt8] {
        var out = Array(b1[0..<0x295E])
        for slot in 0..<16 {
            let o = 0x295E + slot * 0x8E6
            out += b1[o..<(o + 0x20)] + [0xAA, 0xAA]
            out += b1[(o + 0x20)..<(o + 0x33)] + [0xBB]
            out += b1[(o + 0x33)..<(o + 0x8E6)] + [0xCC, 0xCC, 0xCC]
        }
        out += b1[(0x295E + 16 * 0x8E6)...]
        return out
    }

    private func resourceFork(_ r1: [UInt8], _ r2: [UInt8], name2: String) -> Data {
        func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        func be32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * (3 - $0))) & 0xFF) } }
        func be24(_ v: Int) -> [UInt8] { (0..<3).map { UInt8((v >> (8 * (2 - $0))) & 0xFF) } }
        let dataSec = be32(r1.count) + r1 + be32(r2.count) + r2
        let off2 = 4 + r1.count
        let nameBytes = Array(name2.utf8)
        let names: [UInt8] = [UInt8(nameBytes.count)] + nameBytes
        let type: [UInt8] = [0x4E, 0x70, 0x95, 0x4C]
        var typeList = be16(0) + type + be16(1) + be16(10)
        typeList += be16(128) + be16(0xFFFF) + [0] + be24(0) + be32(0)
        typeList += be16(129) + be16(0) + [0] + be24(off2) + be32(0)
        let mapLen = 28 + typeList.count + names.count
        let dataOffset = 256
        var map = [UInt8](repeating: 0, count: 24)
        map += be16(28) + be16(28 + typeList.count) + typeList + names
        XCTAssertEqual(map.count, mapLen)
        var fork = be32(dataOffset) + be32(dataOffset + dataSec.count) + be32(dataSec.count) + be32(mapLen)
        fork += [UInt8](repeating: 0, count: dataOffset - 16) + dataSec + map
        return Data(fork)
    }

    private func macFork(_ s: Spec) -> Data {
        let (b1, b2) = encode(s, big: true, pascal: true)
        return resourceFork(EVNovaPilotFile.crypt(macPad(b1)), b2, name2: s.ship)
    }

    private func appleDouble(_ fork: Data) -> Data {
        var h: [UInt8] = [0x00, 0x05, 0x16, 0x07, 0, 2, 0, 0] + [UInt8](repeating: 0, count: 16) + [0, 1]
        let off = 26 + 12
        func be32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * (3 - $0))) & 0xFF) } }
        h += be32(2) + be32(off) + be32(fork.count)
        return Data(h) + fork
    }

    private func macBinary(_ fork: Data, name: String) -> Data {
        var h = [UInt8](repeating: 0, count: 128)
        h[1] = UInt8(name.utf8.count)
        for (i, c) in name.utf8.enumerated() { h[2 + i] = c }
        let n = fork.count
        for i in 0..<4 { h[87 + i] = UInt8((n >> (8 * (3 - i))) & 0xFF) }
        return Data(h) + fork + Data(repeating: 0, count: (128 - n % 128) % 128)
    }

    // MARK: Cipher

    /// Known answers taken from the original executable's transform (0x0046f960)
    /// run under the oracle emulator.
    func testCipherMatchesOriginalExecutable() {
        let a = (0..<23).map { UInt8(($0 * 7 + 3) & 0xFF) }
        XCTAssertEqual(hex(EVNovaPilotFile.crypt(a)), "b0603017539c4c25ce87d7bf5d80865d445b9d4744f5f8")
        XCTAssertEqual(hex(EVNovaPilotFile.crypt(Array(0..<16))), "b36b230c48bf6716fdcc94e406d3ed3e")
        XCTAssertEqual(EVNovaPilotFile.crypt(EVNovaPilotFile.crypt(a)), a)
    }

    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    // MARK: Scenario helpers

    private struct Ids {
        var jumpIdx: Int, spob: Int, system: Int, shipIdx: Int, missionIdx: Int, cronIdx: Int?, rankIdx: Int?
        var outfitIdx: Int, otherSystem: Int
    }

    private func ids(_ game: NovaGame) throws -> Ids {
        let spob = try XCTUnwrap(game.spobs().first { game.systemContaining(spob: $0.id) != nil })
        let system = try XCTUnwrap(game.systemContaining(spob: spob.id))
        let ship = try XCTUnwrap(game.ships().first)
        let mission = try XCTUnwrap(game.missions().first)
        let outfit = try XCTUnwrap(game.outfits().first)
        let other = try XCTUnwrap(game.systems().first { $0.id != system })
        return Ids(jumpIdx: spob.id - 128, spob: spob.id, system: system, shipIdx: ship.id - 128,
                   missionIdx: mission.id - 128, cronIdx: game.crons().first.map { $0.id - 128 },
                   rankIdx: game.ranks().first.map { $0.id - 128 }, outfitIdx: outfit.id - 128,
                   otherSystem: other.id - 128)
    }

    private func fullSpec(_ game: NovaGame) throws -> (Spec, Ids) {
        let i = try ids(game)
        var s = Spec()
        s.shipIdx = i.shipIdx; s.jumpIdx = i.jumpIdx
        s.outfits = [i.outfitIdx: 3, 0x1FF: 2]
        s.discovery = [i.system - 128: 2, i.otherSystem: 1]
        s.reputation = [i.system - 128: -150, i.otherSystem: 40]
        s.bits = [0, 17, 9999]
        s.escorts = [(cls: i.shipIdx, upgrade: 0, sale: 1), (cls: 1000 + i.shipIdx, upgrade: 0, sale: 0)]
        s.missionSlot = (i.missionIdx, i.jumpIdx, i.jumpIdx, 12, -1, 0)
        if let c = i.cronIdx { s.cron = (c, 30, -1) }
        s.rank = i.rankIdx
        s.dominated = i.jumpIdx
        return (s, i)
    }

    private func check(_ res: EVNovaPilotImportResult, _ s: Spec, _ i: Ids, game: NovaGame, file: StaticString = #filePath, line: UInt = #line) {
        let p = res.player
        XCTAssertEqual(p.pilotName, "Test Pilot", file: file, line: line)
        XCTAssertEqual(p.credits, 123_456, file: file, line: line)
        XCTAssertEqual(p.date, GameDate(day: 14, month: 3, year: 1180), file: file, line: line)
        XCTAssertEqual(p.shipType, 128 + i.shipIdx, file: file, line: line)
        XCTAssertEqual(p.shipName, "Serenity", file: file, line: line)
        XCTAssertEqual(p.landedSpob, i.spob, file: file, line: line)
        XCTAssertEqual(p.currentSystem, i.system, file: file, line: line)
        XCTAssertEqual(p.fuel, 250, file: file, line: line)
        XCTAssertEqual(p.cargo[0], 5, file: file, line: line); XCTAssertEqual(p.cargo[2], 7, file: file, line: line)
        XCTAssertEqual(p.cargo[5], 1, file: file, line: line); XCTAssertNil(p.cargo[1], file: file, line: line)
        XCTAssertEqual(p.outfits[128 + i.outfitIdx], 3, file: file, line: line)
        XCTAssertEqual(p.outfits[128 + 0x1FF], 2, file: file, line: line)
        XCTAssertEqual(p.combatRating, 4321, file: file, line: line)
        XCTAssertEqual(p.setBits, [0, 17, 9999], file: file, line: line)
        XCTAssertEqual(p.systemReputation?[i.system], -150, file: file, line: line)
        XCTAssertEqual(p.systemReputation?[128 + i.otherSystem], 40, file: file, line: line)
        XCTAssertTrue(p.exploredSystems.contains(i.system), file: file, line: line)
        XCTAssertEqual(p.landedSystems, [i.system], file: file, line: line)
        XCTAssertEqual(p.nickname, "Ace", file: file, line: line)
        XCTAssertEqual(p.dateSuffix, " NC", file: file, line: line)
        XCTAssertEqual(p.datePrefix, "", file: file, line: line)
        XCTAssertEqual(p.isStrictPlay, true, file: file, line: line)
        XCTAssertFalse(p.isMale, file: file, line: line)
        XCTAssertEqual(p.escortWing.count, 2, file: file, line: line)
        XCTAssertEqual(p.escortWing.first?.origin, .captured, file: file, line: line)
        XCTAssertEqual(p.escortWing.first?.pendingSale, true, file: file, line: line)
        XCTAssertEqual(p.escortWing.last?.origin, .hired, file: file, line: line)
        XCTAssertEqual(p.dominatedStellars, [i.spob], file: file, line: line)
        XCTAssertEqual(p.activeMissions.count, 1, file: file, line: line)
        if let m = p.activeMissions.first {
            XCTAssertEqual(m.missionID, 128 + i.missionIdx, file: file, line: line)
            XCTAssertEqual(m.travelSpobID, i.spob, file: file, line: line)
            XCTAssertEqual(m.returnSpobID, i.spob, file: file, line: line)
            XCTAssertEqual(m.deadline, p.date.adding(days: 12), file: file, line: line)
            XCTAssertTrue(m.cargoPickedUp, file: file, line: line)
            XCTAssertTrue(m.visitedTravelStellar, file: file, line: line)
            XCTAssertEqual(m.slot, 0, file: file, line: line)
        }
        if let c = i.cronIdx {
            XCTAssertEqual(p.cronRuntime[128 + c]?.duration, 30, file: file, line: line)
            XCTAssertEqual(p.cronRuntime[128 + c]?.holdoff, -1, file: file, line: line)
            XCTAssertTrue(p.cronRuntime[128 + c]?.isActive ?? false, file: file, line: line)
        }
        if let r = i.rankIdx { XCTAssertEqual(p.activeRanks, [128 + r], file: file, line: line) }
        XCTAssertTrue(res.summary.warnings.contains { $0.contains("outfit type(s)") }, "missing outfit 0x1FF should warn", file: file, line: line)
        XCTAssertEqual(res.summary.credits, 123_456, file: file, line: line)
    }

    // MARK: Windows

    func testWindowsPilotRoundTrip() throws {
        let game = try stockGame()
        let (s, i) = try fullSpec(game)
        try XCTSkipIf(game.outfit(128 + 0x1FF) != nil, "stock data defines outfit 0x1FF")
        let blocks = try EVNovaPilotFile.decode(windowsFile(s))
        XCTAssertEqual(blocks.format, .windowsPLT)
        XCTAssertFalse(blocks.bigEndian)
        check(EVNovaPilotImporter.convert(blocks, pilotName: "Test Pilot", game: game), s, i, game: game)
    }

    func testWindowsPlaintextBlocksAreAccepted() throws {
        let game = try stockGame()
        let (s, i) = try fullSpec(game)
        let blocks = try EVNovaPilotFile.decode(windowsFile(s, encrypt: false))
        let res = EVNovaPilotImporter.convert(blocks, pilotName: "Test Pilot", game: game)
        XCTAssertEqual(res.player.credits, 123_456)
        XCTAssertEqual(res.player.landedSpob, i.spob)
    }

    // MARK: Classic Mac

    func testMacResourceForkAppleDoubleAndMacBinary() throws {
        let game = try stockGame()
        let (s, i) = try fullSpec(game)
        try XCTSkipIf(game.outfit(128 + 0x1FF) != nil, "stock data defines outfit 0x1FF")
        let fork = macFork(s)
        for (label, data) in [("fork", fork), ("appledouble", appleDouble(fork)),
                              ("macbinary", macBinary(fork, name: "Test Pilot"))] {
            let blocks = try EVNovaPilotFile.decode(data)
            XCTAssertEqual(blocks.format, .classicMac, label)
            XCTAssertTrue(blocks.bigEndian, label)
            XCTAssertEqual(blocks.block1.count, EVNovaPilotFile.block1Size, label)
            check(EVNovaPilotImporter.convert(blocks, pilotName: "Test Pilot", game: game), s, i, game: game)
        }
    }

    func testMacPaddingStripKeepsMissionBytesAligned() throws {
        var plain = [UInt8](repeating: 0, count: EVNovaPilotFile.block1Size)
        for slot in 0..<16 { for k in 0..<0x8E6 { plain[0x295E + slot * 0x8E6 + k] = UInt8(truncatingIfNeeded: slot * 31 + k) } }
        plain[0xE94E] = 0x7C
        let stripped = EVNovaPilotFile.stripMacMissionPadding(macPad(plain))
        XCTAssertEqual(stripped, plain)
    }

    // MARK: Robustness

    func testRejectsNonPilotAndTruncatedFiles() {
        XCTAssertThrowsError(try EVNovaPilotFile.decode(Data("hello world, not a pilot".utf8)))
        XCTAssertThrowsError(try EVNovaPilotFile.decode(Data([0x52, 0xE9, 0, 0, 1, 2, 3])))
        XCTAssertThrowsError(try EVNovaPilotFile.decode(Data()))
    }

    func testBadIdsWarnInsteadOfFailing() throws {
        let game = try stockGame()
        var s = Spec()
        s.shipIdx = 0x2FF; s.jumpIdx = 0x7FF
        s.escorts = [(cls: 0x2FE, upgrade: 0, sale: 0)]
        s.month = 0
        let blocks = try EVNovaPilotFile.decode(windowsFile(s))
        let res = EVNovaPilotImporter.convert(blocks, pilotName: nil, game: game)
        XCTAssertEqual(res.player.pilotName, "Captain")
        XCTAssertNotNil(game.ship(res.player.shipType))
        XCTAssertNil(res.player.landedSpob)
        XCTAssertGreaterThanOrEqual(res.summary.warnings.count, 3)
    }

    func testImportedPilotSurvivesNativeSaveRoundTrip() throws {
        let game = try stockGame()
        let (s, _) = try fullSpec(game)
        let res = EVNovaPilotImporter.convert(try EVNovaPilotFile.decode(windowsFile(s)), pilotName: "Test Pilot", game: game)
        let save = PilotSave(displayName: "Test Pilot", scenarioName: "Imported", player: res.player, game: game)
        let back = try JSONDecoder().decode(PilotSave.self, from: JSONEncoder().encode(save))
        XCTAssertEqual(back.player.credits, 123_456)
        XCTAssertEqual(back.player.setBits, [0, 17, 9999])
    }
}
