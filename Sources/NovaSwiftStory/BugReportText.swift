import Foundation
import NovaSwiftKit

/// Platform-free assembly of the bug-report bundle's text files (`report.txt`, `diagnostics.txt`,
/// `console.log`, `pilot.json`). The Apple app (`BugReport`) and the Godot debug suite both build
/// their zips from these; only the I/O (log source, zip, share/reveal) differs per platform.
///
/// What goes in — and what deliberately doesn't: pilot state, logs and diagnostics only. No
/// decoded resources, no copy of the imported `Nova Files`: the BYO-data model means a bug report
/// must never become a way to pass that data around. Plug-ins are listed by name and id only.
public enum BugReportText {

    public static let fileNames = ["report.txt", "pilot.json", "diagnostics.txt", "console.log"]

    public static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: date)
    }

    /// The pilot save, pretty-printed — "the single most useful file in the bundle: it's a repro".
    public static func pilotJSON(_ state: PlayerState) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(state)
    }

    /// `report.txt`. `buildLines` are the already-indented rows under BUILD (app version, device,
    /// OS); `dataSetLines` the rows under DATA SET before the counts (base data, plug-ins).
    public static func summary(note: String, stamp: String,
                               buildLines: [String], dataSetLines: [String],
                               game: NovaGame?, state: PlayerState) -> String {
        var out: [String] = []

        out.append("NovaSwift bug report — \(stamp)")
        out.append(String(repeating: "=", count: 60))
        out.append("")
        out.append("WHAT HAPPENED")
        out.append(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                   ? "(no description given)"
                   : note.trimmingCharacters(in: .whitespacesAndNewlines))
        out.append("")

        out.append("BUILD")
        out.append(contentsOf: buildLines)
        out.append("")

        out.append("DATA SET")
        out.append(contentsOf: dataSetLines)
        if let game {
            out.append("  counts       \(game.ships().count) ships · \(game.outfits().count) outfits · \(game.systems().count) systems · \(game.missions().count) missions")
        }
        out.append("")

        out.append("PILOT")
        out.append("  name         \(state.pilotName)")
        out.append("  date         \(state.date.day)/\(state.date.month)/\(state.date.year)")
        out.append("  credits      \(state.credits)")
        out.append("  ship         \(game?.ship(state.shipType)?.displayName ?? "?") (#\(state.shipType))\(state.shipName.isEmpty ? "" : " \"\(state.shipName)\"")")
        let system = game?.system(state.currentSystem)
        out.append("  system       \(system?.displayName ?? "?") (#\(state.currentSystem))")
        out.append("  landed at    \(state.landedSpob.map { "\(game?.spob($0)?.displayName ?? "?") (#\($0))" } ?? "in flight")")
        out.append("  combat rtg   \(state.combatRating)")
        out.append("  explored     \(state.exploredSystems.count) system(s), \(state.chartedSystems?.count ?? 0) charted")
        out.append("")

        out.append("  outfits owned")
        if state.outfits.isEmpty {
            out.append("    (none)")
        } else {
            for (id, n) in state.outfits.sorted(by: { $0.key < $1.key }) {
                out.append("    ×\(n)  #\(id)  \(game?.outfit(id)?.outfitterDisplayName ?? "??")")
            }
        }
        out.append("")

        out.append("  cargo held")
        if state.cargo.isEmpty {
            out.append("    (empty)")
        } else {
            for (id, n) in state.cargo.sorted(by: { $0.key < $1.key }) {
                out.append("    \(n)t  #\(id)")
            }
        }
        out.append("")

        out.append("  active missions")
        if state.activeMissions.isEmpty {
            out.append("    (none)")
        } else {
            for m in state.activeMissions {
                out.append("    #\(m.missionID)  \(game?.mission(m.missionID)?.displayName ?? "??")")
            }
        }
        out.append("")

        out.append("  legal record (per system)")
        let records = (state.systemReputation ?? [:]).filter { $0.value != 0 }
        if state.systemReputation == nil {
            out.append("    (not migrated yet)")
        } else if records.isEmpty {
            out.append("    (clean everywhere)")
        } else {
            for (system, value) in records.sorted(by: { $0.key < $1.key }) {
                out.append("    \(value >= 0 ? "+" : "")\(value)  \(game?.system(system)?.name ?? "system #\(system)")")
            }
        }
        out.append("")

        // Control bits are the single most common cause of "why is the game
        // behaving like this?" and the hardest thing to ask a tester about, so
        // the full set ships verbatim. `console.log` says who set each one (see
        // `StoryEngine.apply(set:source:)`).
        out.append("  control bits set (\(state.setBits.count))")
        out.append("    \(state.setBits.isEmpty ? "(none)" : state.setBits.sorted().map { "b\($0)" }.joined(separator: " "))")
        out.append("")
        out.append("FILES: pilot.json (full save) · diagnostics.txt (self-test) · console.log (last 15 min, incl. every control-bit write and its source)")
        return out.joined(separator: "\n")
    }

    /// `diagnostics.txt`.
    public static func diagnostics(_ sections: [DiagnosticSection]) -> String {
        var out: [String] = ["NovaSwift self-test", String(repeating: "=", count: 60)]
        for section in sections {
            out.append("")
            out.append(section.title.uppercased())
            for r in section.results {
                out.append("  [\(r.status.label)] \(r.name)\(r.detail.map { " — \($0)" } ?? "")")
            }
        }
        return out.joined(separator: "\n")
    }

    /// `console.log`: "HH:mm:ss.SSS  text" per line.
    public static func log(_ lines: [(date: Date, text: String)]) -> String {
        guard !lines.isEmpty else {
            return "(no log entries — the process may have just started)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return lines.map { "\(formatter.string(from: $0.date))  \($0.text)" }
            .joined(separator: "\n")
    }
}
