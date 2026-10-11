import SwiftUI
import GameController
#if os(macOS)
import AppKit
#endif

/// Full, rebindable controls (EV Nova scheme) for both keyboard and game
/// controller. Keyboard: tap a key to rebind, then press the new key (Escape
/// cancels). Controller: tap a binding, then press the new button on the
/// connected pad. Works with any hardware keyboard (Mac, iPad) and any
/// MFi / Xbox / PlayStation controller.
struct ControlsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var capturing: GameAction?
    @State private var padCapturing: GameAction?
    /// Bumped on controller connect/disconnect so the pad tab re-renders with
    /// the live controller's name and per-vendor button labels.
    @State private var padGeneration = 0
    @State private var device: InputDevice = .keyboard
    /// Key Settings edits a shadow copy (0x00734bc8): OK commits it, Cancel
    /// discards it, Reset only previews the defaults (0x0048b280).
    @State private var draft: KeyBindings?
    /// The row OK refused on: it holds a key another row also holds.
    @State private var conflict: GameAction?

    private enum InputDevice: String, CaseIterable, Identifiable {
        case keyboard = "Keyboard", controller = "Controller"
        var id: String { rawValue }
    }

    var body: some View {
        List {
            Section {
                // Cursor-pressable (a system segmented Picker isn't) — and
                // this is the controller-remapping screen, so a pad has to be
                // able to reach it.
                NovaSegmentedPicker(selection: $device, options: Array(InputDevice.allCases)) { $0.rawValue }
                Text(device == .keyboard
                     ? "Tap a key to rebind, then press the new key — or hold a modifier alone, like Control (Esc cancels). These match EV Nova's scheme and drive keyboard play."
                     : padHint)
                    .novaFont(.caption).foregroundStyle(.secondary)
            }
            ForEach(GameAction.Category.allCases) { category in
                Section(category.rawValue) {
                    ForEach(actions(in: category)) { action in
                        device == .keyboard ? AnyView(row(action)) : AnyView(padRow(action))
                    }
                }
            }
            Section {
                Button(role: .destructive) {
                    if device == .keyboard {
                        var preview = keys
                        preview.resetToDefaults(modern: model.settings.enhancements.modernKeyBindings)
                        draft = preview
                        conflict = nil
                    } else {
                        model.padBindings.resetToDefaults()
                        model.commitPadBindings()
                    }
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.novaPlain)
                .foregroundStyle(.red)
            }
            if pad != nil {
                // The toolbar's Cancel/Done are system chrome the controller
                // cursor can't press — mirror them in the list for pad players
                // (Ⓑ = Cancel and Menu = Done work anywhere on this screen too).
                Section {
                    HStack(spacing: 12) {
                        Spacer()
                        CursorButton { draft = nil; dismiss() } label: { bindingChip("Cancel", highlighted: false) }
                        CursorButton { commitKeys() } label: { bindingChip("Done", highlighted: true) }
                    }
                }
            }
        }
        .cursorScrollable()
        .cursorCancel(padCapturing == nil ? { draft = nil; dismiss() } : nil)
        .cursorDefault(padCapturing == nil ? { commitKeys() } : nil)
        .novaResponsive()
        .navigationTitle("Controls")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { draft = nil; dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) { Button("Done") { commitKeys() } }
        }
        .focusable()
        .onAppear { if draft == nil { draft = model.bindings } }
        .onKeyPress(phases: .down) { press in
            guard let action = capturing else { return .ignored }
            let token = KeyToken.from(press)
            if token == "escape" || token.isEmpty { capturing = nil; return .handled }
            capture(token, for: action)
            return .handled
        }
        #if os(macOS)
        // A bare modifier tap (e.g. Control, the real-EV-Nova default for
        // "fire secondary weapon") never reaches `onKeyPress` above — see
        // `ModifierFlagsBridge`'s doc comment — so it's captured here instead.
        .background {
            if capturing != nil { ModifierFlagsBridge(onChange: captureModifier) }
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            padGeneration += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            padGeneration += 1
            endPadCapture()
        }
        .onDisappear { endPadCapture() }
    }

    #if os(macOS)
    private func captureModifier(_ flags: NSEvent.ModifierFlags) {
        guard let action = capturing, let token = bareModifierToken(flags) else { return }
        capture(token, for: action)
    }
    #endif

    /// The bindings being edited.
    private var keys: KeyBindings { draft ?? model.bindings }

    /// Every keyboard row, in display order.
    private var keyRows: [GameAction] { GameAction.Category.allCases.flatMap { actions(in: $0) } }

    /// A captured key binds the row and moves to the next one (0x0048b6d0);
    /// a key the original refuses is ignored.
    private func capture(_ token: String, for action: GameAction) {
        guard KeyBindings.isCapturable(token) else { beep(); return }
        var edited = keys
        edited.assign(action, to: token)
        draft = edited
        conflict = nil
        let rows = keyRows
        if let i = rows.firstIndex(of: action), i + 1 < rows.count { capturing = rows[i + 1] } else { capturing = nil }
    }

    /// OK: refused (beep, conflicting row selected) while two rows share a
    /// key; otherwise the shadow copy becomes the live table.
    private func commitKeys() {
        capturing = nil
        if let clash = keys.firstConflict(in: keyRows) {
            conflict = clash
            beep()
            return
        }
        if let draft { model.bindings = draft; model.commitBindings() }
        dismiss()
    }

    private func beep() {
        #if os(macOS)
        NSSound.beep()
        #endif
    }

    private func actions(in category: GameAction.Category) -> [GameAction] {
        GameAction.allCases.filter { $0.category == category }
    }

    private func row(_ action: GameAction) -> some View {
        HStack {
            Text(action.title).novaFont(.body)
            Spacer()
            CursorButton {
                capturing = (capturing == action) ? nil : action
            } label: {
                bindingChip(capturing == action ? "Press a key…" : KeyToken.label(keys.token(for: action)),
                            highlighted: capturing == action || conflict == action)
            }
        }
    }

    // MARK: Controller

    private var pad: GCExtendedGamepad? {
        _ = padGeneration   // re-read when a controller (dis)connects
        return GCController.current?.extendedGamepad
    }

    private var padHint: String {
        if let name = GCController.current?.vendorName, pad != nil {
            return "\(name) connected. Select a binding, then press the new button on the controller (it cancels itself after a few seconds; ✕ unbinds). Left stick steers, right stick aims — those can't be rebound. In menus: left stick moves the cursor, right stick scrolls, d-pad jumps between buttons, Ⓐ selects, Ⓑ goes back."
        }
        return "No controller connected — connect one to rebind. Bindings persist and apply as soon as a controller is paired."
    }

    private func padRow(_ action: GameAction) -> some View {
        HStack {
            Text(action.title).novaFont(.body)
            Spacer()
            CursorButton {
                padCapturing == action ? endPadCapture() : beginPadCapture(action)
            } label: {
                HStack(spacing: 5) {
                    if padCapturing != action,
                       let symbol = model.padBindings.button(for: action)?.symbolName(on: pad) {
                        Image(systemName: symbol)
                    }
                    bindingChip(padLabel(action), highlighted: padCapturing == action)
                }
            }
            .disabled(pad == nil)
            .contextMenu {
                Button("Unbind", role: .destructive) {
                    model.padBindings.unbind(action)
                    model.commitPadBindings()
                }
            }
            // Unbind without a context menu (which the cursor can't open).
            if pad != nil, padCapturing != action, model.padBindings.button(for: action) != nil {
                CursorButton {
                    model.padBindings.unbind(action)
                    model.commitPadBindings()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Unbind \(action.title)")
            }
        }
    }

    private func padLabel(_ action: GameAction) -> String {
        if padCapturing == action { return "Press a button…" }
        guard let button = model.padBindings.button(for: action) else { return "—" }
        return button.displayName(on: pad)
    }

    /// Arm capture: the next pressed button on the connected pad becomes this
    /// action's binding. Uses the pad's own change handler so it works even
    /// though no game scene is polling here.
    private func beginPadCapture(_ action: GameAction) {
        guard let pad else { return }
        capturing = nil
        padCapturing = action
        // The pad belongs to the capture now: park the UI cursor so the
        // pressed button (Ⓐ, the d-pad, Ⓑ…) doesn't also click, snap or
        // back out. It resumes after release (see the overlay's held-button
        // guard). No answer in 6 s cancels, so a pad-only player can't get
        // stuck waiting.
        CursorTargets.shared.suspend("pad-capture")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if padCapturing == action { endPadCapture() }
        }
        pad.valueChangedHandler = { pad, element in
            guard let button = PadButton.match(element, on: pad) else { return }
            DispatchQueue.main.async {
                guard padCapturing == action else { return }
                model.padBindings.rebind(action, to: button)
                model.commitPadBindings()
                endPadCapture()
            }
        }
    }

    private func endPadCapture() {
        CursorTargets.shared.resume("pad-capture")
        padCapturing = nil
        GCController.current?.extendedGamepad?.valueChangedHandler = nil
    }

    // MARK: Shared chrome

    private func bindingChip(_ text: String, highlighted: Bool) -> some View {
        Text(text)
            .novaFont(.hud, weight: .semibold)
            .foregroundStyle(highlighted ? Color.accentColor : .primary)
            .frame(minWidth: 64)
            .padding(.vertical, 5).padding(.horizontal, 10)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(highlighted ? Color.accentColor : .white.opacity(0.15)))
    }
}
