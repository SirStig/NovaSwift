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
        /// File names inside the zip, for the "Report ready" card's pills.
        var files: [String] = []
    }

    /// Build the bundle. Off-main work (log read, zip) is awaited, so call this
    /// from a `Task` and show progress — a long session's log can take a moment.
    static func make(note: String,
                     model: AppModel,
                     pilot: PilotStore,
                     debug: DebugController?) async throws -> Bundle {
        let stamp = BugReportText.timestamp()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("novaswift-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let summary = Self.summaryText(note: note, model: model, pilot: pilot, stamp: stamp)
        try Data(summary.utf8).write(to: staging.appendingPathComponent("report.txt"))
        var files = ["report.txt"]

        // The save itself: bits, outfits, hull, system, missions, legal record.
        // This is the single most useful file in the bundle — it's a repro.
        if let json = BugReportText.pilotJSON(pilot.state) {
            try json.write(to: staging.appendingPathComponent("pilot.json"))
            files.append("pilot.json")
        }

        if let game = model.data.game {
            let sections = DebugDiagnostics.run(game: game,
                                                pilot: pilot.state,
                                                liveShip: debug?.scene?.playerShip,
                                                liveHostiles: debug?.scene?.liveHostileCount)
            try Data(BugReportText.diagnostics(sections).utf8)
                .write(to: staging.appendingPathComponent("diagnostics.txt"))
            files.append("diagnostics.txt")
        }

        let log = await ConsoleLogStore.snapshot()
        try Data(BugReportText.log(log.map { ($0.date, $0.text) }).utf8)
            .write(to: staging.appendingPathComponent("console.log"))
        files.append("console.log")

        // Zip, then park it somewhere the reporter can find it again.
        let zipped = try GameDataArchiver.zip(directory: staging)
        let destination = try Self.reportsDirectory()
            .appendingPathComponent("NovaSwift-report-\(stamp).zip")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: zipped, to: destination)

        Log.pilot.notice("BugReport.make: wrote \(destination.lastPathComponent, privacy: .public) (\(destination.fileSizeDescription, privacy: .public))")
        return Bundle(url: destination, summary: summary, files: files)
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

    /// The platform-specific rows (app/device/OS, base data, plug-ins) around the shared
    /// `BugReportText.summary` body.
    private static func summaryText(note: String, model: AppModel,
                                    pilot: PilotStore, stamp: String) -> String {
        var build: [String] = []
        let info = Foundation.Bundle.main.infoDictionary
        build.append("  app          \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))")
        #if canImport(UIKit)
        build.append("  device       \(UIDevice.current.model)")
        build.append("  os           \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        #else
        build.append("  os           \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #endif

        var dataSet: [String] = []
        dataSet.append("  base data    \(model.data.isBaseDataComplete ? "complete" : (model.data.hasBaseData ? "PARTIAL — missing \(model.data.missingEssentials.joined(separator: ", "))" : "NOT IMPORTED"))")
        let enabled = model.data.plugins.filter(\.isEnabled)
        dataSet.append("  plug-ins     \(enabled.isEmpty ? "none enabled" : enabled.map { "\($0.name) [\($0.id)]" }.joined(separator: ", "))")

        return BugReportText.summary(note: note, stamp: stamp, buildLines: build, dataSetLines: dataSet,
                                     game: model.data.game, state: pilot.state)
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
