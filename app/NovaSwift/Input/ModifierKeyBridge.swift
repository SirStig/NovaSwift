#if os(macOS)
import SwiftUI
import AppKit

/// Reports raw modifier-flag transitions via a local AppKit event monitor.
///
/// SwiftUI's `.onKeyPress` never delivers a bare modifier-key press —  AppKit
/// only reports one as an `NSEvent` of type `.flagsChanged`, never `.keyDown`,
/// and `onKeyPress` only bridges `keyDown`/`keyUp` — so this is the one
/// reliable way to notice "the player is holding Control" with no other key
/// down. `NSEvent.addLocalMonitorForEvents` fires for the app's own events
/// regardless of which view is first responder, which sidesteps having to
/// fight SwiftUI for keyboard focus.
///
/// The bridging `NSView` never draws anything and always returns `nil` from
/// `hitTest`, so it can sit in a `.background()` without stealing clicks from
/// whatever it's layered under.
struct ModifierFlagsBridge: NSViewRepresentable {
    var onChange: (NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        context.coordinator.install(onChange: onChange)
        return view
    }

    func updateNSView(_ nsView: PassthroughView, context: Context) {
        context.coordinator.onChange = onChange
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onChange: (NSEvent.ModifierFlags) -> Void = { _ in }
        private var monitor: Any?

        func install(onChange: @escaping (NSEvent.ModifierFlags) -> Void) {
            self.onChange = onChange
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.onChange(event.modifierFlags)
                return event
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Bare-modifier tokens this app recognizes, in priority order for the (rare)
/// case more than one is held at once. Only the three "real" modifiers a
/// single key press can express — Shift is excluded because a bare Shift tap
/// has no EV Nova meaning and composes into ordinary characters everywhere
/// else in this binding system.
private let bareModifierTokens: [(token: String, flag: NSEvent.ModifierFlags)] = [
    ("control", .control), ("option", .option), ("command", .command),
]

/// Drives the same continuous flight/combat intents `KeyboardControls` does,
/// but from bare-modifier transitions (`ModifierFlagsBridge`) instead of
/// character keys — the macOS-only half of the real EV Nova default "Control
/// fires the selected secondary weapon."
struct ModifierKeyControls: ViewModifier {
    let input: InputController
    let bindings: KeyBindings
    var onDiscrete: (GameAction) -> Void = { _ in }

    @State private var down: Set<String> = []

    func body(content: Content) -> some View {
        content.background(ModifierFlagsBridge(onChange: handle))
    }

    private func handle(_ flags: NSEvent.ModifierFlags) {
        for (token, flag) in bareModifierTokens {
            let isDown = flags.contains(flag)
            let wasDown = down.contains(token)
            guard isDown != wasDown else { continue }
            if isDown { down.insert(token) } else { down.remove(token) }
            guard let action = bindings.action(for: token) else { continue }
            switch action.flightEffect {
            case .turnLeft: input.keyboard.turnLeft = isDown
            case .turnRight: input.keyboard.turnRight = isDown
            case .thrust: input.keyboard.thrust = isDown
            case .reverse: input.keyboard.reverse = isDown
            case .afterburner: input.keyboard.afterburner = isDown
            case .firePrimary: input.keyboard.firePrimary = isDown
            case .fireSecondary: input.keyboard.fireSecondary = isDown
            case .none:
                // A discrete action bound to a bare modifier only makes sense
                // on press, not release (there's no "up" to react to).
                if isDown { onDiscrete(action) }
            }
        }
    }
}

/// The bare-modifier equivalent of `KeyToken.from` for `ControlsView`'s
/// rebind-capture flow: the first of Control/Option/Command that's down in
/// `flags`, or nil while nothing (relevant) is held. Reported once per
/// physical press since the capture UI reads this only on the transition
/// into a non-nil result.
func bareModifierToken(_ flags: NSEvent.ModifierFlags) -> String? {
    bareModifierTokens.first { flags.contains($0.flag) }?.token
}

/// Safety net for the one race `GameContainerView.grabSceneFocus` can lose:
/// `KeyboardControls.onKeyPress` only fires while SwiftUI's `@FocusState`
/// has actually landed on the flight scene, and reclaiming it after an
/// overlay closes is asynchronous and can take a beat. A held arrow key
/// repeats several `keyDown`s a second — while the reclaim is still in
/// flight, every one of those falls through unhandled and AppKit answers
/// with the default system beep. This monitor drives the same turn/thrust
/// state `KeyboardControls` would and consumes the event (preventing the
/// beep), but only while `isReclaiming()` reports true, so it never
/// double-handles input once focus is actually settled, and never steals
/// arrow keys some other view (a text field, an overlay's own list
/// navigation) legitimately holds focus for.
struct ArrowKeyFocusFallback: NSViewRepresentable {
    let input: InputController
    let bindings: KeyBindings
    let isReclaiming: () -> Bool

    func makeNSView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        context.coordinator.install(input: input, bindings: bindings, isReclaiming: isReclaiming)
        return view
    }

    func updateNSView(_ nsView: PassthroughView, context: Context) {
        context.coordinator.input = input
        context.coordinator.bindings = bindings
        context.coordinator.isReclaiming = isReclaiming
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var input: InputController?
        var bindings: KeyBindings?
        var isReclaiming: (() -> Bool)?
        private var monitor: Any?

        func install(input: InputController, bindings: KeyBindings, isReclaiming: @escaping () -> Bool) {
            self.input = input
            self.bindings = bindings
            self.isReclaiming = isReclaiming
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, self.isReclaiming?() == true,
                      let token = Self.arrowToken(event.keyCode),
                      let action = self.bindings?.action(for: token) else { return event }
                let pressed = event.type == .keyDown
                switch action.flightEffect {
                case .turnLeft: self.input?.keyboard.turnLeft = pressed
                case .turnRight: self.input?.keyboard.turnRight = pressed
                case .thrust: self.input?.keyboard.thrust = pressed
                case .reverse: self.input?.keyboard.reverse = pressed
                default: break
                }
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        private static func arrowToken(_ keyCode: UInt16) -> String? {
            switch keyCode {
            case 123: return "left"
            case 124: return "right"
            case 125: return "down"
            case 126: return "up"
            default: return nil
            }
        }
    }

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
