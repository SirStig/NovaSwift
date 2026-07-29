import SwiftUI

/// The dev console's **tools** pane: the live performance readout plus the
/// switches and one-shot actions that used to make up the debug suite.
///
/// Every control here submits a console command rather than mutating state
/// directly, so the action lands in the scrollback and the pane doubles as
/// documentation for the command line. The command name is shown beside each
/// row for exactly that reason.
struct DevToolsPane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var console: ConsoleController
    @ObservedObject var debug: DebugController

    @State private var showGameState = false
    @State private var showDiagnostics = false
    @State private var showTests = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                performanceSection
                cheatsSection
                worldSection
                stressSection
                deepToolsSection
            }
            .padding(14)
        }
        .sheet(isPresented: $showGameState) {
            DebugGameStateView(debug: debug)
                .environmentObject(model)
                .environmentObject(model.pilot)
        }
        .sheet(isPresented: $showDiagnostics) {
            DebugDiagnosticsView(debug: debug)
                .environmentObject(model)
                .environmentObject(model.pilot)
        }
        .sheet(isPresented: $showTests) {
            DebugTestsView()
                .environmentObject(model)
        }
    }

    // MARK: Performance

    private var performanceSection: some View {
        section("PERFORMANCE", "speedometer") {
            HStack(spacing: 8) {
                metric("FPS", String(format: "%.0f", debug.fps), color: fpsColor)
                metric("FRAME", String(format: "%.1f", debug.frameMsAvg), color: .white)
                metric("WORST", String(format: "%.1f", debug.frameMsMax), color: worstColor)
            }
            HStack(spacing: 8) {
                metric("CPU", String(format: "%.1f", debug.cpuMsAvg), color: cpuColor)
                metric("RENDER", String(format: "%.1f", debug.renderMsAvg), color: .white)
                metric("MEM", String(format: "%.0f", debug.memoryMB), color: .white)
            }
            HStack(spacing: 8) {
                metric("SHIPS", "\(debug.shipCount)", color: .white)
                metric("SHOTS", "\(debug.projectileCount)", color: .white)
                metric("NODES", "\(debug.nodeCount)", color: .white)
            }
            frameBreakdown
            spikeCallout
        }
    }

    /// Per-phase frame-time breakdown, longest-first, plus a synthetic
    /// "render/other" bar for the time SpriteKit's own pass ate. Read it
    /// top-down: the first row is what to go fix.
    @ViewBuilder private var frameBreakdown: some View {
        if !debug.phaseBreakdown.isEmpty {
            let renderRow = PerfPhase(name: "render/other", avgMs: debug.renderMsAvg,
                                      worstMs: debug.renderMsAvg)
            let rows = (debug.phaseBreakdown + [renderRow]).sorted { $0.avgMs > $1.avgMs }
            let scale = max(debug.frameMsAvg, rows.first?.avgMs ?? 1, 0.001)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, phase in
                    phaseRow(phase, scale: scale, highlight: index == 0)
                }
            }
            .padding(.top, 2)
        }
    }

    private func phaseRow(_ phase: PerfPhase, scale: Double, highlight: Bool) -> some View {
        let frac = min(1, max(0, phase.avgMs / scale))
        let tint = highlight ? Color(red: 1.0, green: 0.75, blue: 0.3) : devConsoleGreen
        return VStack(spacing: 2) {
            HStack(spacing: 6) {
                Text(phase.name)
                    .font(.system(size: 9 * devFontScale, weight: highlight ? .bold : .regular,
                                  design: .monospaced))
                Spacer()
                Text(String(format: "%.1f · %.1f", phase.avgMs, phase.worstMs))
                    .font(.system(size: 9 * devFontScale, design: .monospaced))
                    .monospacedDigit()
            }
            .foregroundStyle(highlight ? tint : .white.opacity(0.75))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.07))
                    Capsule().fill(tint.opacity(0.55))
                        .frame(width: max(2, geo.size.width * frac))
                }
            }
            .frame(height: 3)
        }
    }

    @ViewBuilder private var spikeCallout: some View {
        if debug.lastSpikeMs > 0 {
            let culprit = debug.lastSpikePhases.first
            let detail = culprit.map { " · \($0.name) \(String(format: "%.1f", $0.avgMs))ms" } ?? ""
            Text("⚠ Spike \(String(format: "%.1f", debug.lastSpikeMs))ms\(detail)")
                .font(.system(size: 9 * devFontScale, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(red: 0.95, green: 0.55, blue: 0.35))
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    // MARK: Cheats

    private var cheatsSection: some View {
        section("CHEATS", "wand.and.stars") {
            commandToggle("God mode", command: "god", isOn: debug.godMode)
            commandToggle("Infinite fuel", command: "fuel", isOn: debug.infiniteFuel)
            HStack(spacing: 6) {
                commandChip("Full heal", "heal")
                commandChip("Refuel", "refuel")
                commandChip("+100k", "credits add 100000")
            }
        }
    }

    // MARK: World

    private var worldSection: some View {
        section("WORLD", "globe") {
            commandToggle("AI state overlay", command: "ai", isOn: debug.aiDebugEnabled)
            commandToggle("UI measurement grid", command: "uidebug",
                          isOn: model.settings.uiDebugOverlay)
            HStack(spacing: 6) {
                commandChip("Kill hostiles", "killhostiles")
                commandChip("Clear NPCs", "clearnpcs")
            }
            Text("Browse the Ships tab to spawn a specific hull.")
                .font(.system(size: 9 * devFontScale, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Stress test

    private var stressSection: some View {
        section("STRESS TEST", "bolt.fill") {
            Text("Spawns mutually-hostile fleets — the worst-case sim + render load.")
                .font(.system(size: 9 * devFontScale, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if debug.perfTestActive {
                commandChip("Stop test (\(debug.shipCount) live)", "perf stop", destructive: true)
            } else {
                HStack(spacing: 6) {
                    ForEach([20, 60, 150], id: \.self) { n in
                        commandChip("\(n)", "perf start \(n)")
                    }
                }
            }
        }
    }

    // MARK: Deep editors

    private var deepToolsSection: some View {
        section("EDITORS", "wrench.and.screwdriver.fill") {
            sheetRow("Game State", "pencil.and.list.clipboard") { showGameState = true }
            sheetRow("Diagnostics", "checkmark.seal") { showDiagnostics = true }
            sheetRow("Self-Tests", "testtube.2") { showTests = true }
        }
    }

    // MARK: Building blocks

    /// A switch that submits `<command> on|off` instead of writing the flag —
    /// so flipping it shows up in the log exactly like typing it would.
    private func commandToggle(_ title: String, command: String, isOn: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12 * devFontScale, weight: .medium, design: .monospaced))
                Text(command)
                    .font(.system(size: 9 * devFontScale, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            CursorButton { console.submit("\(command) \(isOn ? "off" : "on")") } label: {
                Text(isOn ? "ON" : "OFF")
                    .font(.system(size: 10 * devFontScale, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .frame(minWidth: 48)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? devConsoleGreen.opacity(0.22) : .white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isOn ? devConsoleGreen.opacity(0.7) : .white.opacity(0.15)))
                    .foregroundStyle(isOn ? devConsoleGreen : .white.opacity(0.6))
                    .contentShape(Rectangle())
            }
        }
    }

    /// A one-shot action chip; its label is cosmetic, the command is the truth.
    private func commandChip(_ title: String, _ command: String,
                             destructive: Bool = false) -> some View {
        let tint = destructive ? devConsoleRed : Color.white
        return CursorButton { console.submit(command) } label: {
            Text(title)
                .font(.system(size: 10 * devFontScale, weight: .semibold, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.vertical, 7).padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(tint.opacity(0.25)))
                .foregroundStyle(tint)
                .contentShape(Rectangle())
        }
    }

    /// Entry to one of the deep editors, which stay sheets — they're forms
    /// too large to live in the rail.
    private func sheetRow(_ title: String, _ symbol: String,
                          _ action: @escaping () -> Void) -> some View {
        CursorButton {
            model.audio.play(.uiSelect)
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11 * devFontScale))
                Text(title)
                    .font(.system(size: 12 * devFontScale, weight: .semibold, design: .monospaced))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9 * devFontScale))
            }
            .padding(.vertical, 9).padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(devConsoleGreen.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(devConsoleGreen.opacity(0.45)))
            .foregroundStyle(devConsoleGreen)
            .contentShape(Rectangle())
        }
    }

    private func section<Content: View>(_ title: String, _ symbol: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10 * devFontScale, weight: .bold, design: .monospaced))
                .foregroundStyle(devConsoleGreen)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
    }

    private func metric(_ label: String, _ value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14 * devFontScale, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 8 * devFontScale, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(.black.opacity(0.3)))
    }

    private var cpuColor: Color {
        // Over ~13ms of CPU alone risks missing a 60fps frame before render runs.
        debug.cpuMsAvg > 13 ? Color(red: 1.0, green: 0.75, blue: 0.3) : .white
    }

    private var fpsColor: Color {
        switch debug.fps {
        case 55...: return devConsoleGreen
        case 30..<55: return Color(red: 1.0, green: 0.75, blue: 0.3)
        default: return devConsoleRed
        }
    }

    private var worstColor: Color {
        // A single frame over ~33ms (below 30fps) is a visible hitch.
        debug.frameMsMax > 33 ? devConsoleRed : .white
    }
}

/// A compact always-on performance chip shown in the corner while debug mode
/// is active — an at-a-glance fps/ship read-out without opening the console.
/// Tapping it opens the console on the tools pane.
struct DebugMetricsChip: View {
    @ObservedObject var debug: DebugController
    var onTap: () -> Void

    var body: some View {
        CursorButton(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "speedometer").font(.system(size: 10))
                Text(String(format: "%.0f fps", debug.fps))
                    .foregroundStyle(fpsColor)
                Text("· \(debug.shipCount) ships")
                    .foregroundStyle(.secondary)
                if debug.perfTestActive {
                    Text("· TEST").foregroundStyle(devConsoleGreen)
                }
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color.black.opacity(0.7), in: Capsule())
            .overlay(Capsule().strokeBorder(devConsoleGreen.opacity(0.4)))
            .foregroundStyle(.white)
            .contentShape(Capsule())
        }
    }

    private var fpsColor: Color {
        switch debug.fps {
        case 55...: return devConsoleGreen
        case 30..<55: return Color(red: 1.0, green: 0.75, blue: 0.3)
        default: return devConsoleRed
        }
    }
}
