// NovaDebug — the Godot-visible façade over the Apple app's Debug suite (app/NovaSwift/Debug/).
//
// A second @Godot class beside NovaWorld (registered in NovaSwiftGodot.swift) so the whole dev
// console / diagnostics / NCB browser / bug report surface lives in this one file instead of
// growing NovaWorld. It holds a reference to the NovaWorld it drives (`attach`) and reaches the
// engine through NovaWorld's `dbg*` accessors (the `// MARK: Debug suite` extension at the end of
// NovaWorld.swift).
//
// The pure logic is shared, Foundation-only code in the root package (Sources/NovaSwiftStory/
// Debug*.swift, NCBIndex.swift, BugReportText.swift; Sources/NovaSwiftKit/FrameProfiler.swift,
// DebugEntityRef.swift, DebugLogSink.swift) — the Apple app calls the same types. What is
// bridge-side is the world-touching command closures (the Apple ones live inline in
// `GameContainerView.registerConsoleCommands` / `GameScene` "Debug suite" MARKs and touch
// SpriteKit scene state, so they cannot be shared as-is), the log capture sources and the
// marshalling. Lists cross as JSON strings, like the rest of the bridge.

import Foundation
import SwiftGodot
import NovaSwiftEngine
import NovaSwiftKit
import NovaSwiftStory
#if canImport(OSLog)
import OSLog
#endif

@Godot
class NovaDebug: RefCounted {

    // MARK: State

    private weak var host: NovaWorld?
    private let console = DebugConsole()
    private let log = DebugLogBuffer(capacity: 3000)
    private let profiler = FrameProfiler()
    private var commandsRegistered = false

    // Cheats / overlays (the Apple DebugController fields).
    private var godMode = false
    private var infiniteFuel = false
    private var aiOverlay = false
    private var uiGrid = false
    private var perfTestActive = false
    private var perfTestCount = 60
    /// Which kind the last `select`/`cycle` chose, so `selection()` is stable when both a ship
    /// and a stellar are targeted.
    private var preferStellar = false

    // Frame metrics reported by the frontend (it owns the clock and Godot's Performance monitors).
    private var fps = 0.0, frameMsAvg = 0.0, frameMsMax = 0.0, cpuMs = 0.0, renderMs = 0.0
    private var memoryMB = 0.0, nodeCount = 0
    private var lastSpikeMs = 0.0
    private var lastSpikePhases: [PerfPhase] = []
    private var profiledWorld: World?

    // Log capture.
    private var logStarted = false
    private var osLogPoller: Foundation.Thread?

    // NCB index (built off the main thread, once per data set).
    private let ncbLock = NSLock()
    private var ncbIndex = NCBIndex.empty
    private var ncbBuilding = false
    private var ncbBuiltFor: String?
    private var ncbReadyFlag = false

    // MARK: Attach

    /// Point the suite at the live `NovaWorld`. Idempotent; registers the commands once.
    @Callable(autoSnakeCase: true) func attach(world: NovaWorld) {
        host = world
        if !commandsRegistered {
            commandsRegistered = true
            registerCommands()
            console.onClear = { [weak self] in self?.log.clear() }
        }
    }

    // MARK: Console

    /// Run one line. Returns JSON `[{kind: echo|output|error, text}]` (also appended to the log).
    @Callable(autoSnakeCase: true) func consoleRun(line: String) -> String {
        let out = console.run(line)
        for o in out { log.append(o) }
        return Self.json(out.map { ["kind": $0.kind.rawValue, "text": $0.text] })
    }

    /// `[{name, summary, usage}]`, sorted by name.
    @Callable(autoSnakeCase: true) func consoleCommands() -> String {
        Self.json(console.commands.values.sorted { $0.name < $1.name }
            .map { ["name": $0.name, "summary": $0.summary, "usage": $0.usage] })
    }

    /// Tab completion of the first word; "" when there is nothing to complete.
    @Callable(autoSnakeCase: true) func consoleComplete(draft: String) -> String {
        console.complete(draft) ?? ""
    }

    /// Usage line + summary of the command being typed, "" when none.
    @Callable(autoSnakeCase: true) func consoleHint(draft: String) -> String {
        guard let name = DebugConsole.tokenize(draft).first, let c = console.commands[name.lowercased()] else { return "" }
        return "\(c.usage)  ·  \(c.summary)"
    }

    /// Commands whose names start with the typed first word: `[{name, summary}]`.
    @Callable(autoSnakeCase: true) func consoleMatches(draft: String) -> String {
        Self.json(console.matches(for: draft).prefix(12).map { ["name": $0.name, "summary": $0.summary] })
    }

    @Callable(autoSnakeCase: true) func consoleHistory() -> String { Self.json(console.history) }

    // MARK: Log

    /// Start capturing the engine's `Logging` output (stderr shim off-Apple, OSLogStore on Apple).
    /// Idempotent. Godot's own log is fed in by the GDScript `Logger` via `log_append`.
    @Callable(autoSnakeCase: true) func logStart() {
        guard !logStarted else { return }
        logStarted = true
        let buffer = log
        DebugLogSink.install { level, category, message in
            buffer.appendLog(level: DebugLogLevel(name: level), category: category, text: message)
        }
        #if canImport(OSLog)
        startOSLogPoller()
        #endif
    }

    /// Append a line from another source (Godot's own log / GDScript).
    @Callable(autoSnakeCase: true) func logAppend(level: String, category: String, text: String) {
        log.appendLog(level: DebugLogLevel(name: level), category: category, text: text)
    }

    @Callable(autoSnakeCase: true) func logClear() { log.clear() }

    @Callable(autoSnakeCase: true) func logCount() -> Int { log.count }

    @Callable(autoSnakeCase: true) func logLastId() -> Int { log.lastID }

    /// Entries newer than `sinceId` passing the filter. `filterJson`:
    /// `{mutedLevels: [0-4], mutedCategories: [...], search: ""}` (level 0 debug … 4 fault).
    /// Returns `{lastId, total, categories, entries: [{id, t, kind, level, cat, text, refs}]}`.
    @Callable(autoSnakeCase: true) func logQuery(sinceId: Int, filterJson: String, limit: Int) -> String {
        let entries = log.entries(sinceID: sinceId, filter: Self.parseFilter(filterJson), limit: max(1, limit))
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        let rows: [[String: Any]] = entries.map { e in
            var row: [String: Any] = ["id": e.id, "t": f.string(from: e.date), "text": e.displayText]
            switch e.kind {
            case let .log(level): row["kind"] = "log"; row["level"] = level.rawValue
            case .commandEcho: row["kind"] = "echo"
            case .commandOutput: row["kind"] = "output"
            case .commandError: row["kind"] = "error"
            }
            if let c = e.category { row["cat"] = c }
            let refs = e.entityRefs
            if !refs.isEmpty {
                row["refs"] = refs.map { ref -> [String: Any] in
                    switch ref {
                    case let .ship(id, name): return ["type": "ship", "id": id, "name": name]
                    case let .spob(id, name): return ["type": "spob", "id": id, "name": name]
                    }
                }
            }
            return row
        }
        return Self.json(["lastId": log.lastID, "total": log.count, "categories": log.categories(), "entries": rows] as [String: Any])
    }

    /// The log as plain text (for Copy), same filter as `logQuery`.
    @Callable(autoSnakeCase: true) func logText(filterJson: String, limit: Int) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        return log.entries(filter: Self.parseFilter(filterJson), limit: max(1, limit))
            .map { "\(f.string(from: $0.date))  \($0.displayText)" }.joined(separator: "\n")
    }

    private static func parseFilter(_ text: String) -> DebugLogBuffer.Filter {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .init() }
        let levels = (obj["mutedLevels"] as? [Int] ?? []).compactMap(DebugLogLevel.init(rawValue:))
        return .init(mutedLevels: Set(levels),
                     mutedCategories: Set(obj["mutedCategories"] as? [String] ?? []),
                     search: obj["search"] as? String ?? "")
    }

    #if canImport(OSLog)
    /// Apple: the engine's loggers are real `os.Logger`s and never reach `DebugLogSink`, so tail
    /// this process's own entries from OSLogStore on a utility thread (the store is slow to
    /// build and to query — never on the main thread; same constraint as the Apple console).
    private func startOSLogPoller() {
        let buffer = log
        let thread = Foundation.Thread {
            guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return }
            var cursor = Date(timeIntervalSinceNow: -15)
            let predicate = NSPredicate(format: "subsystem BEGINSWITH %@", "com.novaswift")
            while !Foundation.Thread.current.isCancelled {
                let emptyCursor = Date().addingTimeInterval(-1)
                var newest = cursor
                var got = 0
                if let entries = try? store.getEntries(with: [], at: store.position(date: cursor), matching: predicate) {
                    for entry in entries {
                        if got >= 400 { break }
                        guard let e = entry as? OSLogEntryLog else { continue }
                        if entry.date > newest { newest = entry.date }
                        guard entry.date > cursor else { continue }
                        let level: DebugLogLevel
                        switch e.level {
                        case .debug: level = .debug
                        case .info: level = .info
                        case .error: level = .error
                        case .fault: level = .fault
                        default: level = .notice
                        }
                        buffer.appendLog(level: level, category: e.category, text: e.composedMessage, date: entry.date)
                        got += 1
                    }
                }
                cursor = got == 0 ? emptyCursor : newest
                Foundation.Thread.sleep(forTimeInterval: 1)
            }
        }
        thread.qualityOfService = .utility
        thread.name = "novaswift.debug.oslog"
        thread.start()
        osLogPoller = thread
    }
    #endif

    // MARK: Diagnostics & behavioural tests

    /// The diagnostics battery over the loaded data, the live pilot and the live ship.
    @Callable(autoSnakeCase: true) func diagnosticsRun() -> String {
        Self.sectionsJSON(runDiagnostics())
    }

    /// The engine behavioural tests (throwaway `World`s; the live session is untouched).
    @Callable(autoSnakeCase: true) func testsRun() -> String {
        Self.sectionsJSON(DebugLiveTests.run())
    }

    private func runDiagnostics() -> [DiagnosticSection] {
        DebugDiagnostics.run(game: host?.dbgGame, pilot: host?.dbgPilot ?? PlayerState(),
                             liveShip: host?.dbgWorld?.player, liveHostiles: host?.dbgWorld.map { hostileCount($0) })
    }

    private static func sectionsJSON(_ sections: [DiagnosticSection]) -> String {
        let t = sections.tally
        return json([
            "pass": t.pass, "warn": t.warn, "fail": t.fail,
            "sections": sections.map { s -> [String: Any] in
                ["title": s.title,
                 "results": s.results.map { r -> [String: Any] in
                     ["name": r.name, "status": r.status.label, "detail": r.detail ?? ""]
                 }]
            },
        ] as [String: Any])
    }

    // MARK: Control-bit (NCB) browser

    /// Start building the bit cross-reference off the main thread (once per loaded data set).
    @Callable(autoSnakeCase: true) func ncbBuild() {
        guard let game = host?.dbgGame else { return }
        let key = Self.stamp(game)
        ncbLock.lock()
        if ncbBuiltFor == key || ncbBuilding { ncbLock.unlock(); return }
        ncbBuilding = true
        ncbLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let built = NCBIndex.build(from: game)
            ncbLock.lock()
            ncbIndex = built; ncbBuiltFor = key; ncbBuilding = false; ncbReadyFlag = true
            ncbLock.unlock()
        }
    }

    @Callable(autoSnakeCase: true) func ncbReady() -> Bool {
        ncbLock.lock(); defer { ncbLock.unlock() }
        return ncbReadyFlag
    }

    /// Cheap identity for a loaded data set (NovaGame is a value type).
    private static func stamp(_ game: NovaGame) -> String {
        "\(game.ships().count)/\(game.outfits().count)/\(game.missions().count)/\(game.systems().count)"
    }

    private func currentIndex() -> NCBIndex {
        ncbLock.lock(); defer { ncbLock.unlock() }
        return ncbIndex
    }

    /// Bits for the browser: `filter` is "all" (every referenced or held bit), "held" or
    /// "orphans" (held but referenced nowhere); `query` matches the number or a resource name.
    /// Returns `{total, held, shown, bits: [{bit, set, writers, tests}]}` capped at `limit`.
    @Callable(autoSnakeCase: true) func ncbBits(filter: String, query: String, limit: Int) -> String {
        let index = currentIndex()
        let held = host?.dbgPilot.setBits ?? []
        let universe: [Int]
        switch filter {
        case "held": universe = held.sorted()
        case "orphans": universe = held.subtracting(index.bits).sorted()
        default: universe = Array(Set(index.bits).union(held)).sorted()
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matched = q.isEmpty ? universe : universe.filter {
            "\($0)".contains(q) || (index.searchText[$0]?.contains(q) ?? false)
        }
        let rows: [[String: Any]] = matched.prefix(max(1, limit)).map { bit in
            let refs = index.references(for: bit)
            let tests = refs.filter(\.isTest).count
            return ["bit": bit, "set": held.contains(bit), "writers": refs.count - tests, "tests": tests]
        }
        return Self.json(["total": matched.count, "held": held.count, "shown": rows.count,
                          "ready": ncbReady(), "bits": rows] as [String: Any])
    }

    /// SET BY / CLEARED BY / TOGGLED BY / TESTED BY for one bit:
    /// `{bit, set, refs: [{role: set|clear|toggle|test, negated, kind, id, name, field, text}]}`.
    @Callable(autoSnakeCase: true) func ncbExplain(bit: Int) -> String {
        let index = currentIndex()
        let refs: [[String: Any]] = index.references(for: bit).map { r in
            var role = "set", negated = false
            switch r.role {
            case .set: role = "set"
            case .clear: role = "clear"
            case .toggle: role = "toggle"
            case let .test(n): role = "test"; negated = n
            }
            return ["role": role, "negated": negated, "kind": r.kind, "id": r.resourceID,
                    "name": r.resourceName, "field": r.field, "text": NCBIndex.describe(r)]
        }
        return Self.json(["bit": bit, "set": host?.dbgPilot.setBits.contains(bit) ?? false, "refs": refs] as [String: Any])
    }

    // MARK: Browsers (ships / outfits / governments)

    /// `[{id, name, stats, owned?}]` ships matching `query` (name substring or exact id).
    @Callable(autoSnakeCase: true) func shipsJson(query: String, limit: Int) -> String {
        guard let game = host?.dbgGame else { return "[]" }
        let q = query.trimmingCharacters(in: .whitespaces)
        let rows = game.ships().sorted { $0.displayName < $1.displayName }
            .filter { q.isEmpty || $0.displayName.localizedCaseInsensitiveContains(q) || "\($0.id)" == q }
            .prefix(max(1, limit))
        return Self.json(rows.map { s -> [String: Any] in
            ["id": s.id, "name": s.displayName,
             "stats": "S\(s.shield) A\(s.armor) · spd \(s.speed) trn \(s.turnRate) · \(Self.abbrev(s.cost))",
             "detail": game.descText(13000 + s.id - 128)]
        })
    }

    @Callable(autoSnakeCase: true) func outfitsJson(query: String, limit: Int) -> String {
        guard let game = host?.dbgGame else { return "[]" }
        let q = query.trimmingCharacters(in: .whitespaces)
        let owned = host?.dbgPilot.outfits ?? [:]
        let rows = game.outfits().sorted { $0.outfitterDisplayName < $1.outfitterDisplayName }
            .filter { q.isEmpty || $0.outfitterDisplayName.localizedCaseInsensitiveContains(q) || "\($0.id)" == q }
            .prefix(max(1, limit))
        return Self.json(rows.map { o -> [String: Any] in
            var parts = [Self.abbrev(o.cost), "\(o.mass)t", "tech \(o.techLevel)"]
            if let mod = o.modifiers.first { parts.append("\(mod.type)".replacingOccurrences(of: "_", with: " ")) }
            return ["id": o.id, "name": o.outfitterDisplayName, "stats": parts.joined(separator: " · "),
                    "owned": owned[o.id] ?? 0, "detail": game.descText(o.id - 128 + 3000)]
        })
    }

    @Callable(autoSnakeCase: true) func govtsJson(query: String, limit: Int) -> String {
        guard let game = host?.dbgGame, let pilot = host?.dbgPilot else { return "[]" }
        let q = query.trimmingCharacters(in: .whitespaces)
        let map = game.reputationMap()
        let rows = game.govts().sorted { $0.name < $1.name }
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || "\($0.id)" == q }
            .prefix(max(1, limit))
        return Self.json(rows.map { g -> [String: Any] in
            // The worst record the player holds in any of this government's systems (EC-02).
            let record = map.ids.filter { map.govt(of: $0) == g.id }.map { pilot.reputation(atSystem: $0) }.min() ?? 0
            return ["id": g.id, "name": g.name.isEmpty ? "Govt #\(g.id)" : g.name, "record": record,
                    "stats": "record \(record) · \(g.allies.count) allies · \(g.enemies.count) enemies",
                    "color": [Int(g.mapColor.r), Int(g.mapColor.g), Int(g.mapColor.b)]] as [String: Any]
        })
    }

    private static func abbrev(_ credits: Int) -> String {
        let v = Double(credits)
        if abs(v) >= 1_000_000 { return String(format: "%.1fM cr", v / 1_000_000) }
        if abs(v) >= 1_000 { return String(format: "%.1fk cr", v / 1_000) }
        return "\(credits) cr"
    }

    // MARK: Live game state

    /// Everything the Game State pane shows, as JSON: pilot, live ship, fleet, cheats, outfits.
    @Callable(autoSnakeCase: true) func stateJson() -> String {
        guard let host else { return "{}" }
        let pilot = host.dbgPilot
        let game = host.dbgGame
        var out: [String: Any] = [
            "pilot": [
                "name": pilot.pilotName, "credits": pilot.credits, "combatRating": pilot.combatRating,
                "date": pilot.date.description, "shipType": pilot.shipType,
                "shipName": game?.ship(pilot.shipType)?.displayName ?? "?",
                "system": pilot.currentSystem, "systemName": game?.system(pilot.currentSystem)?.displayName ?? "?",
                "landed": pilot.landedSpob ?? -1,
                "reputationHere": pilot.reputationHere,
                "bitsSet": pilot.setBits.count,
                "bits": pilot.setBits.sorted(),
                "activeMissions": pilot.activeMissions.count,
                "cargoTons": pilot.cargo.values.reduce(0, +),
                "outfits": pilot.outfits.sorted { $0.key < $1.key }.map { id, n -> [String: Any] in
                    ["id": id, "name": game?.outfit(id)?.outfitterDisplayName ?? "??", "count": n]
                },
            ] as [String: Any],
            "cheats": ["god": godMode, "fuel": infiniteFuel, "ai": aiOverlay, "uidebug": uiGrid,
                       "perf": perfTestActive, "perfCount": perfTestCount] as [String: Any],
            "hasGame": game != nil,
        ]
        if let w = host.dbgWorld {
            let p = w.player
            out["ship"] = [
                "name": p.name, "shipType": p.shipTypeID,
                "shield": p.shield, "maxShield": p.maxShield, "armor": p.armor, "maxArmor": p.maxArmor,
                "fuel": p.fuel, "maxFuel": p.maxFuel, "speed": p.velocity.length,
                "maxSpeed": p.stats.maxSpeed, "x": p.position.x, "y": p.position.y,
                "alive": p.isAlive, "weapons": p.weapons.count, "invulnerable": p.invulnerable,
            ] as [String: Any]
            out["world"] = [
                "system": host.dbgSystemID ?? -1, "ships": w.npcs.filter { $0.isAlive }.count,
                "hostiles": hostileCount(w), "escorts": w.playerEscorts.count,
                "projectiles": w.projectiles.count, "asteroids": w.asteroids.count,
                "docked": host.dbgDockedSpob ?? -1,
            ] as [String: Any]
        }
        return Self.json(out)
    }

    /// The live selection (target ship or selected stellar): `{type, id, name}` or "{}".
    @Callable(autoSnakeCase: true) func selectionJson() -> String {
        guard let ref = selection() else { return "{}" }
        switch ref {
        case let .ship(id, name): return Self.json(["type": "ship", "id": id, "name": name] as [String: Any])
        case let .spob(id, name): return Self.json(["type": "spob", "id": id, "name": name] as [String: Any])
        }
    }

    private func selection() -> DevEntityRef? {
        guard let host, let w = host.dbgWorld else { return nil }
        var ship: DevEntityRef?
        if let tid = w.player.currentTargetID, let t = w.ship(id: tid), t.isAlive {
            ship = .ship(id: tid, name: t.name)
        }
        var spob: DevEntityRef?
        if let sid = host.dbgSelectedStellar {
            spob = .spob(id: sid, name: host.dbgGame?.spob(sid)?.name ?? "")
        }
        return preferStellar ? (spob ?? ship) : (ship ?? spob)
    }

    // MARK: Per-frame hooks

    /// Call once per frame: holds the continuous cheats (god mode, infinite fuel — the Apple
    /// scene's `applyDebugCheats`) and wires the engine's phase profiler while the suite is open.
    @Callable(autoSnakeCase: true) func frameTick(profiling: Bool) {
        guard let w = host?.dbgWorld else { return }
        let player = w.player
        if player.invulnerable != godMode { player.invulnerable = godMode }
        if godMode {
            player.shield = player.maxShield
            player.armor = player.maxArmor
            player.ionCharge = 0
        }
        if infiniteFuel, player.maxFuel > 0 { player.fuel = player.maxFuel }
        if profiling {
            if profiledWorld !== w {
                profiledWorld = w
                profiler.reset()
                w.profiler = { [profiler] name, seconds in profiler.record(name, seconds: seconds) }
            }
        } else if profiledWorld != nil {
            profiledWorld?.profiler = nil
            profiledWorld = nil
        }
    }

    /// Frontend-measured metrics (it owns the frame clock): called a few times a second.
    @Callable(autoSnakeCase: true) func metricsReport(fps: Double, frameMsAvg: Double, frameMsMax: Double,
                                                      cpuMs: Double, renderMs: Double, memoryMb: Double,
                                                      nodes: Int) {
        self.fps = fps; self.frameMsAvg = frameMsAvg; self.frameMsMax = frameMsMax
        self.cpuMs = cpuMs; self.renderMs = renderMs; self.memoryMB = memoryMb; self.nodeCount = nodes
    }

    /// Fold one frontend-measured phase (ms) into the frame profiler.
    @Callable(autoSnakeCase: true) func profileRecord(name: String, ms: Double) {
        profiler.record(name, seconds: ms / 1000)
    }

    /// Close a profiled frame; remembers the frame as the last spike when it crossed
    /// `spikeThresholdMs`. Returns the spike's ms (0 when ordinary).
    @Callable(autoSnakeCase: true) func profileEndFrame(spikeThresholdMs: Double) -> Double {
        if let spike = profiler.endFrame(spikeThresholdMs: spikeThresholdMs) {
            lastSpikeMs = spike.frameMs
            lastSpikePhases = spike.phases
            return spike.frameMs
        }
        return 0
    }

    /// The window's per-phase breakdown (worst first) plus counts, as the Performance section
    /// reads it: `{fps, frameMsAvg, frameMsMax, cpuMs, renderMs, memoryMb, ships, shots, roids,
    /// nodes, spikeMs, spike: [...], phases: [{name, avgMs, worstMs}]}`. Resets the window.
    @Callable(autoSnakeCase: true) func profileSnapshot() -> String {
        let phases = profiler.snapshot()
        let w = host?.dbgWorld
        func rows(_ p: [PerfPhase]) -> [[String: Any]] {
            p.map { ["name": $0.name, "avgMs": $0.avgMs, "worstMs": $0.worstMs] }
        }
        return Self.json([
            "fps": fps, "frameMsAvg": frameMsAvg, "frameMsMax": frameMsMax, "cpuMs": cpuMs, "renderMs": renderMs,
            "memoryMb": memoryMB, "nodes": nodeCount,
            "ships": w?.npcs.filter { $0.isAlive }.count ?? 0, "shots": w?.projectiles.count ?? 0,
            "roids": w?.asteroids.count ?? 0, "perfTest": perfTestActive,
            "spikeMs": lastSpikeMs, "spike": rows(lastSpikePhases), "phases": rows(phases),
        ] as [String: Any])
    }

    // MARK: AI overlay

    /// One row per live NPC for the AI overlay: world position, an abbreviated state, colour
    /// class, and the points its combat-target / leader lines run to (engine coordinates).
    @Callable(autoSnakeCase: true) func aiOverlayRows() -> String {
        guard aiOverlay, let w = host?.dbgWorld else { return "[]" }
        var rows: [[String: Any]] = []
        for npc in w.npcs where npc.isAlive {
            guard let brain = npc.brain else { continue }
            var text = Self.aiAbbrev(brain.state)
            if let tid = brain.targetID { text += "→\(tid)" }
            if brain.leaderID != nil { text += " E\(brain.formationSlot)" }
            var row: [String: Any] = ["id": npc.entityID, "x": npc.position.x, "y": npc.position.y,
                                      "r": npc.radius, "text": text, "kind": Self.aiColorClass(brain.state)]
            if let tid = brain.targetID ?? npc.currentTargetID, let t = w.ship(id: tid) {
                row["tx"] = t.position.x; row["ty"] = t.position.y
            }
            if let lid = brain.leaderID, let l = w.ship(id: lid) {
                row["lx"] = l.position.x; row["ly"] = l.position.y
            }
            rows.append(row)
        }
        return Self.json(rows)
    }

    private static func aiAbbrev(_ s: AIState) -> String {
        switch s {
        case .spawning: return "SPAWN"
        case .traveling: return "TRVL"
        case .landing: return "LAND"
        case .docked: return "DOCK"
        case .patrolling: return "PATRL"
        case .orbiting: return "ORBIT"
        case .attacking: return "ATK"
        case .fleeing: return "FLEE"
        case .departing: return "DEPRT"
        case .escorting: return "ESCRT"
        case .assisting: return "ASSIST"
        case .scanning: return "SCAN"
        }
    }

    /// red = combat, amber = flee/depart, cyan = travel, green = escort/assist, grey = idle.
    private static func aiColorClass(_ s: AIState) -> String {
        switch s {
        case .attacking: return "red"
        case .fleeing, .departing: return "amber"
        case .traveling, .landing: return "cyan"
        case .escorting, .assisting: return "green"
        default: return "grey"
        }
    }

    // MARK: Bug report

    /// Assemble the bug-report bundle's text files (the Apple `BugReport.make`, minus the zip
    /// and the share sheet — the frontend zips with `ZIPPacker` and reveals the file).
    /// Returns `{stamp, summary, files: {name: text}}`. `buildInfo` is the app/engine version
    /// line, `osInfo` the OS/GPU line, `pluginsInfo` the enabled plug-ins (names only).
    @Callable(autoSnakeCase: true) func bugReportFiles(note: String, buildInfo: String, osInfo: String,
                                                       pluginsInfo: String) -> String {
        let game = host?.dbgGame
        let pilot = host?.dbgPilot ?? PlayerState()
        let stamp = BugReportText.timestamp()
        let baseLine = game == nil ? "NOT LOADED" : "loaded"
        let summary = BugReportText.summary(
            note: note, stamp: stamp,
            buildLines: ["  app          \(buildInfo)", "  os           \(osInfo)"],
            dataSetLines: ["  base data    \(baseLine)",
                           "  plug-ins     \(pluginsInfo.isEmpty ? "none enabled" : pluginsInfo)"],
            game: game, state: pilot)
        var files: [String: String] = ["report.txt": summary]
        if let json = BugReportText.pilotJSON(pilot), let text = String(data: json, encoding: .utf8) {
            files["pilot.json"] = text
        }
        if game != nil { files["diagnostics.txt"] = BugReportText.diagnostics(runDiagnostics()) }
        files["console.log"] = BugReportText.log(log.recent(limit: 4000).map { ($0.date, $0.displayText) })
        Log.pilot.notice("BugReport.make: assembled \(files.count) file(s) for \(stamp)")
        return Self.json(["stamp": stamp, "summary": summary, "files": files] as [String: Any])
    }

    // MARK: Command registry

    private func hostileCount(_ w: World) -> Int {
        w.npcs.filter { $0.isAlive && isHostileToPlayer($0, w) }.count
    }

    private func isHostileToPlayer(_ s: Ship, _ w: World) -> Bool {
        if s.brain?.provokedByPlayer == true { return true }
        return w.diplomacy?.areEnemies(s.government, w.player.government) ?? false
    }

    private func fail(_ message: String) -> DebugConsole.CommandError { .init(message: message) }

    private func requireWorld() throws -> (NovaWorld, World) {
        guard let host, let w = host.dbgWorld else { throw fail("No live scene.") }
        return (host, w)
    }

    private func requireGame() throws -> NovaGame {
        guard let g = host?.dbgGame else { throw fail("No game data loaded.") }
        return g
    }

    private func armedHulls(_ galaxy: Galaxy) -> [Int] {
        let all = galaxy.game.ships().map { $0.id }
        let armed = all.filter { galaxy.shipSpec($0)?.mounts.isEmpty == false }
        return Array((armed.isEmpty ? all : armed).prefix(16))
    }

    private enum Disposition { case hostile, escort, neutral }

    @discardableResult
    private func spawnShip(hull: Int, as d: Disposition) -> Bool {
        guard let host, let w = host.dbgWorld, let galaxy = host.dbgGalaxy else { return false }
        let player = w.player
        let bearing = w.rng.double(in: 0...(2 * .pi))
        let dist = w.rng.double(in: 400...800)
        let pos = player.position + Vec2(sin(bearing), cos(bearing)) * dist
        let ang = (player.position - pos).angle
        let team: Int? = d == .escort ? player.government : nil
        guard let ship = galaxy.makeLoadedShip(hull, government: team, at: pos, angle: ang,
                                               skillScale: galaxy.skillVarianceScale(classOf: hull, rng: &w.rng)) else { return false }
        switch d {
        case .hostile:
            let brain = AIBrain(aiType: .interceptor, govt: ship.government)
            brain.provokedByPlayer = true
            brain.targetID = player.entityID
            ship.brain = brain
            _ = w.addNPC(ship, arrival: .hyperspace)
        case .escort:
            _ = w.addNPC(ship, arrival: .hyperspace)
            w.recruitEscort(ship)
        case .neutral:
            ship.brain = AIBrain(aiType: .braveTrader, govt: ship.government)
            _ = w.addNPC(ship, arrival: .hyperspace)
        }
        return true
    }

    private func registerCommands() {
        let c = console
        func reg(_ name: String, _ summary: String, _ usage: String,
                 _ run: @escaping ([String]) throws -> String) {
            c.register(.init(name: name, summary: summary, usage: usage, run: run))
        }
        let onOff = DebugConsole.onOff

        reg("god", "Toggle god mode (no damage).", "god [on|off]") { [unowned self] a in
            godMode = try onOff(a, godMode)
            return "God mode: \(godMode ? "on" : "off")"
        }
        reg("fuel", "Toggle infinite fuel.", "fuel [on|off]") { [unowned self] a in
            infiniteFuel = try onOff(a, infiniteFuel)
            return "Infinite fuel: \(infiniteFuel ? "on" : "off")"
        }
        reg("ai", "Toggle the AI state/paths overlay.", "ai [on|off]") { [unowned self] a in
            aiOverlay = try onOff(a, aiOverlay)
            return "AI overlay: \(aiOverlay ? "on" : "off")"
        }
        reg("uidebug", "Toggle the UI measurement grid.", "uidebug [on|off]") { [unowned self] a in
            uiGrid = try onOff(a, uiGrid)
            return "UI debug grid: \(uiGrid ? "on" : "off")"
        }
        reg("heal", "Full shield + armor on the live ship.", "heal") { [unowned self] _ in
            let (_, w) = try requireWorld()
            w.player.shield = w.player.maxShield
            w.player.armor = w.player.maxArmor
            return "Healed."
        }
        reg("refuel", "Fill the live ship's fuel tank.", "refuel") { [unowned self] _ in
            let (h, w) = try requireWorld()
            w.player.fuel = w.player.maxFuel
            h.dbgPilot.fuel = w.player.maxFuel
            h.dbgPersistPilot()
            return "Refueled."
        }
        reg("credits", "Add or set the pilot's credits.", "credits <add|set> <amount>") { [unowned self] a in
            guard let h = host else { throw fail("No game loaded.") }
            var p = h.dbgPilot
            let r = try DebugPilotOps.credits(a, state: &p)
            h.dbgPilot = p
            h.dbgPersistPilot()
            return r
        }
        reg("fps", "Print the current performance snapshot.", "fps") { [unowned self] _ in
            let w = host?.dbgWorld
            return String(format: "%.0f fps · frame %.1fms (worst %.1fms) · %d ships, %d shots, %d roids, %d nodes",
                          fps, frameMsAvg, frameMsMax, w?.npcs.filter { $0.isAlive }.count ?? 0,
                          w?.projectiles.count ?? 0, w?.asteroids.count ?? 0, nodeCount)
        }
        reg("perf", "Start/stop the performance stress test.", "perf <start [count]|stop>") { [unowned self] a in
            guard let sub = a.first else { throw fail("Usage: perf <start [count]|stop>") }
            switch sub.lowercased() {
            case "start":
                if let n = a.dropFirst().first.flatMap(Int.init) { perfTestCount = max(0, n) }
                try startStressTest(count: perfTestCount)
                perfTestActive = true
                return "Stress test started with \(perfTestCount) ships."
            case "stop":
                stopStressTest()
                perfTestActive = false
                return "Stress test stopped."
            default: throw fail("Expected start/stop, got '\(sub)'")
            }
        }
        reg("clearnpcs", "Remove every NPC from the live system.", "clearnpcs") { [unowned self] _ in
            let (_, w) = try requireWorld()
            let n = w.npcs.count
            w.removeAllNPCs()
            return "Cleared \(n) ship\(n == 1 ? "" : "s")."
        }
        reg("killhostiles", "Destroy every hostile in the live system.", "killhostiles") { [unowned self] _ in
            let (_, w) = try requireWorld()
            var n = 0
            for s in w.npcs where s.isAlive && isHostileToPlayer(s, w) { s.shield = 0; s.armor = 0; n += 1 }
            return "Destroyed \(n) ship\(n == 1 ? "" : "s")."
        }
        reg("hd", "HD / 3D graphics: unavailable in the Godot build.", "hd [status|on|off|detail|3d|overlay|reload|clearcache|view]") { _ in
            "HD / 3D graphics (NovaSwiftHD packs, the bake cache and the viewer) are Apple-only and not part of the Godot build."
        }
        reg("spawn", "Spawn a ship by id, hostile/escort/neutral.", "spawn <hostile|escort|neutral> <shipID> [count]") { [unowned self] a in
            guard a.count >= 2, let hull = Int(a[1]) else { throw fail("Usage: spawn <hostile|escort|neutral> <shipID> [count]") }
            let d: Disposition
            switch a[0].lowercased() {
            case "hostile": d = .hostile
            case "escort": d = .escort
            case "neutral": d = .neutral
            default: throw fail("Expected hostile/escort/neutral, got '\(a[0])'")
            }
            let count = a.dropFirst(2).first.flatMap(Int.init) ?? 1
            var spawned = 0
            for _ in 0..<max(1, count) where spawnShip(hull: hull, as: d) { spawned += 1 }
            return spawned > 0 ? "Spawned \(spawned) × #\(hull) (\(a[0]))." : "Couldn't spawn #\(hull) — no live scene?"
        }
        reg("ship", "Set the pilot's current hull by id or name.", "ship <id|name…>") { [unowned self] a in
            guard let h = host else { throw fail("No game loaded.") }
            let game = try requireGame()
            let s = try DebugPilotOps.resolveShip(a, game: game)
            var p = h.dbgPilot
            p.shipType = s.id
            p.shipName = s.displayName
            h.dbgPilot = p
            h.dbgPersistPilot()
            return "Current ship set to #\(s.id) \(s.displayName) — applies on next takeoff/jump/landing (or run 'rebuild')."
        }
        reg("rebuild", "Rebuild the flight ship now from the pilot's hull and outfits.", "rebuild") { [unowned self] _ in
            let (h, _) = try requireWorld()
            guard h.dbgDockedSpob == nil else { throw fail("Docked — the takeoff rebuild applies the changes.") }
            h.dbgRebuildShip()
            return "Ship rebuilt."
        }
        reg("outfit", "Grant or remove an outfit.", "outfit <add|remove> <outfitID> [count]") { [unowned self] a in
            guard let h = host else { throw fail("No game loaded.") }
            let game = try requireGame()
            var p = h.dbgPilot
            let r = try DebugPilotOps.outfit(a, state: &p, game: game)
            h.dbgPilot = p
            h.dbgPersistPilot()
            return r
        }
        reg("outfits", "Grant one of every outfit you lack, or clear them all.", "outfits <all|clear>") { [unowned self] a in
            guard let h = host else { throw fail("No game loaded.") }
            let game = try requireGame()
            var p = h.dbgPilot
            switch a.first?.lowercased() {
            case "all":
                for o in game.outfits() where (p.outfits[o.id] ?? 0) == 0 { p.grantOutfit(o.id) }
            case "clear": p.outfits = [:]
            default: throw fail("Usage: outfits <all|clear>")
            }
            h.dbgPilot = p
            h.dbgPersistPilot()
            return "Outfits: \(p.outfits.values.reduce(0, +)) item(s) — applies on next ship rebuild."
        }
        reg("relation", "Set the legal record in the current system.", "relation <value>") { [unowned self] a in
            guard let h = host else { throw fail("No game loaded.") }
            var p = h.dbgPilot
            let r = try DebugPilotOps.relation(a, state: &p)
            h.dbgPilot = p
            h.dbgWorld?.diplomacy?.setReputationHere(r.value)
            h.dbgPersistPilot()
            return "Reputation in system #\(r.system) set to \(r.value)."
        }
        reg("bit", "Set/clear/toggle a control bit, or explain one.", "bit <set|clear|toggle|info> <n>") { [unowned self] a in
            guard let h = host else { throw fail("No game loaded.") }
            if a.first?.lowercased() == "info", !ncbReady() {
                // `bit info` needs the cross-reference; build it now if the browser never did.
                if let game = h.dbgGame {
                    let built = NCBIndex.build(from: game)
                    ncbLock.lock(); ncbIndex = built; ncbBuiltFor = Self.stamp(game); ncbReadyFlag = true; ncbLock.unlock()
                }
            }
            var p = h.dbgPilot
            let r = try DebugPilotOps.bit(a, state: &p, index: currentIndex())
            h.dbgPilot = p
            if a.first?.lowercased() != "info" { h.dbgPersistPilot() }
            return r
        }
        reg("date", "Advance the galaxy date, or set it.", "date +<days> | date set <day> <month> <year>") { [unowned self] a in
            guard let h = host else { throw fail("No game loaded.") }
            var p = h.dbgPilot
            let r: String
            if a.first?.lowercased() == "set" {
                guard a.count == 4, let d = Int(a[1]), let m = Int(a[2]), let y = Int(a[3]),
                      (1...31).contains(d), (1...12).contains(m), y >= 0 else {
                    throw fail("Usage: date set <day 1-31> <month 1-12> <year>")
                }
                p.date = GameDate(day: d, month: m, year: y)
                r = "Date: \(p.date.description)"
            } else {
                r = try DebugPilotOps.date(a, state: &p)
            }
            h.dbgPilot = p
            h.dbgPersistPilot()
            return r
        }
        reg("rating", "Set the pilot's combat rating.", "rating <n>") { [unowned self] a in
            guard let h = host, a.count == 1, let n = Int(a[0]), n >= 0 else { throw fail("Usage: rating <n>") }
            h.dbgPilot.combatRating = n
            h.dbgPersistPilot()
            return "Combat rating: \(n)"
        }
        reg("set", "Set shield/armor/fuel on the live ship to a percentage.", "set <shield|armor|fuel> <0-100>") { [unowned self] a in
            let (h, w) = try requireWorld()
            guard a.count == 2, let pct = Double(a[1]) else { throw fail("Usage: set <shield|armor|fuel> <0-100>") }
            let f = max(0, min(100, pct)) / 100
            let p = w.player
            switch a[0].lowercased() {
            case "shield": p.shield = f * p.maxShield
            case "armor": p.armor = f * p.maxArmor
            case "fuel":
                p.fuel = f * p.maxFuel
                h.dbgPilot.fuel = p.fuel
                h.dbgPersistPilot()
            default: throw fail("Expected shield/armor/fuel, got '\(a[0])'")
            }
            return "\(a[0]) → \(Int(f * 100))%"
        }
        reg("damage", "Knock shields to 0 and armor to 10% on the live ship.", "damage") { [unowned self] _ in
            let (_, w) = try requireWorld()
            w.player.shield = 0
            w.player.armor = max(1, w.player.maxArmor * 0.1)
            return "Damaged."
        }
        reg("escorts", "Recruit N friendly escorts (varied armed hulls).", "escorts <count>") { [unowned self] a in
            let (h, w) = try requireWorld()
            guard let galaxy = h.dbgGalaxy else { throw fail("No game data loaded.") }
            let n = max(1, a.first.flatMap(Int.init) ?? 1)
            let hulls = armedHulls(galaxy)
            guard !hulls.isEmpty else { throw fail("No hulls available.") }
            var spawned = 0
            for i in 0..<n where spawnShip(hull: hulls[i % hulls.count], as: .escort) { spawned += 1 }
            _ = w
            return "Recruited \(spawned) escort\(spawned == 1 ? "" : "s")."
        }
        reg("hostiles", "Spawn/disable/destroy hostiles.", "hostiles <spawn [n]|disable|destroy>") { [unowned self] a in
            let (h, w) = try requireWorld()
            switch a.first?.lowercased() {
            case "spawn":
                guard let galaxy = h.dbgGalaxy else { throw fail("No game data loaded.") }
                let n = max(1, a.dropFirst().first.flatMap(Int.init) ?? 1)
                let hulls = armedHulls(galaxy)
                guard !hulls.isEmpty else { throw fail("No hulls available.") }
                var spawned = 0
                for i in 0..<n where spawnShip(hull: hulls[i % hulls.count], as: .hostile) { spawned += 1 }
                return "Spawned \(spawned) attacker\(spawned == 1 ? "" : "s") on the player."
            case "disable":
                var n = 0
                for s in w.npcs where s.isAlive && !s.disabled && isHostileToPlayer(s, w) {
                    s.shield = 0
                    s.armor = max(1, s.maxArmor * 0.05)
                    s.disabled = true
                    n += 1
                }
                return "Disabled \(n) ship\(n == 1 ? "" : "s")."
            case "destroy":
                return try console.commands["killhostiles"]!.run([])
            default: throw fail("Usage: hostiles <spawn [n]|disable|destroy>")
            }
        }
        reg("select", "Select a live ship or stellar by id.", "select <ship|spob> <id>") { [unowned self] a in
            guard a.count == 2, let id = Int(a[1]) else { throw fail("Usage: select <ship|spob> <id>") }
            let (h, w) = try requireWorld()
            switch a[0].lowercased() {
            case "ship":
                guard let ship = w.ship(id: id), ship !== w.player, w.selectTarget(id: id) != nil else {
                    throw fail("No live ship #\(id).")
                }
                preferStellar = false
                return "Selected ship #\(id) \(ship.name)."
            case "spob":
                let name = h.dbgGame?.spob(id)?.name ?? ""
                guard h.dbgSelectStellar(id) else { throw fail("#\(id) isn't a stellar in this system.") }
                preferStellar = true
                return "Selected stellar #\(id)\(name.isEmpty ? "" : " \(name)")."
            default: throw fail("Expected ship/spob, got '\(a[0])'")
            }
        }

        // Entity-action commands take a ship entityID or `selected` (the live selection).
        func shipID(_ a: [String]) throws -> Int {
            if let raw = a.first, raw.lowercased() != "selected", let id = Int(raw) { return id }
            if case let .ship(id, _)? = selection() { return id }
            throw fail("No ship selected — pass an id or select one first.")
        }
        func spobID(_ a: [String]) throws -> Int {
            if let raw = a.first, raw.lowercased() != "selected", let id = Int(raw) { return id }
            if case let .spob(id, _)? = selection() { return id }
            throw fail("No stellar selected — pass an id or select one first.")
        }
        func liveNPC(_ id: Int) throws -> Ship {
            let (_, w) = try requireWorld()
            guard let s = w.ship(id: id), s !== w.player, s.isAlive else { throw fail("No live ship #\(id).") }
            return s
        }
        reg("destroy", "Dev-tools kill a ship.", "destroy <id|selected>") { [unowned self] a in
            let id = try shipID(a)
            let s = try liveNPC(id)
            s.shield = 0; s.armor = 0       // the next despawn sweep clears it as a kill (wreck + explosion)
            note("debugDestroyShip: killed \(Self.tagShip(id, s.name))")
            return "Destroyed ship #\(id)."
        }
        reg("disable", "Dev-tools disable a ship.", "disable <id|selected>") { [unowned self] a in
            let id = try shipID(a)
            let s = try liveNPC(id)
            s.disabled = true
            note("debugDisableShip: disabled \(Self.tagShip(id, s.name))")
            return "Disabled ship #\(id)."
        }
        reg("capture", "Dev-tools cheat-capture a ship as an escort.", "capture <id|selected>") { [unowned self] a in
            let id = try shipID(a)
            let s = try liveNPC(id)
            let (h, w) = try requireWorld()
            // Apple: scene.recruitCapturedEscort + registerEscort(.captured) + tagEscort.
            w.recruitEscort(s)
            let name = s.name.isEmpty ? (h.dbgGame?.ship(s.shipTypeID)?.name ?? "Escort") : s.name
            let rec = h.dbgPilot.registerEscort(shipType: s.shipTypeID, name: name, origin: .captured)
            s.escortRecordID = rec.id
            h.dbgPersistPilot()
            if let g = h.dbgGame { h.dbgPost(OriginalText(game: g).capturedAsEscortLine) }   // #123
            return "Captured \(s.name.isEmpty ? "ship #\(id)" : s.name) as an escort."
        }
        reg("conquer", "Dev-tools instantly dominate a stellar (skips the defense fight).", "conquer <id|selected>") { [unowned self] a in
            let id = try spobID(a)
            let (h, w) = try requireWorld()
            guard let spob = h.dbgGame?.spob(id) else { throw fail("No stellar #\(id).") }
            let name = spob.name.isEmpty ? "#\(id)" : spob.name
            let already = w.dominatedStellars.contains(id)
            w.debugForceDominate(spobID: id)
            guard !already, w.dominatedStellars.contains(id) else {
                return "\(name) is already dominated, or isn't a stellar in this system."
            }
            note("debugConquerStellar: dominated \(Self.tagSpob(id, spob.name))")
            return "\(name) dominated."
        }
        reg("cycle", "Cycle the ship/planet selection.", "cycle <ships|planets> [next|prev]") { [unowned self] a in
            guard let kind = a.first else { throw fail("Usage: cycle <ships|planets> [next|prev]") }
            let reverse = a.dropFirst().first?.lowercased() == "prev"
            let (h, w) = try requireWorld()
            switch kind.lowercased() {
            case "ships":
                _ = w.cyclePlayerTarget(forward: !reverse, squad: false)
                preferStellar = false
            case "planets":
                let ids = w.systemContext.bodies.map(\.id)
                guard !ids.isEmpty else { break }
                let cur = h.dbgSelectedStellar.flatMap { ids.firstIndex(of: $0) }
                let step = reverse ? -1 : 1
                let next = (((cur.map { $0 + step } ?? 0) % ids.count) + ids.count) % ids.count
                _ = h.dbgSelectStellar(ids[next])
                preferStellar = true
            default: throw fail("Expected ships/planets, got '\(kind)'")
            }
            guard let ref = selection() else { return "Nothing in range to select." }
            return "Selected \(ref.name.isEmpty ? "#\(ref.id)" : ref.name)."
        }
    }

    // MARK: Stress test (GameScene.startPerformanceTest / stopPerformanceTest)

    private func startStressTest(count: Int) throws {
        guard let host, let w = host.dbgWorld, let galaxy = host.dbgGalaxy else { throw fail("No live scene.") }
        w.spawner = nil
        w.removeAllNPCs()
        // Two mutually-hostile governments (a real enemy pair from the diplomacy table if any).
        var pair = (independentGovt, independentGovt)
        if let dip = w.diplomacy {
            let ids = Array(dip.govts.keys)
            if let found = ids.lazy.compactMap({ a in ids.first(where: { $0 != a && dip.areEnemies(a, $0) }).map { (a, $0) } }).first {
                pair = found
            } else if ids.count >= 2 {
                pair = (ids[0], ids[1])
            }
        }
        let hulls = armedHulls(galaxy)
        guard !hulls.isEmpty else { throw fail("No ship hulls resolvable in the data — cannot spawn a fleet.") }
        let center = w.systemContext.center
        let cloud = max(700.0, 90.0 * Double(count).squareRoot())
        for i in 0..<max(0, count) {
            let team = i % 2 == 0 ? pair.0 : pair.1
            let hull = hulls[i % hulls.count]
            let bearing = w.rng.double(in: 0...(2 * .pi))
            let dist = w.rng.double(in: 0...cloud)
            let pos = center + Vec2(sin(bearing), cos(bearing)) * dist
            let ang = w.rng.double(in: 0...(2 * .pi))
            guard let ship = galaxy.makeLoadedShip(hull, government: team, at: pos, angle: ang,
                                                   skillScale: galaxy.skillVarianceScale(classOf: hull, rng: &w.rng)) else { continue }
            ship.brain = AIBrain(aiType: .warship, govt: team)
            _ = w.addNPC(ship, arrival: .populate)
        }
        note("startPerformanceTest: spawned \(count) combatants (govts \(pair.0) vs \(pair.1), \(hulls.count) hull types)")
    }

    private func stopStressTest() {
        guard let host, let w = host.dbgWorld, let galaxy = host.dbgGalaxy else { return }
        w.removeAllNPCs()
        if let sysID = host.dbgSystemID, let sys = galaxy.game.system(sysID) {
            let spawner = Spawner(galaxy: galaxy, table: SpawnTable(system: sys))
            w.spawner = spawner
            spawner.populate(w)
        }
        note("stopPerformanceTest: fleet cleared, ambient spawner restored")
    }

    // MARK: Helpers

    private static func tagShip(_ id: Int, _ name: String) -> String { "«ship:\(id):\(name)»" }
    private static func tagSpob(_ id: Int, _ name: String) -> String { "«spob:\(id):\(name)»" }

    /// A notice-level line from the suite itself, tagged so the console filters can find it.
    private func note(_ text: String) { log.appendLog(level: .notice, category: "Debug", text: text) }

    static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}
