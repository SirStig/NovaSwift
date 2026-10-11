import SwiftUI
import Foundation

/// Shared chrome colour for every developer surface — the same green the debug
/// suite has always used, hoisted out so the console, tools rail and browsers
/// can't drift apart.
let devConsoleGreen = Color(red: 0.35, green: 0.95, blue: 0.5)
let devConsoleRed = Color(red: 0.95, green: 0.4, blue: 0.35)
let devConsoleOrange = Color(red: 1.0, green: 0.72, blue: 0.3)
let devConsoleBlue = Color(red: 0.45, green: 0.72, blue: 1.0)

/// Base point size for the dev console's monospaced text. A TV is viewed from
/// across a room, so the 11pt that reads fine on a Mac is unusable there.
#if os(tvOS)
let devFontScale: CGFloat = 1.6
#else
let devFontScale: CGFloat = 1
#endif

/// One pane of the dev console. `console` is the command line + log; the rest
/// are inspector panes shown in the right-hand rail (wide) or as their own
/// full-width tab (narrow).
enum DevConsoleTab: String, CaseIterable, Identifiable {
    case console = "Console"
    case tools = "Tools"
    case bits = "Bits"
    case ships = "Ships"
    case outfits = "Outfits"
    case govts = "Govts"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .console: return "terminal.fill"
        case .tools: return "slider.horizontal.3"
        case .bits: return "switch.2"
        case .ships: return "airplane"
        case .outfits: return "shippingbox.fill"
        case .govts: return "flag.fill"
        }
    }

    /// The panes that live in the inspector rail (everything but the console
    /// itself, which is always on screen in the wide layout).
    static var inspectorCases: [DevConsoleTab] { allCases.filter { $0 != .console } }
}

/// The in-game **developer console** — one surface that drops down from the
/// top of the screen, replacing the old split between a left-hand debug suite
/// panel and a separate console overlay.
///
/// Layout is responsive, because the two halves want very different room:
///  * **Wide** (Mac, iPad, Apple TV): the log + command line hold the left,
///    and an inspector rail on the right shows the tools/browsers — both
///    visible at once, so you can watch the log react to what you click.
///  * **Narrow** (iPhone): one pane at a time, chosen by the tab bar.
///
/// The organising idea: **every control here runs a console command** rather
/// than calling the underlying setter itself. Clicking "God mode" prints
/// `> god on` into the log exactly as if it were typed. That keeps one
/// execution path, records every action in the scrollback, and makes the UI
/// teach its own command line. See `registerConsoleCommands()`.
struct DevConsoleView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var console: ConsoleController
    /// Deliberately *not* `@ObservedObject`: `DebugController` republishes a
    /// metrics sample several times a second, and observing it here would
    /// re-run this whole body — including the log list's `ForEach` — at that
    /// rate. The children that actually read the numbers observe it
    /// themselves (`ConsoleHeaderMetrics`, `DevToolsPane`).
    let debug: DebugController
    var onClose: () -> Void
    /// Fired when a clickable `«ship:…»`/`«spob:…»` chip in a log line is
    /// tapped — the app wires this to select + recenter the camera on that
    /// entity in the live scene. Defaults to a no-op so call sites that don't
    /// care (there are none left, but keeps the type usable standalone/in
    /// previews) don't have to pass one.
    var onSelectEntity: (DevEntityRef) -> Void = { _ in }

    /// Below this the log and a useful inspector can't share a row.
    private static let wideBreakpoint: CGFloat = 820

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= Self.wideBreakpoint
            VStack(spacing: 0) {
                header(wide: wide)
                Rectangle().fill(devConsoleGreen.opacity(0.3)).frame(height: 1)
                content(wide: wide)
            }
            .frame(height: panelHeight(in: geo.size))
            .frame(maxWidth: .infinity, alignment: .top)
            .background(Color.black.opacity(0.95))
            .overlay(alignment: .bottom) {
                Rectangle().fill(devConsoleGreen.opacity(0.45)).frame(height: 1)
            }
            .clipped()
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea(edges: .horizontal)
        .foregroundStyle(.white)
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear { console.log.startPolling() }
        .onDisappear { console.log.stopPolling() }
        #if !os(tvOS)
        // Escape closes the console from anywhere in it — including while
        // the command-line `TextField` has focus, where `.keyboardShortcut`
        // alone doesn't fire (the focused text field's own responder eats
        // Escape before it reaches a shortcut elsewhere in the hierarchy; see
        // `ConsolePane.inputBar`'s matching `.onKeyPress(.escape)`). This
        // hidden button covers every other tab (Tools/Ships/Bits/…), where
        // nothing else is capturing the key.
        .background {
            Button("", action: onClose)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        #endif
        // Build the control-bit cross-reference as soon as the console opens,
        // not when the Bits tab is first shown — otherwise `bit info` reports
        // "no references" for anyone who only ever uses the command line.
        .task(id: model.data.dataStamp) {
            await console.buildNCBIndexIfNeeded(game: model.data.game,
                                                stamp: model.data.dataStamp)
        }
    }

    /// Tall enough to be a usable log, never so tall it hides the whole game.
    private func panelHeight(in size: CGSize) -> CGFloat {
        min(max(size.height * 0.72, 300), 680)
    }

    // MARK: Header

    private func header(wide: Bool) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 12 * devFontScale, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 22 * devFontScale, height: 22 * devFontScale)
                    .background(RoundedRectangle(cornerRadius: 5).fill(devConsoleGreen))
                if wide {
                    Text("Developer Console")
                        .font(.system(size: 13 * devFontScale, weight: .bold, design: .monospaced))
                        .foregroundStyle(devConsoleGreen)
                        .lineLimit(1)
                        .fixedSize()
                }
            }

            // Live metrics stay in the header on every tab — the numbers you
            // watch continuously shouldn't require being on the tools pane.
            ConsoleHeaderMetrics(debug: debug)

            Spacer(minLength: 8)

            // Wide keeps the console permanently on the left, so only the
            // inspector panes need tabs.
            tabBar(cases: wide ? DevConsoleTab.inspectorCases : DevConsoleTab.allCases,
                   wide: wide)

            CursorButton(action: onClose) {
                HStack(spacing: 4) {
                    #if os(macOS)
                    Text("esc")
                        .font(.system(size: 9 * devFontScale, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    #endif
                    Image(systemName: "xmark")
                        .font(.system(size: 11 * devFontScale, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.07)))
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Close console")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(devConsoleGreen.opacity(0.05))
    }

    /// Cursor-driven segments rather than a SwiftUI `Picker`: a segmented
    /// picker is focusable on tvOS, where this UI deliberately keeps controls
    /// out of the focus engine (`CursorButton`'s doc comment).
    private func tabBar(cases: [DevConsoleTab], wide: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(cases) { tab in
                let selected = activeTab(wide: wide) == tab
                CursorButton { console.tab = tab } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 9 * devFontScale))
                        Text(tab.rawValue)
                            .font(.system(size: 10 * devFontScale, weight: .semibold, design: .monospaced))
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? devConsoleGreen.opacity(0.22) : .white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selected ? devConsoleGreen.opacity(0.65) : .clear))
                    .foregroundStyle(selected ? devConsoleGreen : .white.opacity(0.65))
                    .contentShape(Rectangle())
                }
            }
        }
    }

    /// Which tab reads as selected. In the wide layout the console is always
    /// showing, so a `.console` selection highlights nothing in the rail —
    /// fall back to the pane the rail is actually rendering.
    private func activeTab(wide: Bool) -> DevConsoleTab {
        guard wide else { return console.tab }
        return console.tab == .console ? .tools : console.tab
    }

    // MARK: Content

    @ViewBuilder private func content(wide: Bool) -> some View {
        if wide {
            HStack(spacing: 0) {
                ConsolePane(console: console, onSelectEntity: onSelectEntity, onClose: onClose)
                Rectangle().fill(devConsoleGreen.opacity(0.25)).frame(width: 1)
                inspector(activeTab(wide: true))
                    .frame(width: 380)
            }
        } else if console.tab == .console {
            ConsolePane(console: console, onSelectEntity: onSelectEntity, onClose: onClose)
        } else {
            inspector(console.tab)
        }
    }

    @ViewBuilder private func inspector(_ tab: DevConsoleTab) -> some View {
        switch tab {
        case .console: ConsolePane(console: console, onSelectEntity: onSelectEntity, onClose: onClose)
        case .tools: DevToolsPane(console: console, debug: debug)
        case .bits: DevBitBrowser(console: console)
        case .ships: DevShipBrowser(console: console)
        case .outfits: DevOutfitBrowser(console: console)
        case .govts: DevGovtBrowser(console: console)
        }
    }
}

/// The header's live fps read-out, isolated into its own view so the metrics
/// tick redraws this label instead of the entire console.
private struct ConsoleHeaderMetrics: View {
    @ObservedObject var debug: DebugController

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(fpsColor).frame(width: 6, height: 6)
            Text(String(format: "%.0f fps · %.1f ms · %d ships",
                        debug.fps, debug.frameMsAvg, debug.shipCount))
        }
        .font(.system(size: 10 * devFontScale, design: .monospaced))
        .foregroundStyle(.white.opacity(0.7))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(0.06)))
    }

    private var fpsColor: Color {
        switch debug.fps {
        case 55...: return devConsoleGreen
        case 30..<55: return devConsoleOrange
        default: return devConsoleRed
        }
    }
}

// MARK: - Console pane

/// The log tail + command line. Text entry follows the same split every other
/// typed-input surface in the app uses (`ChatOverlayView`): a plain `TextField`
/// where there's a real keyboard, `TVCursorTextField` on tvOS where text only
/// arrives through the system fullscreen keyboard.
///
/// Every log line is a touch target: tap one to select it, and an action bar
/// offers copy, run again, edit, and category filters for it. The same actions
/// are on the right-click / long-press context menu. Command names in `help`
/// output are links that fill the prompt.
struct ConsolePane: View {
    @ObservedObject var console: ConsoleController
    /// Observed explicitly: the scrollback lives on a *separate*
    /// `ObservableObject`, so its updates publish on `log` and not on
    /// `console`. Without this the tail only refreshed when some unrelated
    /// state happened to re-render the pane.
    @ObservedObject private var log: ConsoleLogStore
    var onSelectEntity: (DevEntityRef) -> Void = { _ in }
    /// Closes the console — wired to Escape on the command-line `TextField`
    /// (see `inputBar`), since a focused text field eats Escape before
    /// `DevConsoleView`'s hidden `.keyboardShortcut(.cancelAction)` button
    /// ever sees it.
    var onClose: () -> Void = {}

    init(console: ConsoleController, onSelectEntity: @escaping (DevEntityRef) -> Void = { _ in },
         onClose: @escaping () -> Void = {}) {
        self.console = console
        self.onSelectEntity = onSelectEntity
        self.onClose = onClose
        _log = ObservedObject(wrappedValue: console.log)
    }

    @State private var draft = ""
    /// Where the ↑/↓ history walk currently sits; nil when typing fresh.
    @State private var historyIndex: Int?
    @FocusState private var inputFocused: Bool

    /// Severities hidden by the filter bar. Opt-out (empty = show everything)
    /// so a fresh console always starts showing the full stream.
    @State private var mutedSeverities: Set<ConsoleLogStore.Line.Severity> = []
    /// Same idea for categories (the `[ai]`/`[combat]`/… prefix tailed log
    /// lines already carry), keyed by the category string itself since the
    /// set of categories in play isn't known up front.
    @State private var mutedCategories: Set<String> = []
    /// Free-text filter; matches are also highlighted in the visible lines.
    @State private var search = ""
    /// Lines the user has expanded past the default 2-line collapse.
    @State private var expandedLines: Set<UUID> = []
    /// The line the action bar is acting on. While one is selected the log
    /// stops following new output, so the selection can't scroll away.
    @State private var selectedLine: UUID?
    /// Brief "Copied" confirmation in the toolbar.
    @State private var copiedFlash = false

    @AppStorage("devConsole.timestamps") private var showTimestamps = false
    @AppStorage("devConsole.follow") private var follow = true

    /// A line collapses when it's long enough that showing it in full would
    /// dominate the scrollback — either it already contains hard newlines, or
    /// it's just long (heuristic: ~2 wrapped lines' worth of monospaced text
    /// at the pane's typical width).
    private static let collapseThreshold = 160

    /// Link scheme for command names in `help` output; tapping one fills the
    /// prompt with that command.
    private static let commandScheme = "devcmd"

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        let visible = visibleLines
        VStack(spacing: 0) {
            toolbar(visible: visible)
            Rectangle().fill(devConsoleGreen.opacity(0.2)).frame(height: 1)
            logList(visible)
            if let line = selected {
                selectionBar(line)
            }
            Rectangle().fill(devConsoleGreen.opacity(0.3)).frame(height: 1)
            suggestions
            inputBar
        }
        .frame(maxWidth: .infinity)
        .onAppear { inputFocused = true }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == Self.commandScheme, let name = url.host {
                fillPrompt("\(name) ")
                return .handled
            }
            guard let ref = DevEntityRef(linkURL: url) else { return .discarded }
            onSelectEntity(ref)
            return .handled
        })
    }

    // MARK: Filters

    /// Every category seen in the current scrollback, in first-seen order —
    /// tailed log lines are prefixed `"[category] ..."` by `LogTail.fetch`.
    private var availableCategories: [String] {
        var seen: Set<String> = []
        var order: [String] = []
        for line in log.lines {
            guard let category = category(of: line) else { continue }
            if seen.insert(category).inserted { order.append(category) }
        }
        return order
    }

    private func category(of line: ConsoleLogStore.Line) -> String? {
        guard case .log = line.kind,
              line.text.hasPrefix("["), let end = line.text.firstIndex(of: "]") else { return nil }
        return String(line.text[line.text.index(after: line.text.startIndex)..<end])
    }

    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespaces) }

    private var visibleLines: [ConsoleLogStore.Line] {
        let query = trimmedSearch
        return log.lines.filter { line in
            if case let .log(severity) = line.kind {
                if mutedSeverities.contains(severity) { return false }
                if let category = category(of: line), mutedCategories.contains(category) { return false }
            }
            if !query.isEmpty, !line.text.localizedCaseInsensitiveContains(query) { return false }
            return true
        }
    }

    private var selected: ConsoleLogStore.Line? {
        guard let id = selectedLine else { return nil }
        return log.lines.first { $0.id == id }
    }

    private var filtersActive: Bool {
        !mutedSeverities.isEmpty || !mutedCategories.isEmpty || !trimmedSearch.isEmpty
    }

    private func toolbar(visible: [ConsoleLogStore.Line]) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                searchField
                Text(filtersActive ? "\(visible.count) of \(log.lines.count)" : "\(log.lines.count) lines")
                    .font(.system(size: 9 * devFontScale, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 4)
                toolButton(showTimestamps ? "clock.fill" : "clock", "Timestamps", active: showTimestamps) {
                    showTimestamps.toggle()
                }
                toolButton(follow ? "arrow.down.to.line" : "pause.fill",
                           follow ? "Following new output" : "Paused", active: follow) {
                    follow.toggle()
                }
                toolButton(copiedFlash ? "checkmark" : "doc.on.doc", "Copy visible lines",
                           active: copiedFlash) {
                    copy(visible.map(plainText).joined(separator: "\n"))
                }
                toolButton("trash", "Clear", active: false) {
                    selectedLine = nil
                    expandedLines.removeAll()
                    log.clear()
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ConsoleLogStore.Line.Severity.allCases, id: \.self) { severity in
                        filterChip(severity.displayName, color: severityColor(severity),
                                   active: !mutedSeverities.contains(severity)) {
                            toggle(severity, in: &mutedSeverities)
                        }
                    }
                    let categories = availableCategories
                    if !categories.isEmpty {
                        Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 14)
                        ForEach(categories, id: \.self) { category in
                            filterChip(category, color: .white,
                                       active: !mutedCategories.contains(category)) {
                                toggle(category, in: &mutedCategories)
                            }
                        }
                    }
                    if filtersActive {
                        Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 14)
                        filterChip("Reset filters", color: devConsoleGreen, active: true) {
                            mutedSeverities.removeAll()
                            mutedCategories.removeAll()
                            search = ""
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10 * devFontScale))
                .foregroundStyle(.secondary)
            #if os(tvOS)
            TVCursorTextField(placeholder: "Filter lines", text: $search)
            #else
            TextField("Filter lines", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 11 * devFontScale, design: .monospaced))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            #endif
            if !search.isEmpty {
                CursorButton { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10 * devFontScale))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: 260)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.1)))
    }

    private func toolButton(_ symbol: String, _ help: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        CursorButton(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11 * devFontScale, weight: .semibold))
                .frame(width: 26 * devFontScale, height: 24 * devFontScale)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(active ? devConsoleGreen.opacity(0.18) : .white.opacity(0.05)))
                .foregroundStyle(active ? devConsoleGreen : .white.opacity(0.7))
                .contentShape(Rectangle())
        }
        .help(help)
        .accessibilityLabel(help)
    }

    private func toggle<T: Hashable>(_ value: T, in set: inout Set<T>) {
        if !set.insert(value).inserted { set.remove(value) }
    }

    private func filterChip(_ title: String, color: Color, active: Bool, action: @escaping () -> Void) -> some View {
        CursorButton(action: action) {
            Text(title)
                .font(.system(size: 9 * devFontScale, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(active ? color.opacity(0.2) : .white.opacity(0.04)))
                .overlay(Capsule().strokeBorder(active ? color.opacity(0.6) : .white.opacity(0.12)))
                .foregroundStyle(active ? color : .white.opacity(0.35))
        }
    }

    // MARK: Log list

    private func logList(_ visible: [ConsoleLogStore.Line]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if log.lines.isEmpty {
                        emptyState("Streaming \(Log.subsystem). App logs appear here.\nType 'help' or tap a command below to start.")
                    } else if visible.isEmpty {
                        emptyState("No lines match the current filters.")
                    }
                    ForEach(visible) { line in
                        logRow(line)
                    }
                    Color.clear.frame(height: 1).id("console-bottom")
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: log.lines.count) { _, _ in
                guard follow, selectedLine == nil else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("console-bottom", anchor: .bottom)
                }
            }
            .onChange(of: follow) { _, following in
                if following { proxy.scrollTo("console-bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("console-bottom", anchor: .bottom) }
            .overlay(alignment: .bottomTrailing) {
                if !follow || selectedLine != nil {
                    CursorButton {
                        selectedLine = nil
                        follow = true
                        proxy.scrollTo("console-bottom", anchor: .bottom)
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                            .font(.system(size: 10 * devFontScale, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color.black.opacity(0.85)))
                            .overlay(Capsule().strokeBorder(devConsoleGreen.opacity(0.6)))
                            .foregroundStyle(devConsoleGreen)
                    }
                    .padding(10)
                }
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11 * devFontScale, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 8)
    }

    @ViewBuilder private func logRow(_ line: ConsoleLogStore.Line) -> some View {
        let collapsible = isCollapsible(line)
        let expanded = expandedLines.contains(line.id)
        let isSelected = selectedLine == line.id
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if showTimestamps {
                Text(Self.timeFormatter.string(from: line.date))
                    .font(.system(size: 9.5 * devFontScale, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
                    .monospacedDigit()
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                let text = Text(attributedText(for: line))
                    .font(.system(size: 11 * devFontScale, design: .monospaced))
                    .fontWeight(line.isCritical ? .bold : .regular)
                    .lineLimit(collapsible && !expanded ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Drag-to-select text only on the Mac. On touch, long-press
                // belongs to the row's context menu, and copying goes through
                // the action bar instead.
                #if os(macOS)
                text.textSelection(.enabled)
                #else
                text
                #endif
                if collapsible {
                    CursorButton { toggleExpanded(line.id) } label: {
                        Text(expanded ? "▾ show less" : "▸ show more")
                            .font(.system(size: 9 * devFontScale, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 2)
        .background(rowBackground(line, selected: isSelected))
        .overlay(alignment: .leading) {
            Rectangle().fill(color(for: line).opacity(isSelected ? 1 : 0.55)).frame(width: 2)
        }
        .contentShape(Rectangle())
        // Simultaneous so an entity link inside the line still fires.
        .simultaneousGesture(TapGesture().onEnded { toggleSelection(line.id) })
        #if os(tvOS)
        .cursorClickable { toggleSelection(line.id) }
        #else
        .contextMenu { lineActions(line) }
        #endif
    }

    private func rowBackground(_ line: ConsoleLogStore.Line, selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(selected ? devConsoleGreen.opacity(0.16)
                  : line.isCritical ? devConsoleRed.opacity(0.09)
                  : line.kind.isCommandEcho ? devConsoleGreen.opacity(0.05) : .clear)
    }

    private func isCollapsible(_ line: ConsoleLogStore.Line) -> Bool {
        line.text.count > Self.collapseThreshold || line.text.contains("\n")
    }

    private func toggleExpanded(_ id: UUID) {
        if !expandedLines.insert(id).inserted { expandedLines.remove(id) }
    }

    private func toggleSelection(_ id: UUID) {
        selectedLine = selectedLine == id ? nil : id
    }

    // MARK: Line actions

    /// Context-menu version of the action bar (Mac right-click, iOS long-press).
    @ViewBuilder private func lineActions(_ line: ConsoleLogStore.Line) -> some View {
        Button { copy(line.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
        Button { copy(plainText(line)) } label: { Label("Copy with time", systemImage: "clock") }
        if let command = line.echoedCommand {
            Button { console.submit(command) } label: { Label("Run again", systemImage: "arrow.clockwise") }
            Button { fillPrompt(command) } label: { Label("Edit command", systemImage: "pencil") }
        }
        if let category = category(of: line) {
            Divider()
            Button { showOnly(category) } label: { Label("Only [\(category)]", systemImage: "line.3.horizontal.decrease") }
            Button { mutedCategories.insert(category) } label: { Label("Hide [\(category)]", systemImage: "eye.slash") }
        }
        ForEach(line.entityRefs, id: \.linkURL) { ref in
            Button { onSelectEntity(ref) } label: {
                Label("Select \(ref.name.isEmpty ? "#\(ref.id)" : ref.name)", systemImage: ref.systemImage)
            }
        }
    }

    /// The touch-first way to act on a line: tap it, then pick an action here.
    private func selectionBar(_ line: ConsoleLogStore.Line) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "text.cursor")
                .font(.system(size: 10 * devFontScale))
                .foregroundStyle(devConsoleGreen)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    actionChip("Copy", "doc.on.doc") { copy(line.text) }
                    if let command = line.echoedCommand {
                        actionChip("Run again", "arrow.clockwise") { console.submit(command) }
                        actionChip("Edit", "pencil") { fillPrompt(command) }
                    }
                    if let category = category(of: line) {
                        actionChip("Only [\(category)]", "line.3.horizontal.decrease") { showOnly(category) }
                        actionChip("Hide [\(category)]", "eye.slash") { mutedCategories.insert(category) }
                    }
                    if isCollapsible(line) {
                        let expanded = expandedLines.contains(line.id)
                        actionChip(expanded ? "Collapse" : "Expand",
                                   expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                            toggleExpanded(line.id)
                        }
                    }
                    ForEach(line.entityRefs, id: \.linkURL) { ref in
                        actionChip(ref.name.isEmpty ? "#\(ref.id)" : ref.name, ref.systemImage) {
                            onSelectEntity(ref)
                        }
                    }
                }
            }
            CursorButton { selectedLine = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10 * devFontScale, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(5)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(devConsoleGreen.opacity(0.07))
        .overlay(alignment: .top) { Rectangle().fill(devConsoleGreen.opacity(0.25)).frame(height: 1) }
    }

    private func actionChip(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        CursorButton(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10 * devFontScale, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.14)))
                .foregroundStyle(.white.opacity(0.9))
                .contentShape(Rectangle())
        }
    }

    private func showOnly(_ category: String) {
        mutedCategories = Set(availableCategories).subtracting([category])
    }

    private func fillPrompt(_ text: String) {
        draft = text
        historyIndex = nil
        inputFocused = true
    }

    private func plainText(_ line: ConsoleLogStore.Line) -> String {
        "\(Self.timeFormatter.string(from: line.date))  \(line.text)"
    }

    private func copy(_ text: String) {
        DevClipboard.copy(text)
        copiedFlash = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copiedFlash = false
        }
    }

    // MARK: Rendering

    /// Renders `line.segments`: plain runs in the severity/kind colour, and
    /// `«ship:…»`/`«spob:…»` entity markers as underlined, tappable chips
    /// (SwiftUI `Text` only supports inline tap targets via `.link` runs, so
    /// clicking one fires `openURL` — see `DevEntityRef.linkURL`). Command
    /// names at the start of `help` output lines become links too, and the
    /// current search term is highlighted.
    private func attributedText(for line: ConsoleLogStore.Line) -> AttributedString {
        var result = AttributedString(line.kind.isError ? "! " : "")
        result.foregroundColor = color(for: line)
        for segment in line.segments {
            switch segment {
            case let .text(text):
                if case .commandOutput = line.kind {
                    result += linkingCommands(in: text, color: color(for: line))
                } else {
                    var run = AttributedString(text)
                    run.foregroundColor = color(for: line)
                    result += run
                }
            case let .entity(ref):
                var run = AttributedString("[\(ref.name.isEmpty ? "#\(ref.id)" : ref.name)]")
                run.foregroundColor = devConsoleGreen
                run.underlineStyle = .single
                run.link = ref.linkURL
                result += run
            }
        }
        let query = trimmedSearch
        if !query.isEmpty {
            var start = result.startIndex
            while start < result.endIndex,
                  let range = result[start...].range(of: query, options: .caseInsensitive) {
                result[range].backgroundColor = Color.yellow.opacity(0.35)
                result[range].foregroundColor = .white
                start = range.upperBound
            }
        }
        return result
    }

    /// Output text with any line that starts with a registered command name
    /// (as `help` prints them) turned into a link that fills the prompt.
    private func linkingCommands(in text: String, color: Color) -> AttributedString {
        var out = AttributedString()
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, row) in rows.enumerated() {
            if index > 0 {
                var newline = AttributedString("\n")
                newline.foregroundColor = color
                out += newline
            }
            let name = row.prefix { !$0.isWhitespace }
            if !name.isEmpty, console.commands[String(name)] != nil,
               let url = URL(string: "\(Self.commandScheme)://\(name)") {
                var link = AttributedString(String(name))
                link.foregroundColor = devConsoleGreen
                link.link = url
                out += link
                var rest = AttributedString(String(row.dropFirst(name.count)))
                rest.foregroundColor = color
                out += rest
            } else {
                var plain = AttributedString(String(row))
                plain.foregroundColor = color
                out += plain
            }
        }
        return out
    }

    private func color(for line: ConsoleLogStore.Line) -> Color {
        switch line.kind {
        case let .log(severity): return severityColor(severity)
        case .commandEcho: return devConsoleGreen
        case .commandOutput: return .white
        case .commandError: return devConsoleRed
        }
    }

    private func severityColor(_ severity: ConsoleLogStore.Line.Severity) -> Color {
        switch severity {
        case .fault: return devConsoleRed
        case .error: return devConsoleOrange
        case .notice: return devConsoleBlue
        case .info: return .white.opacity(0.78)
        case .debug: return .white.opacity(0.42)
        }
    }

    // MARK: Command line

    /// Commands whose names start with what's typed so far (first word only).
    private var matchingCommands: [ConsoleController.Command] {
        let typed = draft.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typed.isEmpty, !typed.contains(" ") else { return [] }
        return console.commands.values
            .filter { $0.name.hasPrefix(typed) && $0.name != typed }
            .sorted { $0.name < $1.name }
    }

    /// The command being typed, once its name is complete.
    private var currentCommand: ConsoleController.Command? {
        guard let name = ConsoleController.tokenize(draft).first else { return nil }
        return console.commands[name.lowercased()]
    }

    /// Before anything is typed, the commands people reach for most, so the
    /// console can be driven entirely by touch.
    private var quickCommands: [String] {
        ["help", "history", "clear"].filter { console.commands[$0] != nil }
    }

    @ViewBuilder private var suggestions: some View {
        let matches = matchingCommands
        if !matches.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(matches.prefix(12), id: \.name) { command in
                        CursorButton { fillPrompt("\(command.name) ") } label: {
                            HStack(spacing: 6) {
                                Text(command.name)
                                    .foregroundStyle(devConsoleGreen)
                                Text(command.summary)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .font(.system(size: 10 * devFontScale, design: .monospaced))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .frame(maxWidth: 320)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)))
                            .contentShape(Rectangle())
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 6)
            }
        } else if let command = currentCommand {
            Text("\(command.usage)  ·  \(command.summary)")
                .font(.system(size: 10 * devFontScale, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.top, 6)
        } else if draft.isEmpty {
            HStack(spacing: 6) {
                ForEach(quickCommands, id: \.self) { name in
                    actionChip(name, "chevron.right") { console.submit(name) }
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 6)
        }
    }

    private var inputBar: some View {
        let empty = draft.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 8) {
            Text(">")
                .font(.system(size: 13 * devFontScale, weight: .bold, design: .monospaced))
                .foregroundStyle(devConsoleGreen)
            #if os(tvOS)
            TVCursorTextField(placeholder: "command…", text: $draft, onCommit: submit)
            #else
            TextField("command…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13 * devFontScale, design: .monospaced))
                .foregroundStyle(.white)
                .focused($inputFocused)
                .onSubmit(submit)
                .autocorrectionDisabled()
                .onKeyPress(.upArrow) { walkHistory(-1); return .handled }
                .onKeyPress(.downArrow) { walkHistory(1); return .handled }
                .onKeyPress(.tab) { complete() ? .handled : .ignored }
                .onKeyPress(.escape) { onClose(); return .handled }
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            #endif
            CursorButton(action: submit) {
                Image(systemName: "return")
                    .font(.system(size: 12 * devFontScale, weight: .semibold))
                    .foregroundStyle(empty ? .white.opacity(0.3) : .black)
                    .frame(width: 30 * devFontScale, height: 24 * devFontScale)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(empty ? .white.opacity(0.06) : devConsoleGreen))
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Tab completion: the single match, or the longest prefix all matches
    /// share. Returns false when there's nothing to complete.
    private func complete() -> Bool {
        let names = matchingCommands.map(\.name)
        guard let first = names.first else { return false }
        if names.count == 1 {
            draft = first + " "
            return true
        }
        var prefix = first
        for name in names.dropFirst() {
            while !name.hasPrefix(prefix) { prefix.removeLast() }
        }
        guard prefix.count > draft.trimmingCharacters(in: .whitespaces).count else { return false }
        draft = prefix
        return true
    }

    private func submit() {
        let text = draft
        draft = ""
        historyIndex = nil
        selectedLine = nil
        console.submit(text)
        inputFocused = true
    }

    /// Shell-style ↑/↓ recall through this session's submitted commands.
    /// Walking past the newest entry returns to an empty prompt.
    private func walkHistory(_ delta: Int) {
        let history = console.submittedHistory
        guard !history.isEmpty else { return }
        let next: Int
        switch historyIndex {
        case nil:
            guard delta < 0 else { return }
            next = history.count - 1
        case let current?:
            next = current + delta
        }
        if next < 0 {
            historyIndex = 0
        } else if next >= history.count {
            historyIndex = nil
            draft = ""
            return
        } else {
            historyIndex = next
        }
        draft = history[historyIndex ?? 0]
    }
}

/// Copies plain text to the system clipboard. tvOS has none, so it's a no-op
/// there.
enum DevClipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}

extension ConsoleLogStore.Line.Kind {
    var isError: Bool {
        if case .commandError = self { return true }
        return false
    }
}

extension ConsoleLogStore.Line {
    /// Critical (`.fault`) log lines get a bolder, tinted row so the worst
    /// severity reads as unmissable even in a fast-scrolling stream.
    var isCritical: Bool {
        if case .log(.fault) = kind { return true }
        return false
    }
}

extension ConsoleLogStore.Line {
    /// The command a `> …` echo line ran, for "Run again" / "Edit".
    var echoedCommand: String? {
        guard case .commandEcho = kind else { return nil }
        let command = text.hasPrefix("> ") ? String(text.dropFirst(2)) : text
        return command.isEmpty ? nil : command
    }

    /// Ships and planets tagged in this line, in order.
    var entityRefs: [DevEntityRef] {
        segments.compactMap {
            if case let .entity(ref) = $0 { return ref }
            return nil
        }
    }
}

extension ConsoleLogStore.Line.Kind {
    var isCommandEcho: Bool {
        if case .commandEcho = self { return true }
        return false
    }
}
