import Foundation
import GameController
import NovaSwiftEngine
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension GCController {
    /// The pad to read: `current`, else any connected extended gamepad.
    /// tvOS nils out `current` while the app is backgrounded and doesn't
    /// restore it on return until the pad is touched (and no DidConnect fires
    /// for a pad that never disconnected), so `current` alone left the
    /// "Connect a Game Controller" gate stuck up after every resume.
    static var active: GCController? {
        if let c = current, c.extendedGamepad != nil { return c }
        return controllers().first { $0.extendedGamepad != nil } ?? current
    }

    /// Every notification after which `active` may have changed: connect /
    /// disconnect, current-pad switches, and the app returning to foreground.
    static var activeChangeNotifications: [Notification.Name] {
        var names: [Notification.Name] = [.GCControllerDidConnect, .GCControllerDidDisconnect,
                                          .GCControllerDidBecomeCurrent, .GCControllerDidStopBeingCurrent]
        #if canImport(UIKit)
        names += [UIApplication.didBecomeActiveNotification, UIApplication.willEnterForegroundNotification]
        #elseif canImport(AppKit)
        names.append(NSApplication.didBecomeActiveNotification)
        #endif
        return names
    }
}

/// Reads a connected MFi / Xbox / PlayStation controller and feeds the shared
/// `InputController`. Twin-stick style: left stick = turn + thrust (fixed),
/// right stick = absolute aim (fixed). Every button is rebindable through
/// `PadBindings`: continuous actions (fire, throttle, afterburner) drive the
/// per-frame `ControlIntent`; discrete actions (land, jump, map, targeting…)
/// fire once per press through `onDiscrete`, exactly like the keyboard paths
/// (`FlightKeyboardMonitor` / `KeyboardControls`). Polled each frame from the
/// scene.
final class GameControllerInput {
    private weak var input: InputController?
    private(set) var isConnected = false
    /// The connected controller's marketing name, for the Controls UI.
    private(set) var controllerName: String?
    /// Analog dead zone (the player's "Stick dead zone" setting) — how far a
    /// stick must move off centre before it registers. Pushed from the scene.
    var deadzone: Float = 0.15

    /// Live controller map. Read each poll so a rebind in Settings applies
    /// immediately; set by `GameHost` and refreshed by the container.
    var bindings = PadBindings.load()
    /// Fires a discrete (fire-once) action — open menu, land, jump, target, …
    /// Dispatched async onto the main queue for the same "publishing changes
    /// from within view updates" reason the keyboard paths defer.
    var onDiscrete: (GameAction) -> Void = { _ in }
    /// True only while the flight scene should own the controller (no menu,
    /// map, dialog or panel open, and not landed). While inactive the pad
    /// produces an empty intent — the UI cursor owns the sticks and buttons —
    /// so nothing held can stick on across an overlay opening.
    var isActive: () -> Bool = { true }

    /// Buttons currently down, for edge-triggering discrete actions.
    private var held: Set<PadButton> = []
    /// Buttons that were already down when flight took the pad back (Ⓐ that
    /// just pressed a dialog's OK, Ⓑ that just backed out of a menu). They
    /// count for nothing until released — otherwise closing a dialog with Ⓐ
    /// would fire the guns the instant flight resumes.
    private var blocked: Set<PadButton> = []
    private var wasActive = true

    init(input: InputController) {
        self.input = input
        for name in GCController.activeChangeNotifications {
            NotificationCenter.default.addObserver(
                self, selector: #selector(changed), name: name, object: nil)
        }
        GCController.startWirelessControllerDiscovery {}
        changed()
    }

    @objc private func changed() {
        let current = GCController.active
        isConnected = current?.extendedGamepad != nil
        controllerName = isConnected ? current?.vendorName : nil
        // A newly paired pad re-runs the "flight took the pad" setup on the
        // next active poll (adaptive triggers, held-button guard).
        wasActive = false
        if !isConnected {
            input?.controller = ControlIntent()
            held.removeAll()
        }
    }

    /// Poll the current controller state into a fresh controller intent, and
    /// edge-fire any newly pressed discrete bindings.
    /// The flight camera's rotation (`GameScene.viewRotation`): a stick
    /// direction on screen is this far from the same direction in the world.
    var headingOffset: Double = 0

    func poll() {
        guard let pad = GCController.active?.extendedGamepad else { return }
        var c = ControlIntent()

        // A menu/dialog owns the pad: the sticks drive the UI cursor, not the
        // ship. An empty intent also releases anything that was held.
        guard isActive() else {
            if wasActive { setAdaptiveTriggers(flying: false) }
            wasActive = false
            held.removeAll()
            input?.controller = c
            return
        }

        // Left stick (fixed): horizontal = turn, up = thrust, down = reverse.
        let lx = pad.leftThumbstick.xAxis.value
        let ly = pad.leftThumbstick.yAxis.value
        let dz = max(0.05, deadzone)
        if lx < -dz { c.turnLeft = true }
        if lx > dz { c.turnRight = true }
        if ly > dz { c.thrust = true }
        if ly < -dz { c.reverse = true }

        // Right stick (fixed): absolute aim (magnitude past deadzone).
        let rx = pad.rightThumbstick.xAxis.value
        let ry = pad.rightThumbstick.yAxis.value
        if hypot(rx, ry) > max(0.5, dz) {
            // Screen up is +y on the stick; heading 0 = up, clockwise. Less
            // the camera's turn, so the stick aims where it points on screen.
            c.desiredHeading = Double(atan2(rx, ry)) - headingOffset
        }

        // Bindable buttons: continuous actions drive the intent while held;
        // discrete actions fire once on the press edge (release just clears).
        let active = isActive()
        if active, !wasActive {
            blocked = Set(PadButton.allCases.filter { $0.isPressed(on: pad) })
            setAdaptiveTriggers(flying: true)
        }
        wasActive = active
        for button in PadButton.allCases {
            let pressed = button.isPressed(on: pad)
            let wasHeld = held.contains(button)
            if pressed { held.insert(button) } else { held.remove(button) }
            if !pressed { blocked.remove(button) }
            // While a menu/dialog owns the pad (the UI cursor is driving it),
            // no button flies the ship; held ones release cleanly.
            guard active, !blocked.contains(button),
                  let action = bindings.action(for: button) else { continue }

            switch action.flightEffect {
            case .turnLeft: if pressed { c.turnLeft = true }
            case .turnRight: if pressed { c.turnRight = true }
            case .thrust: if pressed { c.thrust = true }
            case .reverse: if pressed { c.reverse = true }
            case .afterburner: if pressed { c.afterburner = true }
            case .firePrimary: if pressed { c.firePrimary = true }
            case .fireSecondary: if pressed { c.fireSecondary = true }
            case .selfDestruct: if pressed { c.selfDestruct = true }
            case .none:
                if pressed, !wasHeld {
                    let onDiscrete = onDiscrete
                    DispatchQueue.main.async { onDiscrete(action) }
                }
            }
        }

        input?.controller = c
    }

    /// DualSense adaptive triggers: a light, even resistance on both triggers
    /// while flying (they're the throttle by default — the pull reads as an
    /// engine to push against), released to a free pull whenever a menu owns
    /// the pad so clicking through UI feels normal. No-op on other pads.
    private func setAdaptiveTriggers(flying: Bool) {
        guard let dualSense = GCController.active?.extendedGamepad as? GCDualSenseGamepad else { return }
        for trigger in [dualSense.leftTrigger, dualSense.rightTrigger] {
            if flying {
                trigger.setModeFeedbackWithStartPosition(0.15, resistiveStrength: 0.35)
            } else {
                trigger.setModeOff()
            }
        }
    }

    deinit {
        setAdaptiveTriggers(flying: false)
        NotificationCenter.default.removeObserver(self)
    }
}
