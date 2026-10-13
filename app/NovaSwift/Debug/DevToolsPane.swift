import SwiftUI
import NovaSwiftKit

/// The dev console's **tools** pane: the live performance readout plus the
/// switches and one-shot actions that used to make up the debug suite.
///
/// Every control here submits a console command rather than mutating state
/// directly, so the action lands in the scrollback and the pane doubles as
/// documentation for the command line. The command name is shown beside each
/// row for exactly that reason.
///
/// Presentation (matching the Godot port): collapsible cards with icon tiles, a
/// nine-tile performance grid with sparklines, per-phase frame bars and a
/// spike warning.
struct DevToolsPane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var console: ConsoleController
    @ObservedObject var debug: DebugController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                selectedSection
                performanceSection
                cheatsSection
                worldSection
                hdSection
                stressSection
                deepToolsSection
            }
            .padding(12)
        }
        // The HD viewer is a turntable, not a form — it stays a sheet (also
        // opened by the `hd view` command).
        .sheet(isPresented: $debug.showHDViewer) {
            HDViewerView(debug: debug)
                .environmentObject(model)
        }
    }

    // MARK: Selected entity
    //
    // The same Destroy/Disable/Capture/Conquer actions the right-click
    // (macOS) / long-press (iOS/tvOS) context menu offers on a ship/planet in
    // the live scene (`DevContextMenu` below), surfaced here too — necessary
    // on tvOS (no right-click/long-press path today) and generally the
    // fastest way to act once something is already targeted. `debug.selection`
    // mirrors whatever `GameScene.selectShip`/`selectPlanet` last set.

    private var selectedSection: some View {
        section("SELECTED", "Selected", "scope", accent: devConsoleBlue) {
            if let ref = debug.selection {
                HStack(spacing: 8) {
                    Image(systemName: ref.systemImage)
                        .font(.system(size: 13 * devFontScale))
                    Text(ref.name.isEmpty ? "#\(ref.id)" : ref.name)
                        .font(.system(size: 14 * devFontScale, weight: .bold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    DevPill(text: "#\(ref.id)", color: .white.opacity(0.6))
                }
                .foregroundStyle(devConsoleGreen)
                HStack(spacing: 6) { entityActionChips(for: ref) }
            } else {
                Text("Nothing selected. Click a ship or planet in the world, or cycle below.")
                    .font(.system(size: 11 * devFontScale))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                DevCaption(text: "Ships")
                DevIconButton(symbol: "chevron.left", help: "Previous ship", tint: devConsoleGreen) {
                    console.submit("cycle ships prev")
                }
                DevIconButton(symbol: "chevron.right", help: "Next ship", tint: devConsoleGreen) {
                    console.submit("cycle ships next")
                }
                Spacer().frame(width: 8)
                DevCaption(text: "Planets")
                DevIconButton(symbol: "chevron.left", help: "Previous planet", tint: devConsoleGreen) {
                    console.submit("cycle planets prev")
                }
                DevIconButton(symbol: "chevron.right", help: "Next planet", tint: devConsoleGreen) {
                    console.submit("cycle planets next")
                }
            }
        }
    }

    @ViewBuilder private func entityActionChips(for ref: DevEntityRef) -> some View {
        switch ref {
        case .ship:
            commandChip("Disable", "disable \(ref.id)", symbol: "pause.fill", tint: devConsoleOrange)
            commandChip("Capture", "capture \(ref.id)", symbol: "arrow.down.circle.fill", tint: devConsoleBlue)
            commandChip("Destroy", "destroy \(ref.id)", symbol: "xmark.octagon.fill", tint: devConsoleRed)
        case .spob:
            commandChip("Conquer", "conquer \(ref.id)", symbol: "crown.fill", tint: devConsoleOrange)
        }
    }

    // MARK: Performance

    private var performanceSection: some View {
        section("PERFORMANCE", "Performance", "speedometer") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                metric("FPS", String(format: "%.0f", debug.fps), color: fpsColor,
                       spark: debug.fpsHistory, sparkColor: fpsColor)
                metric("FRAME MS", String(format: "%.1f", debug.frameMsAvg), color: .white,
                       spark: debug.frameMsHistory, sparkColor: devConsoleGreen)
                metric("WORST MS", String(format: "%.1f", debug.frameMsMax), color: worstColor)
                metric("CPU MS", String(format: "%.1f", debug.cpuMsAvg), color: cpuColor,
                       spark: debug.cpuMsHistory, sparkColor: cpuColor == .white ? devConsoleGreen : cpuColor)
                metric("RENDER MS", String(format: "%.1f", debug.renderMsAvg), color: .white)
                metric("MEM MB", String(format: "%.0f", debug.memoryMB), color: .white)
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
            VStack(alignment: .leading, spacing: 5) {
                DevCaption(text: "Frame breakdown  ·  avg / worst ms")
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, phase in
                    phaseRow(phase, scale: scale, highlight: index == 0)
                }
            }
            .padding(.top, 2)
        }
    }

    private func phaseRow(_ phase: PerfPhase, scale: Double, highlight: Bool) -> some View {
        let frac = min(1, max(0, phase.avgMs / scale))
        let tint = highlight ? devConsoleOrange : devConsoleGreen
        return HStack(spacing: 8) {
            Text(phase.name)
                .font(.system(size: 10 * devFontScale, weight: highlight ? .bold : .regular,
                              design: .monospaced))
                .foregroundStyle(highlight ? tint : .white.opacity(0.72))
                .lineLimit(1)
                .frame(width: 118 * devFontScale, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.07))
                    Capsule().fill(tint.opacity(highlight ? 0.85 : 0.6))
                        .frame(width: max(2, geo.size.width * frac))
                }
            }
            .frame(height: 5)
            Text(String(format: "%.1f · %.1f", phase.avgMs, phase.worstMs))
                .font(.system(size: 10 * devFontScale, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 72 * devFontScale, alignment: .trailing)
        }
    }

    @ViewBuilder private var spikeCallout: some View {
        if debug.lastSpikeMs > 0 {
            let culprit = debug.lastSpikePhases.first
            let detail = culprit.map { " · \($0.name) \(String(format: "%.1f", $0.avgMs))ms" } ?? ""
            Label {
                Text("Spike \(String(format: "%.1f", debug.lastSpikeMs))ms\(detail)")
                    .font(.system(size: 10 * devFontScale, weight: .semibold, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.7)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10 * devFontScale))
            }
            .foregroundStyle(Color(red: 0.95, green: 0.55, blue: 0.35))
        }
    }

    // MARK: Cheats

    private var cheatsSection: some View {
        section("CHEATS", "Cheats", "wand.and.stars", accent: devConsoleOrange) {
            commandToggle("God mode", note: "No damage taken", command: "god", isOn: debug.godMode)
            commandToggle("Infinite fuel", note: "Jumps cost nothing", command: "fuel", isOn: debug.infiniteFuel)
            HStack(spacing: 6) {
                commandChip("Full heal", "heal", symbol: "shield.fill")
                commandChip("Refuel", "refuel", symbol: "bolt.fill")
                commandChip("+100k", "credits add 100000", symbol: "creditcard", tint: devConsoleOrange)
            }
        }
    }

    // MARK: World

    private var worldSection: some View {
        section("WORLD", "World", "globe", accent: devConsoleBlue) {
            commandToggle("AI state overlay", note: "Labels each ship's behaviour", command: "ai",
                          isOn: debug.aiDebugEnabled)
            commandToggle("UI measurement grid", note: "Rulers over the HUD", command: "uidebug",
                          isOn: model.settings.uiDebugOverlay)
            HStack(spacing: 6) {
                commandChip("Kill hostiles", "killhostiles", symbol: "xmark.octagon.fill", tint: devConsoleRed)
                commandChip("Clear NPCs", "clearnpcs", symbol: "trash", tint: devConsoleRed)
            }
            Text("Browse the Ships tab to spawn a specific hull.")
                .font(.system(size: 10 * devFontScale))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: Stress test

    private var stressSection: some View {
        section("STRESS TEST", "Stress test", "waveform.path.ecg", accent: devConsoleRed) {
            Text("Spawns mutually-hostile fleets — the worst-case sim + render load.")
                .font(.system(size: 11 * devFontScale))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            if debug.perfTestActive {
                commandChip("Stop test (\(debug.shipCount) live)", "perf stop",
                            symbol: "stop.fill", tint: devConsoleRed)
            } else {
                HStack(spacing: 6) {
                    ForEach([20, 60, 150], id: \.self) { n in
                        commandChip("\(n) ships", "perf start \(n)", symbol: "play.fill")
                    }
                }
            }
        }
    }

    // MARK: HD / 3D
    //
    // The HD graphics layer (docs/HD_PIPELINE.md): A/B the packs' art against
    // the originals live, check model alignment, and open the turntable viewer.

    private var hdSection: some View {
        section("HD / 3D", "HD / 3D", "cube.transparent", accent: devConsoleBlue) {
            commandToggle("HD graphics", note: "A/B the packs against the originals", command: "hd",
                          isOn: model.settings.hdGraphics)
            commandToggle("HD overlay (exit points)", note: "Frame ring + weapon exit points", command: "hd overlay",
                          isOn: debug.hdOverlay)
            HStack(spacing: 6) {
                commandChip("Detail 2×", "hd detail 2")
                commandChip("Detail 4×", "hd detail 4")
            }
            HStack(spacing: 6) {
                commandChip("Reload packs", "hd reload", symbol: "arrow.clockwise")
                commandChip("Clear cache", "hd clearcache", symbol: "trash", tint: devConsoleRed)
            }
            HStack(spacing: 6) {
                commandChip("Status", "hd status", symbol: "info.circle", tint: devConsoleBlue)
                commandChip("Open viewer", "hd view", symbol: "photo")
            }
        }
    }

    // MARK: Editors
    //
    // The old sheets (Game State, Diagnostics, Self-Tests, Bug Report) are now
    // full tabs of the console; these rows jump there.

    private var deepToolsSection: some View {
        section("EDITORS", "Editors", "wrench.and.screwdriver.fill") {
            sheetRow("Game State", "person.text.rectangle", tab: .state)
            sheetRow("Diagnostics", "checklist", tab: .checks)
            sheetRow("Self-Tests", "checkmark.seal.fill", tab: .checks, selfTests: true)
            sheetRow("Bug Report", "ladybug.fill", tab: .report)
        }
    }

    // MARK: Building blocks

    /// A switch that submits `<command> on|off` instead of writing the flag —
    /// so flipping it shows up in the log exactly like typing it would.
    private func commandToggle(_ title: String, note: String, command: String, isOn: Bool) -> some View {
        CursorButton { console.submit("\(command) \(isOn ? "off" : "on")") } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13 * devFontScale, weight: .semibold))
                    HStack(spacing: 6) {
                        Text(note)
                            .font(.system(size: 10 * devFontScale))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                        Text(command)
                            .font(.system(size: 9 * devFontScale, design: .monospaced))
                            .foregroundStyle(devConsoleGreen.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                DevSwitch(isOn: isOn)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
    }

    /// A one-shot action chip; its label is cosmetic, the command is the truth.
    private func commandChip(_ title: String, _ command: String, symbol: String? = nil,
                             tint: Color = devConsoleGreen) -> some View {
        DevChip(title: title, symbol: symbol, tint: tint, expand: true) {
            console.submit(command)
        }
    }

    /// Entry to one of the editor tabs.
    private func sheetRow(_ title: String, _ symbol: String, tab: DevConsoleTab,
                          selfTests: Bool = false) -> some View {
        CursorButton {
            model.audio.play(.uiSelect)
            console.checksMode = selfTests ? .selfTests : .diagnostics
            console.tab = tab
        } label: {
            HStack(spacing: 10) {
                DevIconTile(symbol: symbol, tint: devConsoleGreen, size: 22)
                Text(title)
                    .font(.system(size: 12.5 * devFontScale, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10 * devFontScale, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 9).fill(devConsoleGreen.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(devConsoleGreen.opacity(0.3)))
            .foregroundStyle(.white)
            .contentShape(Rectangle())
        }
    }

    /// Section ids the user has folded away, remembered between sessions. The
    /// stored key is the original upper-case title so existing preferences hold.
    @AppStorage("devTools.collapsedSections") private var collapsedSections = ""

    private func isCollapsed(_ id: String) -> Bool {
        collapsedSections.split(separator: "|").contains(Substring(id))
    }

    private func toggleCollapsed(_ id: String) {
        var ids = collapsedSections.split(separator: "|").map(String.init)
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
        collapsedSections = ids.joined(separator: "|")
    }

    private func section<Content: View>(_ id: String, _ title: String, _ symbol: String,
                                        accent: Color = devConsoleGreen,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        let collapsed = isCollapsed(id)
        return VStack(alignment: .leading, spacing: 9) {
            CursorButton { withAnimation(.easeOut(duration: 0.15)) { toggleCollapsed(id) } } label: {
                HStack(spacing: 8) {
                    DevIconTile(symbol: symbol, tint: accent)
                    Text(title)
                        .font(.system(size: 14 * devFontScale, weight: .bold))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10 * devFontScale, weight: .bold))
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                        .opacity(0.55)
                }
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            if !collapsed {
                Rectangle().fill(devHairline).frame(height: 1)
                content()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(devHairline))
    }

    /// One metric tile: big monospaced value, dim caption and (for the series
    /// the controller keeps history for) a sparkline.
    private func metric(_ label: String, _ value: String, color: Color,
                        spark: [Double]? = nil, sparkColor: Color = devConsoleGreen) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 17 * devFontScale, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 8.5 * devFontScale, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1).minimumScaleFactor(0.7)
            if let spark {
                DevSparkline(values: spark, color: sparkColor)
                    .frame(height: 16)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.06)))
    }

    private var cpuColor: Color {
        // Over ~13ms of CPU alone risks missing a 60fps frame before render runs.
        debug.cpuMsAvg > 13 ? devConsoleOrange : .white
    }

    private var fpsColor: Color {
        switch debug.fps {
        case 55...: return devConsoleGreen
        case 30..<55: return devConsoleOrange
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
                Circle().fill(fpsColor).frame(width: 7, height: 7)
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
            .overlay(Capsule().strokeBorder(fpsColor.opacity(0.45)))
            .foregroundStyle(.white)
            .contentShape(Capsule())
        }
    }

    private var fpsColor: Color {
        switch debug.fps {
        case 55...: return devConsoleGreen
        case 30..<55: return devConsoleOrange
        default: return devConsoleRed
        }
    }
}

/// The floating Destroy/Disable/Capture/Conquer menu a right-click (macOS) or
/// long-press (iOS/tvOS) on a ship/planet opens — `GameContainerView` shows
/// this at `DebugController.contextMenuRequest.screenPoint` when debug mode
/// is on. Every action submits a console command, same as everything else in
/// the dev console, so it's logged and there's exactly one execution path.
struct DevContextMenu: View {
    let ref: DevEntityRef
    @ObservedObject var console: ConsoleController
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: ref.systemImage).font(.system(size: 10 * devFontScale))
                Text(ref.name.isEmpty ? "#\(ref.id)" : ref.name)
                    .font(.system(size: 11 * devFontScale, weight: .bold, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(devConsoleGreen)
            VStack(alignment: .leading, spacing: 5) {
                switch ref {
                case .ship:
                    menuButton("Select", "select ship \(ref.id)")
                    menuButton("Disable", "disable \(ref.id)")
                    menuButton("Capture", "capture \(ref.id)")
                    menuButton("Destroy", "destroy \(ref.id)", destructive: true)
                case .spob:
                    menuButton("Select", "select spob \(ref.id)")
                    menuButton("Conquer", "conquer \(ref.id)")
                }
            }
        }
        .padding(10)
        .frame(width: 150)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(devConsoleGreen.opacity(0.5)))
        .shadow(color: .black.opacity(0.5), radius: 12)
    }

    private func menuButton(_ title: String, _ command: String, destructive: Bool = false) -> some View {
        let tint = destructive ? devConsoleRed : Color.white
        return CursorButton {
            console.submit(command)
            onDismiss()
        } label: {
            Text(title)
                .font(.system(size: 11 * devFontScale, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(tint)
                .contentShape(Rectangle())
        }
    }
}
