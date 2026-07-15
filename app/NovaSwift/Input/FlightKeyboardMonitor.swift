#if os(macOS)
import SwiftUI
import AppKit

/// Gives the flight scene true "video-game keyboard" ownership on macOS.
///
/// The old path drove flight through SwiftUI's `@FocusState` + `.onKeyPress`
/// (`KeyboardControls`), and the app kept losing the race for focus: while the
/// scene wasn't the first responder, held arrow keys fell straight through to
/// AppKit's unhandled-key **alert beep**, and bare arrows/Tab became SwiftUI
/// **focus navigation** that visibly "switched screens" mid-flight. Chasing
/// focus with retries (`grabSceneFocus`, `ArrowKeyFocusFallback`) never fully
/// closed the gap.
///
/// This drops the focus dependency entirely. One AppKit local event monitor
/// sees every key event *before* it reaches the responder chain. While
/// `isActive()` is true — the flight scene owns the screen and no text field is
/// first responder — it:
///  * drives every binding (turn / thrust / fire, bare modifiers, and discrete
///    actions like map/land/jump) straight onto `InputController`, exactly like
///    `KeyboardControls` did; and
///  * **consumes** the event (`return nil`).
///
/// Consuming is the whole fix: a swallowed key can neither ring the beep nor
/// drive focus navigation. Command chords (⌘Q, Full Screen, …) are always
/// passed through so menu shortcuts keep working, and *everything* passes
/// through untouched while `isActive()` is false, so overlays, text fields and
/// the launcher keep ordinary keyboard behaviour.
///
/// This fully *replaces* the cross-platform `KeyboardControls` on macOS —
/// `GameContainerView` applies `KeyboardControls` only on non-macOS. Running
/// both would double-handle every key: `.onKeyPress` on the `.focusable()`
/// flight view still fires even though this monitor returns `nil`, and while a
/// discrete action *toggles* (menu/map), two fires per press cancel out. On
/// iOS this type doesn't exist and `KeyboardControls` still runs.
struct FlightKeyboardMonitor: NSViewRepresentable {
    let input: InputController
    let bindings: KeyBindings
    /// True only while the flight scene should own the keyboard (no menu, map,
    /// dialog or panel open, and not landed).
    let isActive: () -> Bool
    /// Fires a discrete (fire-once) action — open menu, land, jump, target, …
    var onDiscrete: (GameAction) -> Void = { _ in }

    func makeNSView(context: Context) -> PassthroughView {
        context.coordinator.sync(self)
        context.coordinator.install()
        return PassthroughView()
    }

    func updateNSView(_ nsView: PassthroughView, context: Context) {
        context.coordinator.sync(self)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var input: InputController?
        private var bindings: KeyBindings?
        private var isActive: (() -> Bool)?
        private var onDiscrete: ((GameAction) -> Void)?
        private var monitor: Any?
        /// Bare modifiers currently held, so a release drives the matching
        /// binding off exactly like a key-up.
        private var heldModifiers: Set<String> = []

        func sync(_ v: FlightKeyboardMonitor) {
            input = v.input
            bindings = v.bindings
            isActive = v.isActive
            onDiscrete = v.onDiscrete
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        /// Returns the event to pass it through, or `nil` to consume it.
        private func handle(_ event: NSEvent) -> NSEvent? {
            // Never touch keys aimed at a live text editor (rename pilot, chat,
            // search): the field editor is an `NSText` subclass first responder.
            if event.window?.firstResponder is NSText { return event }
            let active = isActive?() == true

            switch event.type {
            case .flagsChanged:
                handleFlags(event.modifierFlags, active: active)
                // Don't consume: a bare modifier neither beeps nor navigates,
                // and passing it through keeps ⌘-chords intact.
                return event

            case .keyDown, .keyUp:
                // Let menu-shortcut chords (⌘…) reach the menu bar untouched.
                if event.modifierFlags.contains(.command) { return event }
                let pressed = event.type == .keyDown
                if let token = Self.token(for: event), let action = bindings?.action(for: token) {
                    apply(action, pressed: pressed, isRepeat: event.isARepeat, active: active)
                }
                // Consume every non-command key *while flying* — bound or not —
                // so nothing falls through to the beep or SwiftUI focus
                // navigation. When inactive, pass through so menus/overlays get
                // the key normally.
                return active ? nil : event

            default:
                return event
            }
        }

        private func handleFlags(_ flags: NSEvent.ModifierFlags, active: Bool) {
            let mods: [(String, NSEvent.ModifierFlags)] = [
                ("shift", .shift), ("control", .control),
                ("option", .option), ("command", .command),
            ]
            for (token, flag) in mods {
                let isDown = flags.contains(flag)
                guard isDown != heldModifiers.contains(token) else { continue }
                if isDown { heldModifiers.insert(token) } else { heldModifiers.remove(token) }
                guard let action = bindings?.action(for: token) else { continue }
                apply(action, pressed: isDown, isRepeat: false, active: active)
            }
        }

        /// Continuous flight state is applied on *both* press and release
        /// regardless of `active`, so a movement key that's still held when a
        /// discrete action (e.g. Map) opens an overlay can never get stuck on —
        /// its release always lands. Discrete actions only fire while active.
        private func apply(_ action: GameAction, pressed: Bool, isRepeat: Bool, active: Bool) {
            guard let input else { return }
            switch action.flightEffect {
            case .turnLeft: input.keyboard.turnLeft = pressed
            case .turnRight: input.keyboard.turnRight = pressed
            case .thrust: input.keyboard.thrust = pressed
            case .reverse: input.keyboard.reverse = pressed
            case .afterburner: input.keyboard.afterburner = pressed
            case .firePrimary: input.keyboard.firePrimary = pressed
            case .fireSecondary: input.keyboard.fireSecondary = pressed
            case .none:
                // Discrete: fire once on the initial press (ignore auto-repeat),
                // and only when the scene owns the keyboard. Deferred a tick for
                // the same "publishing changes from within view updates" reason
                // `KeyboardControls` defers — `onDiscrete` mutates SwiftUI state.
                if active, pressed, !isRepeat, let onDiscrete {
                    DispatchQueue.main.async { onDiscrete(action) }
                }
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        /// NSEvent → the same stable token strings `KeyToken.from` produces for
        /// SwiftUI presses, so bindings resolve identically on both paths.
        /// `charactersIgnoringModifiers` mirrors `press.key.character`: it drops
        /// Option composition (Option+W stays "w", not "∑").
        static func token(for event: NSEvent) -> String? {
            let base: String
            switch event.keyCode {
            case 123: base = "left"
            case 124: base = "right"
            case 125: base = "down"
            case 126: base = "up"
            case 49:  base = "space"
            case 36, 76: base = "return"     // 76 = numpad Enter
            case 48:  base = "tab"
            case 53:  base = "escape"
            case 51, 117: base = "delete"    // 117 = forward-delete
            default:
                guard let chars = event.charactersIgnoringModifiers,
                      let first = chars.first else { return nil }
                base = String(first).lowercased()
            }
            if event.modifierFlags.contains(.option) { return "opt+\(base)" }
            return base
        }
    }

    /// Draws nothing and never takes a click, so it can sit in `.background()`.
    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
