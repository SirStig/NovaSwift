import SwiftUI
import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory

/// The debug suite's **diagnostics** panel: an in-app self-test battery that
/// exercises the loaded data set, the current pilot, and the live world and
/// reports pass / warn / fail for each check. It's the "automated tests you can
/// run on the device" surface — a fast integrity sweep for catching a broken
/// plug-in merge, a dangling nav link, a hull with no sprite, or a player ship
/// that can't move, without attaching a debugger or reading the console.
///
/// Every check is a pure function over `NovaGame` + `PlayerState` + an optional
/// live `Ship`, collected in `DebugDiagnostics.run`. Adding a check is one entry
/// there; the view just renders whatever comes back, grouped by section.
struct DebugDiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pilot: PilotStore
    @ObservedObject var debug: DebugController
    @Environment(\.dismiss) private var dismiss

    @State private var sections: [DiagnosticSection] = []
    @State private var hasRun = false

    private let green = Color(red: 0.35, green: 0.95, blue: 0.5)

    var body: some View {
        NavigationStack {
            List {
                if hasRun {
                    summaryRow
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.results) { result in
                                resultRow(result)
                            }
                        }
                    }
                } else {
                    Section {
                        Text("Runs a battery of integrity and sanity checks over the loaded data set, the current pilot, and the live flight session. Nothing here changes game state.")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .cancellationAction) {
                    Button(hasRun ? "Re-run" : "Run") { run() }
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if !hasRun { run() } }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 560, idealHeight: 720, maxHeight: 900)
        #endif
    }

    private func run() {
        model.audio.play(.uiSelect)
        sections = DebugDiagnostics.run(game: model.data.game,
                                        pilot: pilot.state,
                                        liveShip: debug.scene?.playerShip,
                                        liveHostiles: debug.scene?.liveHostileCount)
        hasRun = true
    }

    // MARK: Rows

    private var summaryRow: some View {
        let all = sections.flatMap(\.results)
        let fails = all.filter { $0.status == .fail }.count
        let warns = all.filter { $0.status == .warn }.count
        let passes = all.filter { $0.status == .pass }.count
        return Section {
            HStack(spacing: 14) {
                summaryTile("\(passes)", "PASS", .green)
                summaryTile("\(warns)", "WARN", Color(red: 1.0, green: 0.75, blue: 0.3))
                summaryTile("\(fails)", "FAIL", Color(red: 0.95, green: 0.35, blue: 0.3))
            }
            .frame(maxWidth: .infinity)
        } header: {
            Text(fails == 0 ? (warns == 0 ? "All checks passed" : "Passed with warnings")
                            : "\(fails) check\(fails == 1 ? "" : "s") failing")
        }
    }

    private func summaryTile(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            Text(label).font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func resultRow(_ result: DiagnosticResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.status.symbol)
                .foregroundStyle(result.status.color)
                .font(.system(size: 14))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                if let detail = result.detail {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Result model
//
// `DiagnosticStatus` / `DiagnosticResult` / `DiagnosticSection` / `DebugDiagnostics` moved to
// NovaSwiftStory/DebugDiagnostics.swift (shared with the Godot debug suite). Only the SwiftUI
// presentation of the status stays here.

extension DiagnosticStatus {
    var symbol: String {
        switch self {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        }
    }
    var color: Color {
        switch self {
        case .pass: return Color(red: 0.35, green: 0.95, blue: 0.5)
        case .warn: return Color(red: 1.0, green: 0.75, blue: 0.3)
        case .fail: return Color(red: 0.95, green: 0.35, blue: 0.3)
        }
    }
}
