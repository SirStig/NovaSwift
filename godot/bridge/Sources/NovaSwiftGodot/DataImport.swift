// Plain-Swift state for the bridge's `// MARK: Game data import` callables (NovaWorld.swift).
// Same split as PilotFiles.swift: `@Godot` registers only what is declared in the class body, so
// the callables are one-liners in NovaWorld and the logic is `NovaSwiftPluginStore.GameDataImport`
// (shared Swift core). The bridge only plumbs: inspect / start / status / cancel.

import Foundation
import NovaSwiftPluginStore

final class DataImportBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var job: GameDataImport.Job?
    private var inspecting = false
    private var inspectDone = false
    private var inspectResult: GameDataImport.Inspection?
    private var inspectCancel = false

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    private static func json<T: Encodable>(_ v: T) -> String {
        (try? String(data: encoder.encode(v), encoding: .utf8)) ?? "{}"
    }

    /// Synchronous inspection. `deep` parses every container (seconds on a full install): use
    /// `inspectStart` from the UI.
    func inspect(path: String, deep: Bool) -> String {
        let ins = GameDataImport.inspect(URL(fileURLWithPath: path), deep: deep)
        return Self.json(ins)
    }

    func inspectStart(path: String) -> Bool {
        lock.lock()
        if inspecting { lock.unlock(); return false }
        inspecting = true; inspectDone = false; inspectCancel = false
        lock.unlock()
        Thread.detachNewThread { [self] in
            let ins = GameDataImport.inspect(URL(fileURLWithPath: path), deep: true,
                                             cancelled: { self.lock.lock(); defer { self.lock.unlock() }; return self.inspectCancel })
            lock.lock(); inspectResult = ins; inspecting = false; inspectDone = true; lock.unlock()
        }
        return true
    }

    /// `{running, done, result: Inspection}`.
    func inspectStatus() -> String {
        lock.lock(); defer { lock.unlock() }
        struct S: Encodable { var running: Bool; var done: Bool; var result: GameDataImport.Inspection? }
        return Self.json(S(running: inspecting, done: inspectDone, result: inspectResult))
    }

    func inspectCancelNow() { lock.lock(); inspectCancel = true; lock.unlock() }

    func start(path: String, destination: String, includePlugins: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let j = job, j.snapshot().running { return false }
        let j = GameDataImport.Job(source: URL(fileURLWithPath: path), destination: URL(fileURLWithPath: destination),
                                   includePlugins: includePlugins)
        job = j
        j.start()
        return true
    }

    func status() -> String {
        lock.lock(); let j = job; lock.unlock()
        if let j { return Self.json(j.snapshot()) }
        return "{\"running\":false,\"done\":false}"
    }

    func cancel() { lock.lock(); let j = job; lock.unlock(); j?.cancel() }

    func discard() { GameDataImport.discardExtractions() }
}
