import Foundation
import os

/// Always-on main-thread hang detector, cheap enough for every build.
///
/// A background thread pings the main queue every 100 ms. When the ping comes
/// back late — the main thread was stuck in something (file I/O, an audio
/// graph change, a SwiftUI re-layout, a GPU texture upload) — it logs
/// `MAIN THREAD BLOCKED <n> ms` with the last breadcrumb the app dropped via
/// `note(_:)`, and emits a signpost so the stall lines up in Instruments.
/// This catches stalls the scene's frame meter can't attribute: its CPU
/// phases only cover the game's own update.
/// `log stream --predicate 'subsystem == "com.novaswift.app" && category == "Perf"'`
final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()

    /// A main-thread stall longer than this is logged.
    static let thresholdMs = 250.0
    private static let pingInterval: TimeInterval = 0.1

    private let lock = NSLock()
    private var breadcrumb = "launch"
    private var breadcrumbAt = ProcessInfo.processInfo.systemUptime
    private var started = false

    /// Record what the app is doing now, for attribution if the main thread
    /// then stalls. Cheap; call from transitions (screen changes, saves,
    /// music starts), not per frame.
    static func note(_ what: String) {
        shared.lock.lock()
        shared.breadcrumb = what
        shared.breadcrumbAt = ProcessInfo.processInfo.systemUptime
        shared.lock.unlock()
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "NovaSwift.HangWatchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func run() {
        while true {
            let sent = ProcessInfo.processInfo.systemUptime
            let answered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { answered.signal() }
            // Wait in slices so a hang is reported once it ends, with its
            // full length, rather than every slice while it lasts.
            while answered.wait(timeout: .now() + Self.pingInterval) == .timedOut {}
            let ms = (ProcessInfo.processInfo.systemUptime - sent) * 1000
            // Over 30 s is the whole process having been suspended (iOS
            // background, system sleep), not a hang.
            if ms >= Self.thresholdMs, ms < 30_000 { report(ms: ms, startedAt: sent) }
            Thread.sleep(forTimeInterval: Self.pingInterval)
        }
    }

    private func report(ms: Double, startedAt: TimeInterval) {
        lock.lock()
        let crumb = breadcrumb
        let crumbAge = (startedAt - breadcrumbAt) * 1000
        lock.unlock()
        // A crumb dropped just before (or during) the stall is the likely cause.
        let when = crumbAge >= 0 ? "\(Int(crumbAge)) ms before" : "during"
        Log.perf.notice("""
            MAIN THREAD BLOCKED \(Int(ms), privacy: .public) ms — last: \(crumb, privacy: .public) \
            (\(when, privacy: .public) the stall)
            """)
        PerfMonitor.signposter.emitEvent("Main thread blocked", "\(Int(ms)) ms after \(crumb)")
    }
}
