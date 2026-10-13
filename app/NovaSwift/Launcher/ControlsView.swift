import SwiftUI
import GameController
#if os(macOS)
import AppKit
#endif

/// Full, rebindable controls (EV Nova scheme) for keyboard and game controller,
/// as a visual editor: a drawn keyboard / controller beside the action list
/// (`ControlsEditor/`). Both ways to bind stay available — pick an action then
/// press the physical key/button (or click the art), or click a key/button on
/// the art and pick what it does. Works with any hardware keyboard (Mac, iPad)
/// and any MFi / Xbox / PlayStation controller.
struct ControlsView: View {
    @EnvironmentObject private var model: AppModel
    /// Closes the editor. It's presented as a full-window overlay (the drawn
    /// keyboard and pad need the room a sheet doesn't give), so the host owns
    /// dismissal rather than a navigation/sheet environment.
    var onClose: () -> Void
    /// Keyboard rows armed for capture (the next key press binds it).
    @State private var capturing: GameAction?
    @State private var padCapturing: GameAction?
    /// Bumped on controller connect/disconnect so the pad tab re-renders with
    /// the live controller's name and per-vendor button labels.
    @State private var padGeneration = 0
    @State private var tab: EditorTab = .keyboard
    /// Key Settings edits a shadow copy (0x00734bc8): OK commits it, Cancel
    /// discards it, Reset only previews the defaults (0x0048b280).
    @State private var draft: KeyBindings?
    /// The row OK refused on: it holds a key another row also holds.
    @State private var conflict: GameAction?

    @State private var prefs = ControlsEditorPrefs.load()
    @State private var layer: KeyLayer = .base
    /// Device-first selection: a key (by `KeyCap.id`) or pad button picked on the art.
    @State private var selectedKey: String?
    @State private var selectedPad: PadButton?
    @State private var hoveredAction: GameAction?
    /// Pad buttons physically held, polled while the Controller tab is open.
    @State private var pressed: Set<PadButton> = []
    @FocusState private var rootFocus: Bool

    private enum EditorTab: String, CaseIterable, Identifiable {
        case keyboard = "Keyboard", controller = "Controller"
        #if os(iOS)
        case touch = "Touch"
        #endif
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.07).ignoresSafeArea())
        .cursorCancel(padCapturing == nil ? { cancel() } : nil)
        .cursorDefault(padCapturing == nil ? { commitKeys() } : nil)
        .novaResponsive()
        .focusable()
        .focused($rootFocus)
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
        .onChange(of: tab) { _, _ in clearSelection() }
        .onChange(of: prefs) { _, new in
            new.save()
            selectedKey = nil       // key ids belong to the previous layout
        }
        .onChange(of: layer) { _, _ in selectedKey = nil }
        .task(id: tab == .controller) { await pollPressed() }
        .onDisappear { endPadCapture() }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .keyboard:
            KeyboardTab(keys: keys, prefs: $prefs, layer: $layer, capturing: capturing,
                        selectedKey: $selectedKey, hoveredAction: $hoveredAction, conflicts: conflicts,
                        onKeyTap: keyTapped, onActionTap: keyActionTapped, onUnbind: unbindKey)
        case .controller:
            ControllerTab(prefs: $prefs, bindings: model.padBindings, pad: pad, capturing: padCapturing,
                          selectedButton: $selectedPad, hoveredAction: $hoveredAction, pressed: pressed,
                          onButtonTap: padButtonTapped, onActionTap: padActionTapped, onUnbind: unbindPad)
        #if os(iOS)
        case .touch:
            TouchTab()
        #endif
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            CursorButton(action: resetToDefaults) {
                Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    .novaFont(.body).foregroundStyle(.red)
            }
            if conflict != nil {
                Text("Two actions share a key (red) — change one, then press Done.")
                    .novaFont(.caption).foregroundStyle(.red)
            }
            Spacer()
        }
    }

    /// Title, device tabs and Cancel/Done in one bar. Everything is a
    /// `CursorButton`/`NovaSegmentedPicker` (system chrome isn't cursor-
    /// pressable, and this is the controller-remapping screen); Ⓑ = Cancel and
    /// Menu = Done work anywhere on the screen too.
    private var header: some View {
        HStack(spacing: 16) {
            Text("Controls").novaFont(.title, weight: .bold).foregroundStyle(novaAmber)
            NovaSegmentedPicker(selection: $tab, options: Array(EditorTab.allCases)) { $0.rawValue }
                .frame(maxWidth: 420)
            Spacer(minLength: 12)
            CursorButton { cancel() } label: { EditorChip(text: "Cancel") }
            CursorButton { commitKeys() } label: { EditorChip(text: "Done", highlighted: true) }
        }
    }

    private func cancel() {
        draft = nil
        onClose()
    }

    private func resetToDefaults() {
        switch tab {
        case .keyboard:
            var preview = keys
            preview.resetToDefaults(modern: model.settings.enhancements.modernKeyBindings)
            draft = preview
            conflict = nil
            capturing = nil
        case .controller:
            model.padBindings.resetToDefaults()
            model.commitPadBindings()
        #if os(iOS)
        case .touch:
            model.touchLayout = .default
            model.commitTouchLayout()
        #endif
        }
    }

    private func clearSelection() {
        capturing = nil
        selectedKey = nil
        selectedPad = nil
        hoveredAction = nil
        endPadCapture()
    }

    // MARK: Keyboard

    #if os(macOS)
    private func captureModifier(_ flags: NSEvent.ModifierFlags) {
        guard let action = capturing, let token = bareModifierToken(flags) else { return }
        capture(token, for: action)
    }
    #endif

    /// The bindings being edited.
    private var keys: KeyBindings { draft ?? model.bindings }

    /// Every keyboard row, in display order.
    private var keyRows: [GameAction] {
        GameAction.Category.allCases.flatMap { category in GameAction.allCases.filter { $0.category == category } }
    }

    /// Rows sharing a key with another row — drawn red on both the list and the board.
    private var conflicts: Set<GameAction> {
        let held = Dictionary(grouping: keyRows.filter { !keys.token(for: $0).isEmpty }, by: { keys.token(for: $0) })
        var set = Set(held.values.filter { $0.count > 1 }.flatMap { $0 })
        if let conflict { set.insert(conflict) }
        return set
    }

    /// A captured key binds the row and moves to the next one (0x0048b6d0);
    /// a key the original refuses is ignored.
    private func capture(_ token: String, for action: GameAction) {
        guard KeyBindings.isCapturable(token) else { beep(); return }
        var edited = keys
        edited.assign(action, to: token)
        draft = edited
        conflict = nil
        let rows = keyRows
        if let i = rows.firstIndex(of: action), i + 1 < rows.count {
            capturing = rows[i + 1]
            showLayer(of: rows[i + 1])
        } else {
            capturing = nil
        }
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
        onClose()
    }

    private func beep() {
        #if os(macOS)
        NSSound.beep()
        #endif
    }

    /// Flip the board to the layer an action's key lives on so it is in view.
    private func showLayer(of action: GameAction) {
        let token = keys.token(for: action)
        if !token.isEmpty { layer = KeyLayer.of(token: token) }
    }

    /// A row picked in the list: with a key selected on the board it assigns
    /// to that key; otherwise it arms capture for the next key press.
    private func keyActionTapped(_ action: GameAction) {
        if let id = selectedKey,
           let cap = KeyboardLayouts.layout(prefs.keyboardSize ?? .automatic).keys.first(where: { $0.id == id }) {
            assignKey(cap, to: action)
            selectedKey = nil
            return
        }
        selectedKey = nil
        capturing = (capturing == action) ? nil : action
        if capturing != nil {
            showLayer(of: action)
            rootFocus = true        // pull focus off the search field so key presses reach capture
        }
    }

    /// A key clicked on the board: binds the armed action, else selects it.
    private func keyTapped(_ cap: KeyCap) {
        if let action = capturing {
            assignKey(cap, to: action)
            capturing = nil
        } else {
            selectedKey = (selectedKey == cap.id) ? nil : cap.id
        }
    }

    private func assignKey(_ cap: KeyCap, to action: GameAction) {
        guard let token = cap.token(on: layer), KeyBindings.isCapturable(cap.token) else { beep(); return }
        var edited = keys
        edited.assign(action, to: token)
        draft = edited
        conflict = nil
    }

    private func unbindKey(_ action: GameAction) {
        var edited = keys
        edited.assign(action, to: "")
        draft = edited
        conflict = nil
        if capturing == action { capturing = nil }
    }

    // MARK: Controller

    private var pad: GCExtendedGamepad? {
        _ = padGeneration   // re-read when a controller (dis)connects
        return GCController.active?.extendedGamepad
    }

    private func pollPressed() async {
        guard tab == .controller else { pressed = []; return }
        while !Task.isCancelled {
            let now: Set<PadButton> = pad.map { pad in Set(PadButton.allCases.filter { $0.isPressed(on: pad) }) } ?? []
            if now != pressed { pressed = now }
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    /// A row picked in the list: with a pad button selected on the art it
    /// binds to that button; otherwise it arms capture.
    private func padActionTapped(_ action: GameAction) {
        // Turning is the (fixed) left stick; nothing to bind.
        if action == .turnLeft || action == .turnRight { return }
        if let button = selectedPad {
            model.padBindings.rebind(action, to: button)
            model.commitPadBindings()
            selectedPad = nil
            return
        }
        padCapturing == action ? endPadCapture() : beginPadCapture(action)
    }

    /// A control clicked on the art: binds the armed action, else selects it.
    private func padButtonTapped(_ button: PadButton) {
        if let action = padCapturing {
            model.padBindings.rebind(action, to: button)
            model.commitPadBindings()
            endPadCapture()
        } else {
            selectedPad = (selectedPad == button) ? nil : button
        }
    }

    private func unbindPad(_ action: GameAction) {
        model.padBindings.unbind(action)
        model.commitPadBindings()
    }

    /// Arm capture: the next pressed button on the connected pad becomes this
    /// action's binding. Uses the pad's own change handler so it works even
    /// though no game scene is polling here. With no pad connected it only
    /// arms the art (a click on a control binds it) and never times out.
    private func beginPadCapture(_ action: GameAction) {
        endPadCapture()
        selectedPad = nil
        padCapturing = action
        guard let pad else { return }
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
        GCController.active?.extendedGamepad?.valueChangedHandler = nil
    }
}
