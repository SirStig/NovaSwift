#if os(macOS)
import SwiftUI
import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory

// MARK: - Small building blocks

private let panelBG = Color(red: 0.06, green: 0.06, blue: 0.07)
private let cardBG = Color.white.opacity(0.045)

/// A collapsible titled section.
private struct PanelSection<Content: View>: View {
    let title: String
    let symbol: String
    @State private var open: Bool
    @ViewBuilder var content: () -> Content

    init(_ title: String, symbol: String, open: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.symbol = symbol; self._open = State(initialValue: open); self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold)).frame(width: 10)
                    Image(systemName: symbol).frame(width: 16)
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(novaAmber)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 8) { content() }
                    .padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .background(cardBG, in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Filter field + scrolling single-selection list.
private struct PickList: View {
    let items: [EditorPick]
    @Binding var selection: Int?
    var placeholder = "Search…"
    var height: CGFloat = 110
    @State private var query = ""

    private var filtered: [EditorPick] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { $0.searchText.contains(q) }
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField(placeholder, text: $query).textFieldStyle(.plain).font(.system(size: 11))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(5).background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered.prefix(300)) { item in
                        HStack(spacing: 6) {
                            Text("\(item.id)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .trailing)
                            Text(item.title).font(.system(size: 11)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2).padding(.horizontal, 4)
                        .background(selection == item.id ? novaAmber.opacity(0.28) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = item.id }
                    }
                    if filtered.count > 300 {
                        Text("…\(filtered.count - 300) more — refine the search").font(.caption2).foregroundStyle(.secondary).padding(4)
                    }
                    if filtered.isEmpty { Text("No matches").font(.caption2).foregroundStyle(.secondary).padding(4) }
                }
            }
            .frame(height: height)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

private struct ActionButton: View {
    let title: String
    var symbol: String? = nil
    var role: ButtonRole? = nil
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(novaAmber.opacity(disabled ? 0.06 : 0.16), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(disabled ? Color.secondary : novaAmber)
        }
        .buttonStyle(.plain).disabled(disabled)
    }
}

private struct ToggleRow: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            Label(title, systemImage: symbol).font(.system(size: 11))
        }
        .toggleStyle(.switch).controlSize(.mini).tint(novaAmber)
    }
}

// MARK: - Panel

struct EditorDebugPanel: View {
    @ObservedObject var session: EditorTestSession
    var onExit: () -> Void
    var onCollapse: () -> Void

    // Spawn
    @State private var spawnShip: Int?
    @State private var spawnCount = 1
    @State private var stance: EditorTestSession.Stance = .hostile
    @State private var placement: EditorTestSession.Placement = .nearPlayer
    @State private var govt: Int = -1
    @State private var fleet: Int?
    // Hull / outfits
    @State private var hull: Int?
    @State private var outfit: Int?
    @State private var outfitCount = 1
    // Travel
    @State private var jumpSystem: Int?
    // Story
    @State private var bitText = ""
    @State private var testText = ""
    @State private var testResult: String?
    @State private var mission: Int?
    @State private var creditText = ""
    // Feedback
    @State private var toast: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 8) {
                    sessionSection
                    cheatsSection
                    spawnSection
                    hullSection
                    travelSection
                    storySection
                    targetsSection
                    perfSection
                    consoleSection
                }
                .padding(8)
            }
            if let toast {
                Text(toast).font(.system(size: 11)).foregroundStyle(novaAmber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.black.opacity(0.5))
                    .transition(.opacity)
            }
        }
        .background(panelBG)
        .foregroundStyle(.white.opacity(0.9))
        .tint(novaAmber)
        .controlSize(.small)
    }

    private func say(_ text: String) {
        withAnimation { toast = text }
        Task { try? await Task.sleep(for: .seconds(3)); withAnimation { if toast == text { toast = nil } } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "ladybug.fill").foregroundStyle(novaAmber)
            Text("Test Run").font(.system(size: 13, weight: .bold)).foregroundStyle(novaAmber)
            Spacer()
            Button(role: .destructive) { onExit() } label: {
                Label("End Test", systemImage: "stop.fill").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.red.opacity(0.28), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
            }.buttonStyle(.plain)
            Button(action: onCollapse) { Image(systemName: "sidebar.right") }
                .buttonStyle(.plain).help("Collapse panel")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.black.opacity(0.4))
    }

    // MARK: Sections

    private var sessionSection: some View {
        PanelSection("Session", symbol: "info.circle", open: true) {
            let _ = session.stateRevision
            VStack(alignment: .leading, spacing: 3) {
                row("System", "#\(session.systemID) \(session.systemName(session.systemID))")
                row("Ship", "#\(session.shipID) \(session.shipName(session.shipID))")
                row("Date", session.pilot.state.date.description)
                row("Credits", "\(session.pilot.state.credits)")
                if !session.buildInfo.isEmpty {
                    Text(session.buildInfo).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                ForEach([("pause.fill", "Pause", -1.0), ("tortoise.fill", "0.25×", 0.25),
                         ("play.fill", "1×", 1.0), ("hare.fill", "4×", 4.0)], id: \.1) { sym, label, v in
                    let active = v < 0 ? session.paused : (!session.paused && session.timeScale == v)
                    Button {
                        if v < 0 { session.setPaused(!session.paused) }
                        else { session.setPaused(false); session.setTimeScale(v) }
                    } label: {
                        VStack(spacing: 1) {
                            Image(systemName: sym)
                            Text(label).font(.system(size: 9))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                        .background(active ? novaAmber.opacity(0.32) : Color.white.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(active ? novaAmber : .white.opacity(0.75))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Text(v).font(.system(size: 11)).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var cheatsSection: some View {
        PanelSection("Cheats", symbol: "bolt.shield") {
            ToggleRow(title: "God mode", symbol: "shield.lefthalf.filled",
                      isOn: Binding(get: { session.debug.godMode }, set: { session.setGod($0) }))
            ToggleRow(title: "Infinite fuel", symbol: "fuelpump",
                      isOn: Binding(get: { session.debug.infiniteFuel }, set: { session.setInfiniteFuel($0) }))
            ToggleRow(title: "Freeze AI & spawning", symbol: "snowflake",
                      isOn: Binding(get: { session.aiFrozen }, set: { session.setAIFrozen($0) }))
            ToggleRow(title: "AI debug overlay", symbol: "point.topleft.down.to.point.bottomright.curvepath",
                      isOn: Binding(get: { session.debug.aiDebugEnabled }, set: { session.debug.aiDebugEnabled = $0 }))
            HStack(spacing: 6) {
                ActionButton(title: "Heal", symbol: "cross.fill") { session.heal(); say("Healed.") }
                ActionButton(title: "Refuel", symbol: "fuelpump.fill") { session.refuel(); say("Refueled.") }
            }
            HStack(spacing: 6) {
                TextField("credits", text: $creditText).textFieldStyle(.roundedBorder).frame(width: 90)
                ActionButton(title: "Add") { if let n = Int(creditText) { session.setCredits(n, add: true); say("Credits: \(session.pilot.state.credits)") } }
                ActionButton(title: "Set") { if let n = Int(creditText) { session.setCredits(n, add: false); say("Credits: \(session.pilot.state.credits)") } }
            }
        }
    }

    private var spawnSection: some View {
        PanelSection("Spawn", symbol: "plus.viewfinder") {
            Text("Ship").font(.system(size: 10)).foregroundStyle(.secondary)
            PickList(items: session.shipPicks, selection: $spawnShip, placeholder: "Search ships…")
            HStack {
                Stepper("×\(spawnCount)", value: $spawnCount, in: 1...50).font(.system(size: 11))
                Spacer()
                Picker("", selection: $stance) {
                    ForEach(EditorTestSession.Stance.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 190).labelsHidden()
            }
            HStack {
                Picker("Govt", selection: $govt) {
                    Text("Hull default").tag(-1)
                    ForEach(session.govtPicks) { Text("\($0.id) \($0.title)").tag($0.id) }
                }.font(.system(size: 11))
                Picker("", selection: $placement) {
                    ForEach(EditorTestSession.Placement.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 110)
            }
            ActionButton(title: "Spawn ship\(spawnCount > 1 ? "s" : "")", symbol: "plus.circle.fill", disabled: spawnShip == nil) {
                guard let id = spawnShip else { return }
                let n = session.spawnShips(hull: id, count: spawnCount, stance: stance,
                                           govt: govt >= 0 ? govt : nil, placement: placement)
                say(n > 0 ? "Spawned \(n) × \(session.shipName(id))." : "Couldn't spawn.")
            }
            Divider().overlay(Color.white.opacity(0.1))
            Text("Fleet (flët)").font(.system(size: 10)).foregroundStyle(.secondary)
            PickList(items: session.fleetPicks, selection: $fleet, placeholder: "Search fleets…", height: 90)
            ActionButton(title: "Spawn fleet (\(stance.rawValue.lowercased()))", symbol: "person.3.fill", disabled: fleet == nil) {
                guard let id = fleet else { return }
                let n = session.spawnFleet(id, stance: stance, placement: placement)
                say(n > 0 ? "Spawned fleet #\(id): \(n) ships." : "Couldn't spawn fleet.")
            }
        }
    }

    private var hullSection: some View {
        PanelSection("Ship & Outfits", symbol: "airplane.circle") {
            let _ = session.stateRevision
            Text("Set ship (rebuilds the player)").font(.system(size: 10)).foregroundStyle(.secondary)
            PickList(items: session.shipPicks, selection: $hull, placeholder: "Search hulls…", height: 90)
            HStack(spacing: 6) {
                ActionButton(title: "Set ship", symbol: "arrow.triangle.swap", disabled: hull == nil) {
                    if let h = hull { session.setShip(h); say("Hull → \(session.shipName(h)).") }
                }
                ActionButton(title: "Reset loadout", symbol: "arrow.counterclockwise") { session.resetLoadout(); say("Stock loadout restored.") }
            }
            Divider().overlay(Color.white.opacity(0.1))
            Text("Outfits").font(.system(size: 10)).foregroundStyle(.secondary)
            PickList(items: session.outfitPicks, selection: $outfit, placeholder: "Search outfits…")
            HStack {
                Stepper("×\(outfitCount)", value: $outfitCount, in: 1...999).font(.system(size: 11))
                Spacer()
                ActionButton(title: "Give", symbol: "plus", disabled: outfit == nil) {
                    if let o = outfit { session.giveOutfit(o, count: outfitCount); say("Gave ×\(outfitCount).") }
                }.frame(width: 70)
                ActionButton(title: "Remove", symbol: "minus", disabled: outfit == nil) {
                    if let o = outfit { session.removeOutfit(o, count: outfitCount); say("Removed ×\(outfitCount).") }
                }.frame(width: 80)
            }
            DisclosureGroup("Owned (\(session.ownedOutfits.count))") {
                VStack(spacing: 2) {
                    ForEach(session.ownedOutfits, id: \.id) { o in
                        HStack(spacing: 4) {
                            Text("×\(o.count)").font(.system(size: 10, design: .monospaced)).frame(width: 34, alignment: .trailing)
                            Text(o.name).font(.system(size: 11)).lineLimit(1)
                            Spacer()
                            Button { session.removeOutfit(o.id, count: 1) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                            Button { session.giveOutfit(o.id, count: 1) } label: { Image(systemName: "plus.circle") }.buttonStyle(.plain)
                        }
                    }
                }
            }.font(.system(size: 11))
        }
    }

    private var travelSection: some View {
        PanelSection("Travel", symbol: "arrow.triangle.turn.up.right.diamond") {
            PickList(items: session.systemPicks, selection: $jumpSystem, placeholder: "Search systems…")
            HStack(spacing: 6) {
                ActionButton(title: "Jump here", symbol: "bolt.fill", disabled: jumpSystem == nil || session.landedSpobID != nil) {
                    if let s = jumpSystem { say(session.jump(to: s) ? "Arrived in \(session.systemName(s))." : "Can't jump right now.") }
                }
                ActionButton(title: "Galaxy map (M)", symbol: "map") { session.nav.showingMap.toggle() }
            }
        }
    }

    private var storySection: some View {
        PanelSection("Story", symbol: "text.book.closed") {
            let _ = session.stateRevision
            Text("Control bits (\(session.pilot.state.setBits.count) set)").font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                TextField("bit #", text: $bitText).textFieldStyle(.roundedBorder).frame(width: 64)
                ForEach(["set", "clear", "toggle"], id: \.self) { op in
                    ActionButton(title: op.capitalized, disabled: Int(bitText) == nil) {
                        if let n = Int(bitText) { session.setBit(n, op); say("Bit \(n): \(session.pilot.state.setBits.contains(n) ? "set" : "clear")") }
                    }
                }
            }
            HStack(spacing: 5) {
                TextField("NCB test, e.g. b100 & !b101", text: $testText).textFieldStyle(.roundedBorder)
                    .onSubmit { testResult = "\(session.evaluate(test: testText))" }
                ActionButton(title: "Test") { testResult = "\(session.evaluate(test: testText))" }.frame(width: 54)
            }
            if let testResult { Text("→ \(testResult)").font(.system(size: 11, design: .monospaced)).foregroundStyle(novaAmber) }
            DisclosureGroup("Set bits") {
                Text(session.pilot.state.setBits.sorted().map(String.init).joined(separator: ", "))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 11))
            Divider().overlay(Color.white.opacity(0.1))
            Text("Start mission").font(.system(size: 10)).foregroundStyle(.secondary)
            PickList(items: session.missionPicks, selection: $mission, placeholder: "Search missions…", height: 90)
            ActionButton(title: "Start mission", symbol: "flag.fill", disabled: mission == nil) {
                if let m = mission { say(session.startMission(m) ? "Mission #\(m) started." : "Mission didn't start.") }
            }
            if !session.activeMissionTitles.isEmpty {
                Text("Active: " + session.activeMissionTitles.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Divider().overlay(Color.white.opacity(0.1))
            HStack(spacing: 6) {
                Text("Date").font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach([1, 7, 30, 365], id: \.self) { d in
                    ActionButton(title: "+\(d)d") { session.addDays(d); say("Date: \(session.pilot.state.date.description)") }
                }
            }
        }
    }

    private var targetsSection: some View {
        PanelSection("Targets & NPCs", symbol: "scope") {
            let sel = session.debug.selection
            Text(selectionText(sel)).font(.system(size: 11)).lineLimit(2)
            HStack(spacing: 6) {
                ActionButton(title: "Destroy", symbol: "burst.fill", disabled: !isShip(sel)) { say(session.destroySelected() ? "Destroyed." : "No ship.") }
                ActionButton(title: "Disable", symbol: "bolt.slash.fill", disabled: !isShip(sel)) { say(session.disableSelected() ? "Disabled." : "No ship.") }
                ActionButton(title: "Capture", symbol: "link", disabled: !isShip(sel)) { say(session.captureSelected() ? "Captured." : "No ship.") }
            }
            HStack(spacing: 6) {
                ActionButton(title: "Clear NPCs", symbol: "trash") { say("Cleared \(session.clearNPCs()).") }
                ActionButton(title: "Kill hostiles", symbol: "flame") { say("Destroyed \(session.killHostiles()).") }
                ActionButton(title: "Disable hostiles", symbol: "bolt.slash") { say("Disabled \(session.disableHostiles()).") }
            }
            Text("Tip: target a ship in flight (T / R) to act on it here.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func isShip(_ ref: DevEntityRef?) -> Bool { if case .ship? = ref { return true }; return false }
    private func selectionText(_ ref: DevEntityRef?) -> String {
        switch ref {
        case let .ship(id, name)?: return "Ship #\(id) \(name)"
        case let .spob(id, name)?: return "Stellar #\(id) \(name)"
        case nil: return "Nothing selected"
        }
    }

    private var perfSection: some View {
        PanelSection("Performance", symbol: "gauge.with.dots.needle.50percent") {
            EditorPerfReadout(debug: session.debug)
        }
    }

    private var consoleSection: some View {
        PanelSection("Console", symbol: "terminal") {
            EditorConsoleView(console: session.console)
        }
    }
}

// MARK: - Perf readout (observes the metrics feed on its own)

private struct EditorPerfReadout: View {
    @ObservedObject var debug: DebugController
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(format: "%.0f fps · %.1f ms (worst %.1f)", debug.fps, debug.frameMsAvg, debug.frameMsMax))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(debug.fps >= 50 ? novaAmber : .orange)
            Text(String(format: "CPU %.1f ms · render %.1f ms · %.0f MB", debug.cpuMsAvg, debug.renderMsAvg, debug.memoryMB))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            Text("\(debug.shipCount) ships · \(debug.projectileCount) shots · \(debug.asteroidCount) roids · \(debug.nodeCount) nodes")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            ForEach(debug.phaseBreakdown.prefix(5), id: \.name) { p in
                HStack {
                    Text(p.name).font(.system(size: 10)).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.2f ms", p.avgMs)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Embedded console

/// A compact console bound to the session's `ConsoleController`. Same command
/// registry and scrollback store as the in-game dev console; its own small UI
/// because `DevConsoleView` is a full-screen overlay wired to the play session.
private struct EditorConsoleView: View {
    @ObservedObject var console: ConsoleController
    @ObservedObject private var log: ConsoleLogStore
    @State private var input = ""
    @State private var showLog = false

    init(console: ConsoleController) {
        self.console = console
        self._log = ObservedObject(wrappedValue: console.log)
    }

    private var visible: [ConsoleLogStore.Line] {
        let all = showLog ? log.lines : log.lines.filter {
            switch $0.kind { case .log: return false; default: return true }
        }
        return Array(all.suffix(80))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visible) { line in
                            Text(line.text)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(color(line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                }
                .frame(height: 150)
                .padding(4)
                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
                .onChange(of: log.lines.count) { _, _ in
                    if let last = visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HStack(spacing: 5) {
                Text(">").font(.system(size: 12, design: .monospaced)).foregroundStyle(novaAmber)
                TextField("help", text: $input)
                    .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced))
                    .onSubmit { console.submit(input); input = "" }
            }
            .padding(5).background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
            Toggle("Show engine log", isOn: $showLog).toggleStyle(.checkbox).font(.system(size: 10))
                .onChange(of: showLog) { _, on in if on { log.startPolling() } else { log.stopPolling() } }
        }
        .onDisappear { log.stopPolling() }
    }

    private func color(_ line: ConsoleLogStore.Line) -> Color {
        switch line.kind {
        case .commandEcho: return novaAmber
        case .commandError: return Color(red: 1, green: 0.45, blue: 0.4)
        case .commandOutput: return .white.opacity(0.9)
        case .log: return .white.opacity(0.5)
        }
    }
}
#endif
