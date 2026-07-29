import Foundation
import OSLog

/// Live scrollback for the in-game **command console** — the app's own
/// `Log.*` output (via `OSLogStore`, so no existing call site needs to know
/// the console exists) interleaved with typed command echoes/results.
///
/// Reads only this process's own log entries (`.currentProcessIdentifier`),
/// which needs no special entitlement, unlike reading the whole system log.
/// `OSLogStore` has no push/subscribe API, so freshness is a poll while the
/// console is open — cheap at the console's ~2/sec cadence and free the rest
/// of the time since `stopPolling()` tears the loop down on close.
@MainActor
final class ConsoleLogStore: ObservableObject {
    struct Line: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
        let kind: Kind

        enum Kind {
            case log(OSLogEntryLog.Level)
            case commandEcho
            case commandOutput
            case commandError
        }
    }

    @Published private(set) var lines: [Line] = []

    /// Oldest scrollback kept before older lines are dropped — a debug
    /// console that never trims would grow without bound over a long session.
    private static let capacity = 2000

    private var store: OSLogStore?
    private var pollTask: Task<Void, Never>?
    /// Only entries newer than this have not yet been shown. Seeded a short
    /// window into the past so opening the console mid-session shows recent
    /// context instead of starting blank.
    private var lastDate = Date(timeIntervalSinceNow: -30)

    /// Begin tailing the log while the console is on screen. Idempotent.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pull()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// Stop tailing once the console closes — no reason to keep reading the
    /// log store while nothing is showing it.
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pull() {
        if store == nil {
            store = try? OSLogStore(scope: .currentProcessIdentifier)
        }
        guard let store else { return }
        let position = store.position(date: lastDate)
        guard let entries = try? store.getEntries(at: position) else { return }

        var fresh: [Line] = []
        for entry in entries {
            guard entry.date > lastDate,
                  let log = entry as? OSLogEntryLog,
                  log.subsystem == Log.subsystem else { continue }
            fresh.append(Line(date: entry.date, text: "[\(log.category)] \(log.composedMessage)",
                              kind: .log(log.level)))
            lastDate = entry.date
        }
        guard !fresh.isEmpty else { return }
        append(fresh)
    }

    func appendCommandEcho(_ text: String) {
        append([Line(date: Date(), text: text, kind: .commandEcho)])
    }

    func appendOutput(_ text: String) {
        append([Line(date: Date(), text: text, kind: .commandOutput)])
    }

    func appendError(_ text: String) {
        append([Line(date: Date(), text: text, kind: .commandError)])
    }

    /// Clears the visible scrollback only — never rewinds `lastDate`, so a
    /// stray log entry racing the clear can't reappear as a "duplicate".
    func clear() {
        lines.removeAll()
    }

    private func append(_ new: [Line]) {
        lines.append(contentsOf: new)
        if lines.count > Self.capacity {
            lines.removeFirst(lines.count - Self.capacity)
        }
    }
}
