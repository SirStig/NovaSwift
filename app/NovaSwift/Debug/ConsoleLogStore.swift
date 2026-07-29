import Foundation
import OSLog

/// Live scrollback for the in-game console — the app's own `Log.*` output
/// (read back through `OSLogStore`, so no existing call site needs to know the
/// console exists) interleaved with typed command echoes and results.
///
/// Reads only this process's own entries (`.currentProcessIdentifier`), which
/// needs no special entitlement unlike reading the whole system log.
///
/// **All store work happens off the main thread.** `OSLogStore` is a
/// synchronous, genuinely expensive API: constructing one takes seconds, and
/// each query decodes and formats entries. Run on the main actor it blocks the
/// render/sim thread outright — the game drops to single-digit fps and hitches
/// in time with the poll. `LogTail` therefore owns the store on its own serial
/// queue and only Sendable results cross back.
@MainActor
final class ConsoleLogStore: ObservableObject {
    struct Line: Identifiable, Sendable {
        let id: UUID
        let date: Date
        let text: String
        let kind: Kind
        /// `text` split into plain runs and `«ship:…»`/`«spob:…»` entity
        /// markers (`DevLogLinking`), computed once here rather than per
        /// render — the console pane renders this instead of raw `text` so a
        /// tagged entity shows as a clickable chip.
        let segments: [DevLogLinking.Segment]

        init(id: UUID, date: Date, text: String, kind: Kind) {
            self.id = id
            self.date = date
            self.text = text
            self.kind = kind
            self.segments = DevLogLinking.segments(in: text)
        }

        enum Kind: Sendable {
            case log(Severity)
            case commandEcho
            case commandOutput
            case commandError
        }

        /// Our own severity, rather than re-exporting `OSLogEntryLog.Level` —
        /// keeps the view layer off OSLog and the type trivially Sendable.
        /// Named for the console's filter UI: OSLog's 5 native levels
        /// (`debug`/`info`/`default`/`error`/`fault`) read most usefully to a
        /// developer as Debug/Info/Notice/Warning/Critical.
        enum Severity: CaseIterable, Hashable, Sendable {
            case debug, info, notice, error, fault

            var displayName: String {
                switch self {
                case .debug: return "Debug"
                case .info: return "Info"
                case .notice: return "Notice"
                case .error: return "Warning"
                case .fault: return "Critical"
                }
            }
        }
    }

    @Published private(set) var lines: [Line] = []

    /// Oldest scrollback kept before older lines are dropped. Deliberately
    /// modest: every retained line is an element SwiftUI's `ForEach` has to
    /// diff on each redraw, so a huge buffer costs frame time for scrollback
    /// nobody reads.
    private static let capacity = 600
    /// Slow enough to stay invisible next to a 60fps frame budget, fast enough
    /// to read as live.
    private static let pollInterval = Duration.seconds(1)

    private var pollTask: Task<Void, Never>?

    /// Begin tailing the log while the console is on screen. Idempotent.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            // Seed a short window back so opening mid-session shows recent
            // context instead of starting blank.
            var cursor = Date(timeIntervalSinceNow: -15)
            while !Task.isCancelled {
                let batch = await LogTail.pull(since: cursor)
                cursor = batch.cursor
                if !batch.lines.isEmpty { self?.append(batch.lines) }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// Stop tailing once the console closes — no reason to keep querying the
    /// log store while nothing is showing it.
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func appendCommandEcho(_ text: String) { append([line(text, .commandEcho)]) }
    func appendOutput(_ text: String) { append([line(text, .commandOutput)]) }
    func appendError(_ text: String) { append([line(text, .commandError)]) }

    /// Clears the visible scrollback only — never rewinds the tail cursor, so
    /// an entry racing the clear can't reappear as a duplicate.
    func clear() { lines.removeAll() }

    private func line(_ text: String, _ kind: Line.Kind) -> Line {
        Line(id: UUID(), date: Date(), text: text, kind: kind)
    }

    private func append(_ new: [Line]) {
        lines.append(contentsOf: new)
        if lines.count > Self.capacity {
            lines.removeFirst(lines.count - Self.capacity)
        }
    }
}

/// The off-main half: owns the `OSLogStore` and answers one query at a time on
/// its own serial queue.
private enum LogTail {
    struct Batch: Sendable {
        let lines: [ConsoleLogStore.Line]
        /// Where the next poll should resume from.
        let cursor: Date
    }

    /// Holds the store across calls (building one is the expensive part, so it
    /// must not be rebuilt per poll). Only ever touched on `queue`.
    private final class Holder: @unchecked Sendable { var store: OSLogStore? }

    private static let holder = Holder()
    private static let queue = DispatchQueue(label: "com.novaswift.console.logtail", qos: .utility)
    /// Pushes the subsystem filter down into the store, so it never decodes or
    /// formats entries belonging to other subsystems in this process.
    private static let predicate = NSPredicate(format: "subsystem == %@", Log.subsystem)
    /// Bounds the work of any single poll — a burst of logging must not turn
    /// one query into an unbounded scan.
    private static let maxPerPull = 400

    static func pull(since cursor: Date) async -> Batch {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: fetch(since: cursor)) }
        }
    }

    private static func fetch(since cursor: Date) -> Batch {
        // Captured before the query: with the subsystem predicate applied in
        // the store, an empty result really does mean "no app logs in this
        // window", so the cursor can safely skip past it. (Not doing this is
        // what made every poll re-scan an ever-growing window.) The second of
        // slack absorbs entries that land with a slightly earlier timestamp
        // than when they were written.
        let emptyCursor = Date().addingTimeInterval(-1)

        if holder.store == nil {
            holder.store = try? OSLogStore(scope: .currentProcessIdentifier)
        }
        guard let store = holder.store else { return Batch(lines: [], cursor: emptyCursor) }

        let position = store.position(date: cursor)
        guard let entries = try? store.getEntries(with: [], at: position, matching: predicate) else {
            return Batch(lines: [], cursor: emptyCursor)
        }

        var lines: [ConsoleLogStore.Line] = []
        var newest = cursor
        for entry in entries {
            if lines.count >= maxPerPull { break }
            guard let log = entry as? OSLogEntryLog else { continue }
            if entry.date > newest { newest = entry.date }
            guard entry.date > cursor else { continue }
            lines.append(ConsoleLogStore.Line(
                id: UUID(), date: entry.date,
                text: "[\(log.category)] \(log.composedMessage)",
                kind: .log(severity(log.level))))
        }
        return Batch(lines: lines, cursor: lines.isEmpty ? emptyCursor : newest)
    }

    private static func severity(_ level: OSLogEntryLog.Level) -> ConsoleLogStore.Line.Severity {
        switch level {
        case .debug: return .debug
        case .info: return .info
        case .error: return .error
        case .fault: return .fault
        default: return .notice
        }
    }
}
