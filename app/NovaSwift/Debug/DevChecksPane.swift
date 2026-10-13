import SwiftUI
import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory

/// Which battery the Checks tab is showing.
enum DevChecksMode: String, CaseIterable, Identifiable {
    case diagnostics = "Diagnostics"
    case selfTests = "Self-Tests"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .diagnostics: return "checklist"
        case .selfTests: return "checkmark.seal.fill"
        }
    }

    var blurb: String {
        switch self {
        case .diagnostics:
            return "Integrity and sanity checks over the data set, the pilot and the live session. Changes nothing."
        case .selfTests:
            return "Behavioural tests — damage, flight physics, projectile combat, regen — in throwaway worlds. Your session is never touched."
        }
    }
}

/// The console's **Checks** tab: the static diagnostics sweep
/// (`DebugDiagnostics`) and the behavioural engine self-tests
/// (`DebugLiveTests`) as one dashboard — three big PASS / WARN / FAIL tiles,
/// then a card per section with a status icon on every row. Replaces the two
/// separate list sheets (`DebugDiagnosticsView`, `DebugTestsView`).
struct DevChecksPane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var console: ConsoleController
    let debug: DebugController
    var wide: Bool

    @State private var results: [DevChecksMode: [DiagnosticSection]] = [:]

    private var mode: DevChecksMode { console.checksMode }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            if let sections = results[mode] {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        summary(sections)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top),
                                                 count: wide ? 2 : 1),
                                  alignment: .leading, spacing: 10) {
                            ForEach(sections) { sectionCard($0) }
                        }
                    }
                    .padding(.bottom, 4)
                }
            } else {
                Spacer(minLength: 0)
                DevEmptyState(kind: .list, title: "Not run yet", hint: mode.blurb)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .onAppear { if results[mode] == nil { run() } }
        .onChange(of: console.checksMode) { _, _ in
            if results[mode] == nil { run() }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            ForEach(DevChecksMode.allCases) { m in
                let selected = m == mode
                CursorButton { console.checksMode = m } label: {
                    HStack(spacing: 6) {
                        Image(systemName: m.symbol).font(.system(size: 11 * devFontScale, weight: .semibold))
                        Text(m.rawValue).font(.system(size: 12 * devFontScale, weight: .semibold, design: .rounded))
                    }
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .foregroundStyle(selected ? devConsoleGreen : .white.opacity(0.6))
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(selected ? devConsoleGreen.opacity(0.17) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? devConsoleGreen.opacity(0.6) : .clear))
                    .contentShape(Rectangle())
                }
            }
            if wide {
                Text(mode.blurb)
                    .font(.system(size: 11 * devFontScale))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
            DevChip(title: results[mode] == nil ? "Run" : "Run / Re-run", symbol: "arrow.clockwise",
                    filled: true) { run() }
        }
    }

    // MARK: Summary

    private func summary(_ sections: [DiagnosticSection]) -> some View {
        let tally = sections.tally
        let headline: (String, Color) = tally.fail > 0
            ? ("\(tally.fail) check\(tally.fail == 1 ? "" : "s") failing", DiagnosticStatus.fail.color)
            : (tally.warn > 0 ? ("Passed with warnings", DiagnosticStatus.warn.color)
                              : ("All checks passed", DiagnosticStatus.pass.color))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                tile("PASS", tally.pass, .pass)
                tile("WARN", tally.warn, .warn)
                tile("FAIL", tally.fail, .fail)
            }
            Text(headline.0)
                .font(.system(size: 14 * devFontScale, weight: .bold))
                .foregroundStyle(headline.1)
        }
    }

    private func tile(_ label: String, _ count: Int, _ status: DiagnosticStatus) -> some View {
        let active = count > 0
        let color = status.color
        return HStack(spacing: 12) {
            Image(systemName: status.symbol)
                .font(.system(size: 24 * devFontScale))
                .foregroundStyle(active ? color : color.opacity(0.4))
            VStack(alignment: .leading, spacing: 0) {
                Text("\(count)")
                    .font(.system(size: 24 * devFontScale, weight: .semibold, design: .monospaced))
                    .foregroundStyle(active ? color : .white.opacity(0.5))
                    .monospacedDigit()
                DevCaption(text: label)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(active ? 0.12 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(active ? 0.4 : 0.1)))
    }

    // MARK: Section cards

    private func sectionCard(_ section: DiagnosticSection) -> some View {
        var worst = DiagnosticStatus.pass
        if section.results.contains(where: { $0.status == .fail }) {
            worst = .fail
        } else if section.results.contains(where: { $0.status == .warn }) {
            worst = .warn
        }
        return DevCard(section.title, symbol: worst.symbol, accent: worst.color) {
            DevPill(text: "\(section.results.count) checks", color: .white.opacity(0.55))
        } content: {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(section.results) { result in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: result.status.symbol)
                            .font(.system(size: 14 * devFontScale))
                            .foregroundStyle(result.status.color)
                            .frame(width: 18 * devFontScale)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.name)
                                .font(.system(size: 13 * devFontScale, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail = result.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.system(size: 11 * devFontScale))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: Run

    private func run() {
        model.audio.play(.uiSelect)
        switch mode {
        case .diagnostics:
            results[.diagnostics] = DebugDiagnostics.run(game: model.data.game,
                                                         pilot: model.pilot.state,
                                                         liveShip: debug.scene?.playerShip,
                                                         liveHostiles: debug.scene?.liveHostileCount)
        case .selfTests:
            results[.selfTests] = DebugLiveTests.run()
        }
    }
}
