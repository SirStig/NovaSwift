import SwiftUI
import NovaSwiftEngine

/// The in-game **debug suite** panel: a slide-in developer console, opened from
/// the on-screen debug button (or the pause menu) once debug mode is enabled.
///
/// It hosts every developer tool in one place — a live performance readout, the
/// performance stress test, and the UI measurement overlay today; more as the
/// port grows. Each tool is one self-contained section, so adding a new one is
/// purely additive: drop a `section` in `body` and, if it needs state, a field
/// on `DebugController`.
///
/// Styled green-on-black monospaced to read unmistakably as a dev surface,
/// never to be confused with the player-facing game menu.
struct DebugSuiteView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var debug: DebugController
    var onClose: () -> Void

    @State private var showGameState = false
    @State private var showDiagnostics = false
    @State private var showTests = false

    /// Fleet sizes the stress test offers.
    private let shipCountPresets = [20, 40, 60, 100, 150, 200]
    private let green = Color(red: 0.35, green: 0.95, blue: 0.5)

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            panel
                .frame(maxWidth: 380, maxHeight: .infinity, alignment: .top)
                .background(.ultraThinMaterial)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(green.opacity(0.25)).frame(width: 1)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
        }
        .novaResponsive()
        .foregroundStyle(.white)
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

    // MARK: Cheats (quick toggles)

    private var cheatsSection: some View {
        sectionCard(title: "CHEATS", systemImage: "wand.and.stars") {
            debugToggle("God mode", "Player takes no damage; health stays full.",
                        isOn: $debug.godMode)
            debugToggle("Infinite fuel", "Fuel never drains from burners or jumps.",
                        isOn: $debug.infiniteFuel)
            if debug.scene?.playerShip == nil {
                Text("Applies once you're flying.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Diagnostics

    private var diagnosticsSection: some View {
        sectionCard(title: "DIAGNOSTICS & TESTS", systemImage: "stethoscope") {
            Text("Integrity checks the data set, pilot, and live world (nav links, sprites, hull validity). Self-tests drive the engine itself — damage, physics, projectiles, regen.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            actionButton("Run Diagnostics", systemImage: "checkmark.seal") {
                showDiagnostics = true
            }
            actionButton("Run Self-Tests", systemImage: "testtube.2") {
                showTests = true
            }
        }
    }

    /// A full-width green action button used by the diagnostics/tests section.
    private func actionButton(_ title: String, systemImage: String,
                              _ action: @escaping () -> Void) -> some View {
        Button {
            model.audio.play(.uiSelect)
            action()
        } label: {
            HStack {
                Image(systemName: systemImage)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10))
            }
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .padding(.vertical, 11).padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 9).fill(green.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(green.opacity(0.6)))
            .foregroundStyle(green)
        }
        .buttonStyle(.plain)
    }

    /// A compact green-tinted toggle row for the suite's own switches.
    private func debugToggle(_ title: String, _ subtitle: String,
                             isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                Text(subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .tint(green)
    }

    // MARK: Game state

    private var gameStateSection: some View {
        sectionCard(title: "GAME STATE", systemImage: "slider.horizontal.3") {
            Text("Edit the live pilot and world — credits, fuel, ship health, date, relations, mission bits, current hull, outfits, and enemy spawns.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.audio.play(.uiSelect)
                showGameState = true
            } label: {
                HStack {
                    Image(systemName: "pencil.and.list.clipboard")
                    Text("Open Game State Editor")
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10))
                }
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .padding(.vertical, 11).padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 9).fill(green.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(green.opacity(0.6)))
                .foregroundStyle(green)
            }
            .buttonStyle(.plain)

            // At-a-glance quick actions for the most common tweaks.
            HStack(spacing: 8) {
                quickChip("Full Heal") {
                    if let s = debug.scene?.playerShip { s.shield = s.maxShield; s.armor = s.maxArmor }
                }
                quickChip("Refuel") {
                    if let s = debug.scene?.playerShip {
                        s.fuel = s.maxFuel
                        model.pilot.state.fuel = s.maxFuel; model.pilot.save()
                    }
                }
                quickChip("+100k") {
                    model.pilot.state.credits += 100_000; model.pilot.save()
                }
            }
        }
    }

    private func quickChip(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button {
            model.audio.play(.uiSelect)
            action()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.12)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(green.opacity(0.25))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    performanceSection
                    cheatsSection
                    gameStateSection
                    diagnosticsSection
                    stressTestSection
                    aiSection
                    overlaysSection
                }
                .padding(16)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "ladybug.fill")
                .font(.title2)
                .foregroundStyle(green)
            VStack(alignment: .leading, spacing: 1) {
                Text("DEBUG SUITE")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(green)
                Text("developer tools")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.subheadline.weight(.bold))
                    .padding(8).background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // MARK: Performance readout

    private var performanceSection: some View {
        sectionCard(title: "PERFORMANCE", systemImage: "speedometer") {
            HStack(spacing: 10) {
                metric("FPS", String(format: "%.0f", debug.fps), color: fpsColor)
                metric("FRAME", String(format: "%.1fms", debug.frameMsAvg), color: .white)
                metric("WORST", String(format: "%.1fms", debug.frameMsMax), color: worstColor)
            }
            HStack(spacing: 10) {
                metric("SHIPS", "\(debug.shipCount)", color: .white)
                metric("SHOTS", "\(debug.projectileCount)", color: .white)
                metric("ROIDS", "\(debug.asteroidCount)", color: .white)
                metric("NODES", "\(debug.nodeCount)", color: .white)
            }
        }
    }

    private var fpsColor: Color {
        switch debug.fps {
        case 55...: return green
        case 30..<55: return Color(red: 1.0, green: 0.75, blue: 0.3)
        default: return Color(red: 0.95, green: 0.35, blue: 0.3)
        }
    }

    private var worstColor: Color {
        // A single frame over ~33ms (below 30fps) is a visible hitch.
        debug.frameMsMax > 33 ? Color(red: 0.95, green: 0.35, blue: 0.3) : .white
    }

    // MARK: Performance stress test

    private var stressTestSection: some View {
        sectionCard(title: "STRESS TEST", systemImage: "bolt.fill") {
            Text("Spawns two enemy fleets in the current system and lets them fight — the worst-case sim + render load for chasing down frame drops.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("FLEET")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Fleet size", selection: $debug.perfTestShipCount) {
                    ForEach(shipCountPresets, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.menu)
                .tint(green)
                .disabled(debug.perfTestActive)
            }

            Button {
                model.audio.play(.uiSelect)
                if debug.perfTestActive { debug.stopPerformanceTest() }
                else { debug.startPerformanceTest() }
            } label: {
                HStack {
                    Image(systemName: debug.perfTestActive ? "stop.fill" : "play.fill")
                    Text(debug.perfTestActive
                         ? "Stop Test"
                         : "Spawn \(debug.perfTestShipCount) Combatants")
                    Spacer()
                }
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .padding(.vertical, 11).padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill((debug.perfTestActive ? Color(red: 0.95, green: 0.35, blue: 0.3) : green)
                            .opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder((debug.perfTestActive ? Color(red: 0.95, green: 0.35, blue: 0.3) : green)
                            .opacity(0.6))
                )
                .foregroundStyle(debug.perfTestActive ? Color(red: 0.95, green: 0.45, blue: 0.4) : green)
            }
            .buttonStyle(.plain)

            if debug.perfTestActive {
                Text("Test running — \(debug.shipCount) ships live. Fly in and watch the numbers above.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(green.opacity(0.85))
            }
        }
    }

    // MARK: AI debugging

    private var aiSection: some View {
        sectionCard(title: "AI", systemImage: "brain") {
            Toggle(isOn: $debug.aiDebugEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("State & paths overlay")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                    Text("Draws each NPC's AI state, target, nav goal and formation link over the scene.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .tint(green)

            if debug.aiDebugEnabled {
                VStack(alignment: .leading, spacing: 5) {
                    legendRow(Color(red: 0.95, green: 0.3, blue: 0.25), "line to combat target")
                    legendRow(Color(red: 0.35, green: 0.75, blue: 1.0), "line to nav goal (path)")
                    legendRow(Color(red: 0.4, green: 0.9, blue: 0.45), "line to fleet leader")
                    Text("Label above each ship: state → target id · E# = escort slot.")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
        }
    }

    private func legendRow(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 14, height: 3)
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Overlays

    private var overlaysSection: some View {
        sectionCard(title: "OVERLAYS", systemImage: "ruler") {
            Toggle(isOn: Binding(
                get: { model.settings.uiDebugOverlay },
                set: { model.settings.uiDebugOverlay = $0; model.commitSettings() }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("UI measurement grid")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                    Text("Design-space grid + live .novaPlace read-out on authentic screens. Also ⇧⌘D.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .tint(green)
        }
    }

    // MARK: Building blocks

    /// One titled tool card. New debug tools drop in as another of these.
    private func sectionCard<Content: View>(title: String, systemImage: String,
                                            @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(green)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
    }

    /// A single labelled metric tile for the performance readout.
    private func metric(_ label: String, _ value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.25)))
    }
}

/// A compact always-on performance chip shown in the corner while debug mode is
/// active — an at-a-glance fps/ship read-out so you can watch frame rate without
/// opening the full suite. Tapping it opens the suite.
struct DebugMetricsChip: View {
    @ObservedObject var debug: DebugController
    var onTap: () -> Void

    private let green = Color(red: 0.35, green: 0.95, blue: 0.5)

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "ladybug.fill").font(.system(size: 10))
                Text(String(format: "%.0f fps", debug.fps))
                    .foregroundStyle(fpsColor)
                Text("· \(debug.shipCount) ships")
                    .foregroundStyle(.secondary)
                if debug.perfTestActive {
                    Text("· TEST").foregroundStyle(green)
                }
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color.black.opacity(0.7), in: Capsule())
            .overlay(Capsule().strokeBorder(green.opacity(0.4)))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private var fpsColor: Color {
        switch debug.fps {
        case 55...: return green
        case 30..<55: return Color(red: 1.0, green: 0.75, blue: 0.3)
        default: return Color(red: 0.95, green: 0.35, blue: 0.3)
        }
    }
}
