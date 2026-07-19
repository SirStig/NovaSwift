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

    private enum InputDevice: String, CaseIterable, Identifiable {
        case keyboard = "Keyboard", controller = "Controller"
        var id: String { rawValue }
    }

    var body: some View {
        List {
            Section {
                Picker("Input device", selection: $device) {
                    ForEach(InputDevice.allCases) { d in Text(d.rawValue).tag(d) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
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
                        model.bindings.resetToDefaults()
                        model.commitBindings()
                    } else {
                        model.padBindings.resetToDefaults()
                        model.commitPadBindings()
                    }
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .novaResponsive()
        .navigationTitle("Controls")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .focusable()
        .onKeyPress(phases: .down) { press in
            guard let action = capturing else { return .ignored }
            let token = KeyToken.from(press)
            if token == "escape" || token.isEmpty { capturing = nil; return .handled }
            model.bindings.rebind(action, to: token)
            model.commitBindings()
            capturing = nil
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
        model.bindings.rebind(action, to: token)
        model.commitBindings()
        capturing = nil
    }
    #endif

    private func actions(in category: GameAction.Category) -> [GameAction] {
        GameAction.allCases.filter { $0.category == category }
    }

    private func row(_ action: GameAction) -> some View {
        HStack {
            Text(action.title).novaFont(.body)
            Spacer()
            Button {
                capturing = (capturing == action) ? nil : action
            } label: {
                bindingChip(capturing == action ? "Press a key…" : KeyToken.label(model.bindings.token(for: action)),
                            highlighted: capturing == action)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Controller

    private var pad: GCExtendedGamepad? {
        _ = padGeneration   // re-read when a controller (dis)connects
        return GCController.current?.extendedGamepad
    }

    private var padHint: String {
        if let name = GCController.current?.vendorName, pad != nil {
            return "\(name) connected. Tap a binding, then press the new button on the controller (tap again to cancel). Left stick steers, right stick aims — those can't be rebound."
        }
        return "No controller connected — connect one to rebind. Bindings persist and apply as soon as a controller is paired."
    }

    private func padRow(_ action: GameAction) -> some View {
        HStack {
            Text(action.title).novaFont(.body)
            Spacer()
            Button {
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
            .buttonStyle(.plain)
            .disabled(pad == nil)
            .contextMenu {
                Button("Unbind", role: .destructive) {
                    model.padBindings.unbind(action)
                    model.commitPadBindings()
                }
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
