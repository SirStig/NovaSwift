import Foundation
import NovaSwiftKit

// Shared (Foundation-only) core of the dev console: the command registry/parser and the
// level/category-filtered in-memory log. The Apple app keeps its own `ConsoleController` /
// `ConsoleLogStore` (SwiftUI + OSLogStore); the Godot debug suite drives these. Behaviour is
// deliberately identical (same tokenizer, same builtins, same severity names).

// MARK: - Command registry

public final class DebugConsole {
    public struct CommandError: Error {
        public let message: String
        public init(message: String) { self.message = message }
    }

    public struct Command {
        public let name: String
        public let summary: String
        public let usage: String
        public let run: (_ args: [String]) throws -> String

        public init(name: String, summary: String, usage: String,
                    run: @escaping (_ args: [String]) throws -> String) {
            self.name = name; self.summary = summary; self.usage = usage; self.run = run
        }
    }

    public struct Output: Sendable {
        public enum Kind: String, Sendable { case echo, output, error }
        public let kind: Kind
        public let text: String
    }

    public private(set) var commands: [String: Command] = [:]
    /// Every line submitted this session, oldest first.
    public private(set) var history: [String] = []
    /// Called by the builtin `clear`.
    public var onClear: (() -> Void)?

    public init() { registerBuiltins() }

    public func register(_ command: Command) { commands[command.name] = command }

    /// Parse and run one line: returns the echo plus the result (or error) lines. Blank input
    /// yields nothing.
    @discardableResult
    public func run(_ raw: String) -> [Output] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        history.append(trimmed)
        var out = [Output(kind: .echo, text: "> \(trimmed)")]
        let tokens = Self.tokenize(trimmed)
        guard let name = tokens.first else { return out }
        guard let command = commands[name.lowercased()] else {
            out.append(Output(kind: .error, text: "Unknown command: \(name). Type 'help' for a list."))
            return out
        }
        do {
            let result = try command.run(Array(tokens.dropFirst()))
            if !result.isEmpty { out.append(Output(kind: .output, text: result)) }
        } catch let error as CommandError {
            out.append(Output(kind: .error, text: error.message))
        } catch {
            out.append(Output(kind: .error, text: "\(error)"))
        }
        return out
    }

    /// Whitespace-separated tokens, with `"quoted strings"` kept as one token.
    public static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in input {
            if ch == "\"" { inQuotes.toggle(); continue }
            if ch.isWhitespace, !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Command names starting with the first word typed so far (empty once a space is typed).
    public func matches(for draft: String) -> [Command] {
        let typed = draft.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typed.isEmpty, !typed.contains(" ") else { return [] }
        return commands.values.filter { $0.name.hasPrefix(typed) && $0.name != typed }
            .sorted { $0.name < $1.name }
    }

    /// Tab completion: the single match plus a space, or the longest shared prefix; nil when
    /// there is nothing to complete (same rule as the Apple console).
    public func complete(_ draft: String) -> String? {
        let names = matches(for: draft).map(\.name)
        guard let first = names.first else { return nil }
        if names.count == 1 { return first + " " }
        var prefix = first
        for name in names.dropFirst() {
            while !name.hasPrefix(prefix) { prefix.removeLast() }
        }
        return prefix.count > draft.trimmingCharacters(in: .whitespaces).count ? prefix : nil
    }

    /// `on` / `off` (or true/false/1/0) -> Bool; no argument toggles `current`.
    public static func onOff(_ args: [String], current: Bool) throws -> Bool {
        guard let raw = args.first else { return !current }
        switch raw.lowercased() {
        case "on", "true", "1": return true
        case "off", "false", "0": return false
        default: throw CommandError(message: "Expected on/off, got '\(raw)'")
        }
    }

    private func registerBuiltins() {
        register(Command(name: "help", summary: "List commands, or show usage for one.",
                         usage: "help [command]") { [weak self] args in
            guard let self else { return "" }
            if let name = args.first {
                guard let c = self.commands[name.lowercased()] else {
                    throw CommandError(message: "Unknown command: \(name)")
                }
                return "\(c.usage)\n  \(c.summary)"
            }
            return self.commands.values.sorted { $0.name < $1.name }
                .map { "\($0.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \($0.summary)" }
                .joined(separator: "\n")
        })
        register(Command(name: "clear", summary: "Clear the console scrollback.", usage: "clear") { [weak self] _ in
            self?.onClear?()
            return ""
        })
        register(Command(name: "echo", summary: "Print the given text back.", usage: "echo <text>") { args in
            args.joined(separator: " ")
        })
        register(Command(name: "history", summary: "List commands run this session.", usage: "history") { [weak self] _ in
            guard let self, !self.history.isEmpty else { return "No commands run yet." }
            return self.history.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        })
    }
}

// MARK: - Log buffer

/// Our own severity (same five levels and names as the Apple console's filter UI).
public enum DebugLogLevel: Int, CaseIterable, Sendable {
    case debug = 0, info, notice, error, fault

    public var displayName: String {
        switch self {
        case .debug: return "Debug"
        case .info: return "Info"
        case .notice: return "Notice"
        case .error: return "Warning"
        case .fault: return "Critical"
        }
    }

    /// Maps `os.Logger` level names and Godot's own ("warning", "err") onto our levels.
    public init(name: String) {
        switch name.lowercased() {
        case "debug": self = .debug
        case "info": self = .info
        case "error", "err", "warning", "warn": self = .error
        case "fault", "critical", "fatal": self = .fault
        default: self = .notice
        }
    }
}

public struct DebugLogEntry: Sendable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case log(DebugLogLevel)
        case commandEcho, commandOutput, commandError
    }
    public let id: Int
    public let date: Date
    public let kind: Kind
    /// Log category ("AI", "Pilot", "Godot"...); nil for console echoes/results.
    public let category: String?
    public let text: String

    public var level: DebugLogLevel? {
        if case let .log(l) = kind { return l }
        return nil
    }
    /// Ships/stellars tagged in the text (`«ship:id:name»`), as the console renders chips.
    public var entityRefs: [DevEntityRef] {
        DevLogLinking.segments(in: text).compactMap {
            if case let .entity(ref) = $0 { return ref }
            return nil
        }
    }
    /// The text as shown: "[Category] message" for log lines (matches the Apple console).
    public var displayText: String {
        if case .log = kind, let category { return "[\(category)] \(text)" }
        return text
    }
}

/// Thread-safe ring buffer. Writers (the log sink, Godot's logger, the console) can be on any
/// thread; the frontend polls with `entries(sinceID:)`.
public final class DebugLogBuffer: @unchecked Sendable {
    public struct Filter: Sendable {
        public var mutedLevels: Set<DebugLogLevel> = []
        public var mutedCategories: Set<String> = []
        public var search = ""
        public init(mutedLevels: Set<DebugLogLevel> = [], mutedCategories: Set<String> = [], search: String = "") {
            self.mutedLevels = mutedLevels; self.mutedCategories = mutedCategories; self.search = search
        }
        public var isActive: Bool {
            !mutedLevels.isEmpty || !mutedCategories.isEmpty
                || !search.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private let lock = NSLock()
    private var buffer: [DebugLogEntry] = []
    private var nextID = 1
    public let capacity: Int

    public init(capacity: Int = 3000) { self.capacity = max(10, capacity) }

    public func appendLog(level: DebugLogLevel, category: String, text: String, date: Date = Date()) {
        append(.log(level), category: category, text: text, date: date)
    }
    public func appendEcho(_ text: String) { append(.commandEcho, category: nil, text: text, date: Date()) }
    public func appendOutput(_ text: String) { append(.commandOutput, category: nil, text: text, date: Date()) }
    public func appendError(_ text: String) { append(.commandError, category: nil, text: text, date: Date()) }

    /// Routes a console result into the buffer.
    public func append(_ output: DebugConsole.Output) {
        switch output.kind {
        case .echo: appendEcho(output.text)
        case .output: appendOutput(output.text)
        case .error: appendError(output.text)
        }
    }

    private func append(_ kind: DebugLogEntry.Kind, category: String?, text: String, date: Date) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(DebugLogEntry(id: nextID, date: date, kind: kind, category: category, text: text))
        nextID += 1
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
    }

    /// Clears the visible scrollback; ids keep increasing so a poller never re-reads old rows.
    public func clear() { lock.lock(); buffer.removeAll(); lock.unlock() }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return buffer.count }
    public var lastID: Int { lock.lock(); defer { lock.unlock() }; return nextID - 1 }

    /// Entries newer than `sinceID` that pass `filter`, oldest first, capped to the newest `limit`.
    public func entries(sinceID: Int = 0, filter: Filter = Filter(), limit: Int = 500) -> [DebugLogEntry] {
        lock.lock(); let snapshot = buffer; lock.unlock()
        let query = filter.search.trimmingCharacters(in: .whitespaces)
        var out = snapshot.filter { e in
            guard e.id > sinceID else { return false }
            if case let .log(level) = e.kind {
                if filter.mutedLevels.contains(level) { return false }
                if let c = e.category, filter.mutedCategories.contains(c) { return false }
            }
            if !query.isEmpty, !e.displayText.localizedCaseInsensitiveContains(query) { return false }
            return true
        }
        if out.count > limit { out.removeFirst(out.count - limit) }
        return out
    }

    /// Categories seen so far, in first-seen order (the category filter chips).
    public func categories() -> [String] {
        lock.lock(); let snapshot = buffer; lock.unlock()
        var seen = Set<String>(), order: [String] = []
        for e in snapshot { if let c = e.category, seen.insert(c).inserted { order.append(c) } }
        return order
    }

    /// Newest `limit` entries for a bug report, unfiltered.
    public func recent(limit: Int = 4000) -> [DebugLogEntry] { entries(limit: limit) }
}
