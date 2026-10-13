// Plain-Swift helpers for the bridge's pilot-file and async-load sections (`// MARK: Pilot files`
// and `// MARK: Async data load` in NovaWorld.swift). Same split as Story.swift: `@Godot`
// registers only what is declared in the class body, so the callables live in NovaWorld and
// this is the data and the pure logic they share.

import Foundation
import NovaSwiftEngine
import NovaSwiftKit
import NovaSwiftStory

/// Progress and result of `NovaWorld.loadGameAsync`. The worker thread writes, the main
/// thread (GDScript polling `loadStatus`) reads and adopts the result.
final class AsyncLoadState: @unchecked Sendable {
    private let lock = NSLock()
    private var _running = false
    private var _done = false
    private var _ok = false
    private var _phase = ""
    private var _fraction = 0.0
    private var _result: (NovaGame, Galaxy)?

    var running: Bool { lock.lock(); defer { lock.unlock() }; return _running }

    /// False when a load is already in flight.
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _running { return false }
        _running = true; _done = false; _ok = false; _phase = "Starting"; _fraction = 0; _result = nil
        return true
    }

    func report(_ phase: String, _ fraction: Double) {
        lock.lock(); _phase = phase; _fraction = fraction; lock.unlock()
    }

    func finish(_ result: (NovaGame, Galaxy)?) {
        lock.lock()
        _result = result; _ok = result != nil; _done = true; _running = false
        _phase = result != nil ? "Ready" : "Failed"; _fraction = 1
        lock.unlock()
    }

    /// Takes the finished result exactly once.
    func take() -> (NovaGame, Galaxy)? {
        lock.lock(); defer { lock.unlock() }
        let r = _result
        _result = nil
        return r
    }

    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["running": _running, "done": _done, "ok": _ok, "phase": _phase, "fraction": _fraction]
    }
}

enum PilotFiles {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// A native `.evpilot` (JSON `PilotSave`) at any path, or nil.
    static func decodeNative(_ url: URL) -> PilotSave? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(PilotSave.self, from: data)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func row(_ s: PilotSave) -> [String: Any] {
        ["kind": "evpilot", "id": s.id.uuidString, "name": s.displayName, "ship": s.snapshot.shipName,
         "system": s.snapshot.systemName, "credits": s.snapshot.credits,
         "rating": s.snapshot.ratingTitle, "scenario": s.scenarioName,
         "updated": stamp.string(from: s.updatedAt)]
    }

    static func summaryJSON(_ s: EVNovaPilotImportSummary, date: String) -> [String: Any] {
        ["kind": "original", "format": s.format.rawValue, "name": s.pilotName, "nickname": s.nickname,
         "ship": s.shipName.isEmpty || s.shipName == s.hullName ? s.hullName : "\(s.shipName) (\(s.hullName))",
         "credits": s.credits, "date": date, "location": s.location,
         "rating": "\(s.ratingTitle) (\(s.combatRating))",
         "story": "\(s.controlBits) control bits set, \(s.activeMissions) active mission(s)",
         "escorts": s.escorts, "warnings": s.warnings, "unmapped": s.unmapped]
    }
}
