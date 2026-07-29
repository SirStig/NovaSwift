import SwiftUI

/// The in-game **command console** — a Quake-style panel that drops down
/// from the top of the screen: a live tail of the app's own logs (via
/// `ConsoleLogStore`) with a typed command line pinned underneath, wired to
/// `ConsoleController`. Opened only while debug mode is on, alongside the
/// debug suite (see `GameContainerView.debugControls`); gated out of
/// `flightControlsVisible` so typing here never fights flight input for the
/// keyboard/controller/touch.
///
/// Text entry follows the same split every other typed-input surface in the
/// app uses (`ChatOverlayView`): a plain `TextField` on platforms with a real
/// keyboard, `TVCursorTextField` on tvOS where text only comes from the
/// system fullscreen keyboard. Opening/closing itself needs no console-
/// specific input path — the toggle button is `.novaPlain`, which is already
/// touch/mouse/controller-cursor clickable everywhere including tvOS, and the
/// macOS-only ⌘\` shortcut is wired by the caller the same way ⇧⌘D is.
struct ConsoleView: View {
    @ObservedObject var console: ConsoleController
    var onClose: () -> Void

    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private let green = Color(red: 0.35, green: 0.95, blue: 0.5)
    private let red = Color(red: 0.95, green: 0.4, blue: 0.35)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(green.opacity(0.3))
            log
            Divider().overlay(green.opacity(0.3))
            inputBar
        }
        .background(Color.black.opacity(0.95))
        .overlay(alignment: .bottom) {
            Rectangle().fill(green.opacity(0.4)).frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        .foregroundStyle(.white)
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear {
            console.log.startPolling()
            inputFocused = true
        }
        .onDisappear {
            console.log.stopPolling()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal.fill").foregroundStyle(green)
            Text("CONSOLE")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(green)
            Text("· \(console.commands.count) commands, 'help' to list")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Button { console.submit("clear") } label: {
                Image(systemName: "trash").font(.system(size: 12))
            }
            .buttonStyle(.novaPlain)
            .foregroundStyle(.white.opacity(0.6))
            Button(action: onClose) {
                Image(systemName: "chevron.up").font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(.novaPlain)
            .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if console.log.lines.isEmpty {
                        Text("No output yet — app logs will stream in here.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(console.log.lines) { line in
                        Text(displayText(line))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: line))
                            .textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("console-bottom")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: console.log.lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("console-bottom", anchor: .bottom)
                }
            }
            .onAppear { proxy.scrollTo("console-bottom", anchor: .bottom) }
        }
    }

    private func displayText(_ line: ConsoleLogStore.Line) -> String {
        switch line.kind {
        case .commandError: return "! \(line.text)"
        default: return line.text
        }
    }

    private func color(for line: ConsoleLogStore.Line) -> Color {
        switch line.kind {
        case let .log(level):
            switch level {
            case .error, .fault: return red
            case .debug: return .white.opacity(0.4)
            default: return .white.opacity(0.75)
            }
        case .commandEcho: return green
        case .commandOutput: return .white
        case .commandError: return red
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Text(">")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(green)
            #if os(tvOS)
            TVCursorTextField(placeholder: "command…", text: $draft, onCommit: submit)
            #else
            TextField("command…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white)
                .focused($inputFocused)
                .onSubmit(submit)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            #endif
            Button(action: submit) {
                Image(systemName: "return")
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty
                                     ? .white.opacity(0.3) : green)
            }
            .buttonStyle(.novaPlain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func submit() {
        let text = draft
        draft = ""
        console.submit(text)
        inputFocused = true
    }
}
