import SwiftUI
import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory

/// The debug suite's **in-game self-tests**: a behavioral test battery you run
/// on-device from the running app. Unlike the static `DebugDiagnostics` sweep
/// (which inspects data and current state), these actually *drive the engine* —
/// each test builds its own throwaway `World`/`Ship`, steps the simulation, and
/// asserts on the outcome. They exercise the real damage model, flight physics,
/// projectile combat, and regen exactly as gameplay does.
///
/// Everything runs against isolated worlds, so a test run never touches the
/// player's live session — safe to fire mid-flight. Adding a test is one entry
/// in the relevant section of `DebugLiveTests`.
struct DebugTestsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var sections: [DiagnosticSection] = []
    @State private var hasRun = false

    var body: some View {
        NavigationStack {
            List {
                if hasRun {
                    summaryRow
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.results) { DebugResultRow(result: $0) }
                        }
                    }
                } else {
                    Section {
                        Text("Runs the engine's behavioral test battery — damage, flight physics, projectile combat, and regen — against throwaway worlds. Your live session is never touched.")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Self-Tests")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .cancellationAction) {
                    Button(hasRun ? "Re-run" : "Run") { run() }.fontWeight(.semibold)
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
        sections = DebugLiveTests.run()
        hasRun = true
    }

    private var summaryRow: some View {
        let all = sections.flatMap(\.results)
        let fails = all.filter { $0.status == .fail }.count
        let passes = all.filter { $0.status == .pass }.count
        return Section {
            HStack {
                Label("\(passes) passed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(DiagnosticStatus.pass.color)
                Spacer()
                if fails > 0 {
                    Label("\(fails) failed", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(DiagnosticStatus.fail.color)
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
        } header: {
            Text(fails == 0 ? "All \(all.count) tests passed" : "\(fails) of \(all.count) tests failing")
        }
    }
}

/// Shared result row used by both the diagnostics and self-test panels.
struct DebugResultRow: View {
    let result: DiagnosticResult
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.status.symbol)
                .foregroundStyle(result.status.color)
                .font(.system(size: 14)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name).font(.system(size: 13, weight: .medium, design: .monospaced))
                if let detail = result.detail {
                    Text(detail).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// `DebugLiveTests` moved to NovaSwiftStory/DebugLiveTests.swift (shared with the Godot debug suite).
