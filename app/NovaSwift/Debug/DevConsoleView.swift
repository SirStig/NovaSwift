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
            Image(systemName: "chevron.down.square.fill")
                .foregroundStyle(devConsoleGreen)
            Text("CONSOLE / DEBUG")
                .font(.system(size: 13 * devFontScale, weight: .bold, design: .monospaced))
                .foregroundStyle(devConsoleGreen)

            // Live metrics stay in the header on every tab — the numbers you
            // watch continuously shouldn't require being on the tools pane.
            ConsoleHeaderMetrics(debug: debug)

            Spacer(minLength: 8)

            // Wide keeps the console permanently on the left, so only the
            // inspector panes need tabs.
            tabBar(cases: wide ? DevConsoleTab.inspectorCases : DevConsoleTab.allCases,
                   wide: wide)

            CursorButton(action: onClose) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12 * devFontScale, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(6)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
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
        Text(String(format: "%.0f fps · %.1fms · %d ships",
                    debug.fps, debug.frameMsAvg, debug.shipCount))
            .font(.system(size: 10 * devFontScale, design: .monospaced))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
    }
}

// MARK: - Console pane

/// The log tail + command line. Text entry follows the same split every other
/// typed-input surface in the app uses (`ChatOverlayView`): a plain `TextField`
/// where there's a real keyboard, `TVCursorTextField` on tvOS where text only
/// arrives through the system fullscreen keyboard.
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
    /// Lines the user has expanded past the default 2-line collapse.
    @State private var expandedLines: Set<UUID> = []

    /// A line collapses when it's long enough that showing it in full would
    /// dominate the scrollback — either it already contains hard newlines, or
    /// it's just long (heuristic: ~2 wrapped lines' worth of monospaced text
    /// at the pane's typical width).
    private static let collapseThreshold = 160

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Rectangle().fill(devConsoleGreen.opacity(0.2)).frame(height: 1)
            logList
            Rectangle().fill(devConsoleGreen.opacity(0.3)).frame(height: 1)
            inputBar
        }
        .frame(maxWidth: .infinity)
        .onAppear { inputFocused = true }
        .environment(\.openURL, OpenURLAction { url in
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
            guard case .log = line.kind, let category = category(of: line) else { continue }
            if seen.insert(category).inserted { order.append(category) }
        }
        return order
    }

    private func category(of line: ConsoleLogStore.Line) -> String? {
        guard line.text.hasPrefix("["), let end = line.text.firstIndex(of: "]") else { return nil }
        return String(line.text[line.text.index(after: line.text.startIndex)..<end])
    }

    private var visibleLines: [ConsoleLogStore.Line] {
        log.lines.filter { line in
            guard case let .log(severity) = line.kind else { return true }
            if mutedSeverities.contains(severity) { return false }
            if let category = category(of: line), mutedCategories.contains(category) { return false }
            return true
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ConsoleLogStore.Line.Severity.allCases, id: \.self) { severity in
                    filterChip(severity.displayName, color: severityColor(severity),
                              active: !mutedSeverities.contains(severity)) {
                        toggle(severity, in: &mutedSeverities)
                    }
                }
                if !availableCategories.isEmpty {
                    Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 14)
                    ForEach(availableCategories, id: \.self) { category in
                        filterChip(category, color: .white,
                                  active: !mutedCategories.contains(category)) {
                            toggle(category, in: &mutedCategories)
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
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

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if log.lines.isEmpty {
                        Text("Streaming \(Log.subsystem) — app logs appear here. Type 'help' for commands.")
                            .font(.system(size: 11 * devFontScale, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else if visibleLines.isEmpty {
                        Text("Every line is filtered out — toggle a chip above to see it.")
                            .font(.system(size: 11 * devFontScale, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(visibleLines) { line in
                        logRow(line)
                    }
                    Color.clear.frame(height: 1).id("console-bottom")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: log.lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("console-bottom", anchor: .bottom)
                }
            }
            .onAppear { proxy.scrollTo("console-bottom", anchor: .bottom) }
        }
    }

    @ViewBuilder private func logRow(_ line: ConsoleLogStore.Line) -> some View {
        let collapsible = isCollapsible(line)
        let expanded = expandedLines.contains(line.id)
        VStack(alignment: .leading, spacing: 2) {
            let text = Text(attributedText(for: line))
                .font(.system(size: 11 * devFontScale, design: .monospaced))
                .fontWeight(line.isCritical ? .bold : .regular)
                .lineLimit(collapsible && !expanded ? 2 : nil)
            // `.textSelection` doesn't exist on tvOS (and copying a log line
            // off a TV is meaningless anyway).
            #if os(tvOS)
            text.fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            #else
            text.textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            #endif
            if collapsible {
                CursorButton { toggleExpanded(line.id) } label: {
                    Text(expanded ? "▾ show less" : "▸ show more")
                        .font(.system(size: 9 * devFontScale, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, line.isCritical ? 2 : 0)
        .background(line.isCritical ? devConsoleRed.opacity(0.08) : .clear)
    }

    private func isCollapsible(_ line: ConsoleLogStore.Line) -> Bool {
        line.text.count > Self.collapseThreshold || line.text.contains("\n")
    }

    private func toggleExpanded(_ id: UUID) {
        if !expandedLines.insert(id).inserted { expandedLines.remove(id) }
    }

    /// Renders `line.segments`: plain runs in the severity/kind colour, and
    /// `«ship:…»`/`«spob:…»` entity markers as underlined, tappable chips
    /// (SwiftUI `Text` only supports inline tap targets via `.link` runs, so
    /// clicking one fires `openURL` — see `DevEntityRef.linkURL`).
    private func attributedText(for line: ConsoleLogStore.Line) -> AttributedString {
        var result = AttributedString(line.kind.isError ? "! " : "")
        result.foregroundColor = color(for: line)
        for segment in line.segments {
            switch segment {
            case let .text(text):
                var run = AttributedString(text)
                run.foregroundColor = color(for: line)
                result += run
            case let .entity(ref):
                var run = AttributedString("[\(ref.name.isEmpty ? "#\(ref.id)" : ref.name)]")
                run.foregroundColor = devConsoleGreen
                run.underlineStyle = .single
                run.link = ref.linkURL
                result += run
            }
        }
        return result
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

    private var inputBar: some View {
        HStack(spacing: 8) {
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
                .onKeyPress(.escape) { onClose(); return .handled }
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            #endif
            CursorButton(action: submit) {
                Image(systemName: "return")
                    .font(.system(size: 12 * devFontScale))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty
                                     ? .white.opacity(0.3) : devConsoleGreen)
                    .padding(4)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func submit() {
        let text = draft
        draft = ""
        historyIndex = nil
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
