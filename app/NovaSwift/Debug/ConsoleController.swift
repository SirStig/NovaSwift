import Foundation

/// Command registry and parser for the in-game **command console**. Owns the
/// log tail (`ConsoleLogStore`) and whether the console is on screen; game-
/// specific commands (cheats, spawns, world edits) are registered onto it
/// once by `GameContainerView` — see `registerConsoleCommands()` — so this
/// type itself knows nothing about `DebugController`/`AppModel`.
///
/// A new command is purely additive: call `register` with a name, usage, and
/// a closure that returns the text to print (or throws a `CommandError` with
/// a message to print in red).
@MainActor
final class ConsoleController: ObservableObject {
    @Published var isPresented = false
    /// Which half of the dev console the narrow (phone) layout is showing.
    /// Ignored on wide screens, where both panes are on screen at once — see
    /// `DevConsoleView`. Set by whichever control opened the panel, so the
    /// terminal button lands on the command line and the metrics chip lands
    /// on the tools.
    @Published var tab: DevConsoleTab = .console
    let log = ConsoleLogStore()

    struct Command {
        let name: String
        let summary: String
        let usage: String
        let run: (_ args: [String]) throws -> String
    }

    struct CommandError: Error {
        let message: String
    }

    private(set) var commands: [String: Command] = [:]
    /// Every line submitted this session, oldest first — a `history` command
    /// reads it back; nothing else consumes it today.
    @Published private(set) var submittedHistory: [String] = []

    init() {
        registerBuiltins()
    }

    /// Adds (or replaces) a command. Re-registering the same name is fine —
    /// `registerConsoleCommands()` runs once per session, but a harmless
    /// no-op if a future caller calls it again.
    func register(_ command: Command) {
        commands[command.name] = command
    }

    /// Parse and run one line of input: echoes it, looks up the leading
    /// token as a command name, and prints whatever it returns (or its
    /// error). Silently ignores blank input.
    func submit(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        submittedHistory.append(trimmed)
        log.appendCommandEcho("> \(trimmed)")

        let tokens = Self.tokenize(trimmed)
        guard let name = tokens.first else { return }
        let args = Array(tokens.dropFirst())

        guard let command = commands[name.lowercased()] else {
            log.appendError("Unknown command: \(name). Type 'help' for a list.")
            return
        }
        do {
            let result = try command.run(args)
            if !result.isEmpty { log.appendOutput(result) }
        } catch let error as CommandError {
            log.appendError(error.message)
        } catch {
            log.appendError("\(error)")
        }
    }

    /// Whitespace-separated tokens, with `"quoted strings"` kept as one token
    /// (so e.g. a ship-name search can contain spaces).
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in input {
            if ch == "\"" {
                inQuotes.toggle()
                continue
            }
            if ch.isWhitespace, !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private func registerBuiltins() {
        register(Command(
            name: "help", summary: "List commands, or show usage for one.",
            usage: "help [command]"
        ) { [weak self] args in
            guard let self else { return "" }
            if let name = args.first {
                guard let c = self.commands[name.lowercased()] else {
                    throw CommandError(message: "Unknown command: \(name)")
                }
                return "\(c.usage)\n  \(c.summary)"
            }
            return self.commands.values
                .sorted { $0.name < $1.name }
                .map { "\($0.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \($0.summary)" }
                .joined(separator: "\n")
        })

        register(Command(
            name: "clear", summary: "Clear the console scrollback.", usage: "clear"
        ) { [weak self] _ in
            self?.log.clear()
            return ""
        })

        register(Command(
            name: "echo", summary: "Print the given text back.", usage: "echo <text>"
        ) { args in
            args.joined(separator: " ")
        })

        register(Command(
            name: "history", summary: "List commands run this session.", usage: "history"
        ) { [weak self] _ in
            guard let self, !self.submittedHistory.isEmpty else { return "No commands run yet." }
            return self.submittedHistory.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
        })
    }
}
