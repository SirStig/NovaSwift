import XCTest
import NovaSwiftKit
import NovaSwiftEngine
@testable import NovaSwiftStory

/// The shared (Foundation-only) core of the debug suite that both the Apple app and the Godot dev
/// console drive: console registry, log buffer, pilot cheat ops, diagnostics battery, behavioural
/// tests, NCB index and the bug-report text assembly.
final class DebugSuiteTests: XCTestCase {

    private func stockGame() throws -> NovaGame {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = GameLibrary.discoverResourceFiles(in: repo.appendingPathComponent("data/base"))
        guard !files.isEmpty else { throw XCTSkip("No stock data under data/base") }
        return NovaGame(try GameLibrary.merge(baseFiles: files))
    }

    // MARK: Console

    func testTokenizeKeepsQuotedStrings() {
        XCTAssertEqual(DebugConsole.tokenize(#"ship "Federation Carrier" now"#),
                       ["ship", "Federation Carrier", "now"])
        XCTAssertEqual(DebugConsole.tokenize("  a   b "), ["a", "b"])
        XCTAssertEqual(DebugConsole.tokenize(""), [])
    }

    func testRunEchoesAndReportsUnknownCommand() {
        let c = DebugConsole()
        XCTAssertTrue(c.run("   ").isEmpty)
        let out = c.run("nope 1")
        XCTAssertEqual(out.first?.kind, .echo)
        XCTAssertEqual(out.first?.text, "> nope 1")
        XCTAssertEqual(out.last?.kind, .error)
        XCTAssertTrue(out.last?.text.contains("Unknown command: nope") ?? false)
    }

    func testBuiltinsHelpEchoHistoryClear() {
        let c = DebugConsole()
        var cleared = false
        c.onClear = { cleared = true }
        XCTAssertEqual(c.run("echo hello world").last?.text, "hello world")
        XCTAssertTrue(c.run("help").last?.text.contains("history") ?? false)
        XCTAssertEqual(c.run("help echo").last?.text, "echo <text>\n  Print the given text back.")
        c.run("clear")
        XCTAssertTrue(cleared)
        let hist = c.run("history").last?.text ?? ""
        XCTAssertTrue(hist.hasPrefix("1. echo hello world"))
        XCTAssertEqual(c.history.count, 5)
    }

    func testRegisteredCommandErrorsAndOnOff() throws {
        let c = DebugConsole()
        c.register(.init(name: "god", summary: "s", usage: "god [on|off]") { args in
            "God: \(try DebugConsole.onOff(args, current: false))"
        })
        XCTAssertEqual(c.run("god").last?.text, "God: true")
        XCTAssertEqual(c.run("GOD off").last?.text, "God: false")
        XCTAssertEqual(c.run("god maybe").last?.kind, .error)
    }

    func testTabCompletion() {
        let c = DebugConsole()
        c.register(.init(name: "spawn", summary: "", usage: "") { _ in "" })
        c.register(.init(name: "select", summary: "", usage: "") { _ in "" })
        XCTAssertEqual(c.complete("sp"), "spawn ")
        XCTAssertNil(c.complete("s"))                               // spawn/select share only "s"
        XCTAssertNil(c.complete("spawn "))
        XCTAssertEqual(c.matches(for: "he").map(\.name), ["help"])
    }

    // MARK: Log buffer

    func testLogBufferFiltersAndCapacity() {
        let b = DebugLogBuffer(capacity: 10)
        for i in 0..<25 { b.appendLog(level: .info, category: "AI", text: "line \(i)") }
        XCTAssertEqual(b.count, 10)
        XCTAssertEqual(b.lastID, 25)
        b.appendLog(level: .error, category: "Pilot", text: "boom «ship:7:Rebel»")
        b.appendEcho("> credits add 5")
        let all = b.entries()
        XCTAssertEqual(all.last?.kind, .commandEcho)
        XCTAssertEqual(b.categories(), ["AI", "Pilot"])
        XCTAssertEqual(b.entries(filter: .init(mutedLevels: [.info])).count, 2)   // error + echo
        XCTAssertEqual(b.entries(filter: .init(mutedCategories: ["Pilot"])).count, 9)   // 8 AI + the echo
        XCTAssertEqual(b.entries(filter: .init(search: "boom")).count, 1)
        let boom = b.entries(filter: .init(search: "boom")).first
        XCTAssertEqual(boom?.entityRefs, [.ship(id: 7, name: "Rebel")])
        XCTAssertEqual(boom?.displayText, "[Pilot] boom «ship:7:Rebel»")
        XCTAssertEqual(b.entries(sinceID: 26).count, 1)
        b.clear()
        XCTAssertEqual(b.count, 0)
        b.appendOutput("x")
        XCTAssertEqual(b.entries().first?.id, 28)
    }

    func testLevelNameMapping() {
        XCTAssertEqual(DebugLogLevel(name: "warning"), .error)
        XCTAssertEqual(DebugLogLevel(name: "fault"), .fault)
        XCTAssertEqual(DebugLogLevel(name: "default"), .notice)
        XCTAssertEqual(DebugLogLevel.error.displayName, "Warning")
    }

    func testLogSinkReceivesEmits() {
        let b = DebugLogBuffer()
        DebugLogSink.install { level, cat, msg in b.appendLog(level: DebugLogLevel(name: level), category: cat, text: msg) }
        defer { DebugLogSink.install(nil) }
        DebugLogSink.emit(level: "error", category: "Combat", message: "hit")
        XCTAssertEqual(b.entries().first?.level, .error)
        XCTAssertEqual(b.entries().first?.category, "Combat")
    }

    // MARK: Entity refs & profiler

    func testEntityRefRoundTripsThroughURL() {
        let ref = DevEntityRef.spob(id: 130, name: "Earth Station")
        XCTAssertEqual(DevEntityRef(linkURL: ref.linkURL), ref)
        XCTAssertEqual(ref.commandArg, "130")
        let segs = DevLogLinking.segments(in: "a «ship:3:X» b «bad c")
        XCTAssertEqual(segs.count, 3)
    }

    func testFrameProfilerAveragesAndSpikes() {
        let p = FrameProfiler()
        p.record("sim", seconds: 0.002); _ = p.endFrame(spikeThresholdMs: 100)
        p.record("sim", seconds: 0.004); p.record("draw", seconds: 0.001)
        let spike = p.endFrame(spikeThresholdMs: 4)
        XCTAssertEqual(spike?.phases.first?.name, "sim")
        let snap = p.snapshot()
        XCTAssertEqual(snap.first?.name, "sim")
        XCTAssertEqual(snap.first!.avgMs, 3.0, accuracy: 1e-9)
        XCTAssertEqual(snap.first!.worstMs, 4.0, accuracy: 1e-9)
        XCTAssertTrue(p.snapshot().isEmpty)
    }

    // MARK: Pilot ops

    func testPilotOps() throws {
        var s = PlayerState(shipType: 128, currentSystem: 128)
        s.credits = 100
        XCTAssertEqual(try DebugPilotOps.credits(["add", "50"], state: &s), "Credits: 150")
        XCTAssertEqual(try DebugPilotOps.credits(["set", "-9"], state: &s), "Credits: 0")
        XCTAssertThrowsError(try DebugPilotOps.credits(["add"], state: &s))
        XCTAssertThrowsError(try DebugPilotOps.credits(["mul", "2"], state: &s))

        let idx = NCBIndex.empty
        XCTAssertEqual(try DebugPilotOps.bit(["set", "42"], state: &s, index: idx), "Bit 42: set")
        XCTAssertTrue(s.setBits.contains(42))
        XCTAssertEqual(try DebugPilotOps.bit(["toggle", "42"], state: &s, index: idx), "Bit 42: clear")
        XCTAssertEqual(try DebugPilotOps.bit(["info", "9"], state: &s, index: idx),
                       "Bit 9 [clear] — no references in this data set.")

        let before = s.date
        _ = try DebugPilotOps.date(["+30"], state: &s)
        XCTAssertEqual(s.date, before.adding(days: 30))
        XCTAssertThrowsError(try DebugPilotOps.date(["30"], state: &s))

        let r = try DebugPilotOps.relation(["99999"], state: &s)
        XCTAssertEqual(r.value, SystemReputation.clamp(99999))
        XCTAssertEqual(s.systemReputation?[128], r.value)
    }

    func testPilotOpsAgainstStockData() throws {
        let game = try stockGame()
        var s = PlayerState(shipType: 128, currentSystem: 128)
        let first = try XCTUnwrap(game.outfits().first)
        _ = try DebugPilotOps.outfit(["add", "\(first.id)", "3"], state: &s, game: game)
        XCTAssertEqual(s.outfits[first.id], 3)
        _ = try DebugPilotOps.outfit(["remove", "\(first.id)", "2"], state: &s, game: game)
        XCTAssertEqual(s.outfits[first.id], 1)
        XCTAssertThrowsError(try DebugPilotOps.outfit(["add", "99999"], state: &s, game: game))
        let ship = try XCTUnwrap(game.ships().first)
        XCTAssertEqual(try DebugPilotOps.resolveShip(["\(ship.id)"], game: game).id, ship.id)
        XCTAssertThrowsError(try DebugPilotOps.resolveShip(["zzzz-no-such-hull"], game: game))
    }

    // MARK: Diagnostics & behavioural tests

    func testDiagnosticsWithoutGameFails() {
        let sections = DebugDiagnostics.run(game: nil, pilot: PlayerState(), liveShip: nil, liveHostiles: nil)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.tally.fail, 1)
    }

    func testDiagnosticsAgainstStockData() throws {
        let game = try stockGame()
        let pilot = PilotFactory.makeDefault(name: "Test", isMale: true, game: game)
        let sections = DebugDiagnostics.run(game: game, pilot: pilot, liveShip: nil, liveHostiles: nil)
        XCTAssertEqual(sections.map(\.title), ["Data Set", "Navigation", "Pilot", "Live World"])
        XCTAssertEqual(sections.tally.fail, 0, "\(sections.flatMap(\.results).filter { $0.status == .fail }.map(\.name))")
        let text = BugReportText.diagnostics(sections)
        XCTAssertTrue(text.contains("DATA SET"))
        XCTAssertTrue(text.contains("[PASS] Ships defined"))
    }

    func testBehaviouralTestsAllPass() {
        let sections = DebugLiveTests.run()
        XCTAssertEqual(sections.map(\.title), ["Damage Model", "Projectile Combat", "Flight Physics", "Regeneration"])
        let t = sections.tally
        XCTAssertEqual(t.fail, 0, "\(sections.flatMap(\.results).filter { $0.status == .fail }.map { "\($0.name): \($0.detail ?? "")" })")
        XCTAssertGreaterThanOrEqual(t.pass, 10)
    }

    // MARK: NCB index

    func testNCBIndexAgainstStockData() throws {
        let game = try stockGame()
        let index = NCBIndex.build(from: game)
        XCTAssertFalse(index.bits.isEmpty)
        let bit = try XCTUnwrap(index.bits.first)
        XCTAssertFalse(index.references(for: bit).isEmpty)
        let text = index.explain(bit: bit, isSet: true)
        XCTAssertTrue(text.hasPrefix("Bit \(bit) [SET] — "))
        XCTAssertEqual(index.bits, index.bits.sorted())
    }

    // MARK: Bug report

    func testBugReportTextAssembly() throws {
        var s = PlayerState(shipType: 128, currentSystem: 128)
        s.credits = 777
        s.setBit(5); s.setBit(900)
        let text = BugReportText.summary(note: "  it broke ", stamp: "2026-10-12-120000",
                                         buildLines: ["  app          X"], dataSetLines: ["  base data    complete"],
                                         game: nil, state: s)
        XCTAssertTrue(text.contains("NovaSwift bug report — 2026-10-12-120000"))
        XCTAssertTrue(text.contains("WHAT HAPPENED\nit broke\n"))
        XCTAssertTrue(text.contains("BUILD\n  app          X\n\nDATA SET\n  base data    complete\n\nPILOT"))
        XCTAssertTrue(text.contains("credits      777"))
        XCTAssertTrue(text.contains("control bits set (2)\n    b5 b900"))
        XCTAssertTrue(text.contains("FILES: pilot.json"))
        XCTAssertTrue(BugReportText.summary(note: "", stamp: "x", buildLines: [], dataSetLines: [],
                                            game: nil, state: s).contains("(no description given)"))
        let json = try XCTUnwrap(BugReportText.pilotJSON(s))
        XCTAssertNotNil(try? JSONDecoder().decode(PlayerState.self, from: json))
        XCTAssertEqual(BugReportText.log([]), "(no log entries — the process may have just started)")
        XCTAssertTrue(BugReportText.log([(Date(), "hello")]).hasSuffix("  hello"))
        XCTAssertEqual(BugReportText.timestamp().count, "2026-10-12-120000".count)
    }
}
