import Foundation
import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory
import NovaSwiftPluginStore
#if canImport(UIKit)
import UIKit
#endif

/// Packages everything needed to diagnose a bug into one shareable `.zip`.
///
/// The app already *collects* almost everything a report needs — the console
/// tails this process's own log, the pilot is plain `Codable` JSON, and
/// `DebugDiagnostics` can self-check the data set, the save and the live world.
/// None of it could leave the device, so a tester's only channel was a
/// screenshot and a sentence of prose, and reconstructing what their save
/// actually looked like meant reading raw `.rez` bytes by hand.
///
/// **What goes in — and what deliberately doesn't.** Pilot state, logs and
/// diagnostics only. No decoded resources, no sprites, no copy of the imported
/// `Nova Files`: the project's BYO-data model means the player brings their own
/// EV Nova install, and a bug report must never become a way to pass that data
/// around. Plug-ins are listed by name and id, never attached.
@MainActor
enum BugReport {

    /// A finished report on disk, ready to hand to `ShareLink`.
    struct Bundle {
        /// The `.zip`, written under Documents/Diagnostics so it's also reachable
        /// over Finder file sharing if the share sheet is awkward on the device.
        let url: URL
        /// The same headline the report opens with, shown in the UI so the
        /// reporter can see what they're about to send.
        let summary: String
    }

    /// Build the bundle. Off-main work (log read, zip) is awaited, so call this
    /// from a `Task` and show progress — a long session's log can take a moment.
    static func make(note: String,
                     model: AppModel,
                     pilot: PilotStore,
                     debug: DebugController?) async throws -> Bundle {
        let stamp = Self.timestamp()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("novaswift-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let summary = Self.summaryText(note: note, model: model, pilot: pilot, stamp: stamp)
        try Data(summary.utf8).write(to: staging.appendingPathComponent("report.txt"))

        // The save itself: bits, outfits, hull, system, missions, legal record.
        // This is the single most useful file in the bundle — it's a repro.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let json = try? encoder.encode(pilot.state) {
            try json.write(to: staging.appendingPathComponent("pilot.json"))
        }

        if let game = model.data.game {
            let sections = DebugDiagnostics.run(game: game,
                                                pilot: pilot.state,
                                                liveShip: debug?.scene?.playerShip,
                                                liveHostiles: debug?.scene?.liveHostileCount)
            try Data(Self.diagnosticsText(sections).utf8)
                .write(to: staging.appendingPathComponent("diagnostics.txt"))
        }

        let log = await ConsoleLogStore.snapshot()
        try Data(Self.logText(log).utf8)
            .write(to: staging.appendingPathComponent("console.log"))

        // Zip, then park it somewhere the reporter can find it again.
        let zipped = try GameDataArchiver.zip(directory: staging)
        let destination = try Self.reportsDirectory()
            .appendingPathComponent("NovaSwift-report-\(stamp).zip")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: zipped, to: destination)

        Log.pilot.notice("BugReport.make: wrote \(destination.lastPathComponent, privacy: .public) (\(destination.fileSizeDescription, privacy: .public))")
        return Bundle(url: destination, summary: summary)
    }

    /// Previously written reports, newest first — so a reporter who dismissed
    /// the share sheet can get back to one instead of regenerating it.
    static func existingReports() -> [URL] {
        guard let dir = try? reportsDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        return urls.filter { $0.pathExtension == "zip" }.sorted {
            ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast)
        }
    }

    /// `Documents/Diagnostics`. Documents (not Application Support, where saves
    /// live) because that's the only directory `UIFileSharingEnabled` exposes,
    /// which is the fallback route off the device when sharing is inconvenient.
    ///
    /// tvOS has no writable Documents directory at all — only Caches — so it
    /// lands there instead, mirroring what `NovaStorage.root` already does.
    private static func reportsDirectory() throws -> URL {
        #if os(tvOS)
        let parent = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        #else
        let parent = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        #endif
        let dir = parent.appendingPathComponent("Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Report body

    private static func summaryText(note: String, model: AppModel,
                                    pilot: PilotStore, stamp: String) -> String {
        let game = model.data.game
        let state = pilot.state
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
        let info = Foundation.Bundle.main.infoDictionary
        out.append("  app          \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))")
        #if canImport(UIKit)
        out.append("  device       \(UIDevice.current.model)")
        out.append("  os           \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        #else
        out.append("  os           \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #endif
        out.append("")

        out.append("DATA SET")
        out.append("  base data    \(model.data.isBaseDataComplete ? "complete" : (model.data.hasBaseData ? "PARTIAL — missing \(model.data.missingEssentials.joined(separator: ", "))" : "NOT IMPORTED"))")
        let enabled = model.data.plugins.filter(\.isEnabled)
        out.append("  plug-ins     \(enabled.isEmpty ? "none enabled" : enabled.map { "\($0.name) [\($0.id)]" }.joined(separator: ", "))")
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

        out.append("  legal record (universal)")
        let records = state.legalRecord.filter { $0.value != 0 }
        if records.isEmpty {
            out.append("    (clean everywhere)")
        } else {
            for (govt, value) in records.sorted(by: { $0.key < $1.key }) {
                out.append("    \(value >= 0 ? "+" : "")\(value)  \(game?.govt(govt)?.displayName ?? "govt #\(govt)")")
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

    private static func diagnosticsText(_ sections: [DiagnosticSection]) -> String {
        var out: [String] = ["NovaSwift self-test", String(repeating: "=", count: 60)]
        for section in sections {
            out.append("")
            out.append(section.title.uppercased())
            for r in section.results {
                let mark: String
                switch r.status {
                case .pass: mark = "PASS"
                case .warn: mark = "WARN"
                case .fail: mark = "FAIL"
                }
                out.append("  [\(mark)] \(r.name)\(r.detail.map { " — \($0)" } ?? "")")
            }
        }
        return out.joined(separator: "\n")
    }

    private static func logText(_ lines: [ConsoleLogStore.Line]) -> String {
        guard !lines.isEmpty else {
            return "(no log entries — the process may have just started)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return lines.map { "\(formatter.string(from: $0.date))  \($0.text)" }
            .joined(separator: "\n")
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}

private extension URL {
    var modificationDate: Date? {
        try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
    var fileSizeDescription: String {
        let bytes = (try? resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
