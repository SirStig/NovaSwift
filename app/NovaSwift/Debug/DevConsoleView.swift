import SwiftUI

/// Shared chrome colour for every developer surface — the same green the debug
/// suite has always used, hoisted out so the console, tools rail and browsers
/// can't drift apart.
let devConsoleGreen = Color(red: 0.35, green: 0.95, blue: 0.5)
let devConsoleRed = Color(red: 0.95, green: 0.4, blue: 0.35)

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
    case ships = "Ships"
    case outfits = "Outfits"
    case govts = "Govts"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .console: return "terminal.fill"
        case .tools: return "slider.horizontal.3"
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
    @ObservedObject var console: ConsoleController
    /// Deliberately *not* `@ObservedObject`: `DebugController` republishes a
    /// metrics sample several times a second, and observing it here would
    /// re-run this whole body — including the log list's `ForEach` — at that
    /// rate. The children that actually read the numbers observe it
    /// themselves (`ConsoleHeaderMetrics`, `DevToolsPane`).
    let debug: DebugController
    var onClose: () -> Void

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
                ConsolePane(console: console)
                Rectangle().fill(devConsoleGreen.opacity(0.25)).frame(width: 1)
                inspector(activeTab(wide: true))
                    .frame(width: 380)
            }
        } else if console.tab == .console {
            ConsolePane(console: console)
        } else {
            inspector(console.tab)
        }
    }

    @ViewBuilder private func inspector(_ tab: DevConsoleTab) -> some View {
        switch tab {
        case .console: ConsolePane(console: console)
        case .tools: DevToolsPane(console: console, debug: debug)
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

    init(console: ConsoleController) {
        self.console = console
        _log = ObservedObject(wrappedValue: console.log)
    }

    @State private var draft = ""
    /// Where the ↑/↓ history walk currently sits; nil when typing fresh.
    @State private var historyIndex: Int?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            logList
            Rectangle().fill(devConsoleGreen.opacity(0.3)).frame(height: 1)
            inputBar
        }
        .frame(maxWidth: .infinity)
        .onAppear { inputFocused = true }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if log.lines.isEmpty {
                        Text("Streaming \(Log.subsystem) — app logs appear here. Type 'help' for commands.")
                            .font(.system(size: 11 * devFontScale, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(log.lines) { line in
                        let text = Text(line.kind.isError ? "! \(line.text)" : line.text)
                            .font(.system(size: 11 * devFontScale, design: .monospaced))
                            .foregroundStyle(color(for: line))
                        // `.textSelection` doesn't exist on tvOS (and copying a
                        // log line off a TV is meaningless anyway).
                        #if os(tvOS)
                        text
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        #else
                        text
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        #endif
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

    private func color(for line: ConsoleLogStore.Line) -> Color {
        switch line.kind {
        case let .log(severity):
            switch severity {
            case .error, .fault: return devConsoleRed
            case .debug: return .white.opacity(0.42)
            case .info, .notice: return .white.opacity(0.78)
            }
        case .commandEcho: return devConsoleGreen
        case .commandOutput: return .white
        case .commandError: return devConsoleRed
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
