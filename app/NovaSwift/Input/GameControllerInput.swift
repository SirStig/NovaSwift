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

    // MARK: Action wheels

    /// Live wheel set (a button that is a wheel's trigger is tap/hold dual-use).
    /// Set by `GameHost` / the container like `bindings`.
    var wheels = ActionWheels.load()
    /// Hold longer than this (or push the right stick) and the wheel opens;
    /// release sooner and it was a tap.
    static let wheelHoldDelay: TimeInterval = 0.22

    private struct WheelHold {
        let wheel: ActionWheel
        let button: PadButton
        let start: TimeInterval
        /// The right stick was already pushed (aiming) when the trigger went
        /// down; only a push that starts after the press can open the wheel
        /// early, so tapping LB/RB mid-aim stays a tap.
        var stickWasAiming: Bool
        var open = false
        /// Ⓑ was pressed while open: release does nothing.
        var cancelled = false
        var selected: Int?
    }
    private var wheelHold: WheelHold?
    /// Self-destruct picked from a wheel. The original holds the key for five
    /// seconds and releasing aborts; a wheel can't be held that long, so the
    /// command latches (`c.selfDestruct` every poll) until ANY pad button is
    /// pressed, which aborts it.
    private var selfDestructLatched = false
    /// Last state pushed to `ActionWheelState`, so main is only hit on change.
    private var publishedWheel: (id: String?, highlighted: Int?) = (nil, nil)
    /// When the scene last polled. "Pause while an action wheel is open"
    /// freezes the SKScene, which stops `update` and with it `poll()` — so
    /// while a wheel is open this timer keeps polling whenever the scene
    /// hasn't, or the wheel could never see its trigger released.
    private var lastPoll: TimeInterval = 0
    private var wheelPump: Timer?

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
            closeWheel()
        }
    }

    /// Poll the current controller state into a fresh controller intent, and
    /// edge-fire any newly pressed discrete bindings.
    /// The flight camera's rotation (`GameScene.viewRotation`): a stick
    /// direction on screen is this far from the same direction in the world.
    var headingOffset: Double = 0

    func poll() {
        lastPoll = ProcessInfo.processInfo.systemUptime
        guard let pad = GCController.active?.extendedGamepad else { return }
        var c = ControlIntent()

        // A menu/dialog owns the pad: the sticks drive the UI cursor, not the
        // ship. An empty intent also releases anything that was held.
        guard isActive() else {
            if wasActive { setAdaptiveTriggers(flying: false) }
            wasActive = false
            held.removeAll()
            closeWheel()
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

        // Ⓑ while a wheel is open cancels it. Handled before the button loop
        // and blocked, so that press never also fires the secondary weapon.
        if var h = wheelHold, h.open, !h.cancelled,
           PadButton.buttonB.isPressed(on: pad), !held.contains(.buttonB) {
            h.cancelled = true
            wheelHold = h
            blocked.insert(.buttonB)
        }
        let now = ProcessInfo.processInfo.systemUptime
        let stickMag = hypot(rx, ry)

        for button in PadButton.allCases {
            let pressed = button.isPressed(on: pad)
            let wasHeld = held.contains(button)
            if pressed { held.insert(button) } else { held.remove(button) }
            if !pressed { blocked.remove(button) }
            // Any fresh press aborts a latched wheel self-destruct.
            if pressed, !wasHeld, selfDestructLatched { selfDestructLatched = false }

            // Wheel triggers: tap fires the normal binding, hold opens the wheel.
            if active, !blocked.contains(button),
               let wheel = wheels.wheel(for: button),
               ActionWheels.canTrigger(button, bindings: bindings) {
                if pressed, !wasHeld, wheelHold == nil {
                    wheelHold = WheelHold(wheel: wheel, button: button, start: now,
                                          stickWasAiming: stickMag > 0.5)
                } else if var h = wheelHold, h.button == button {
                    if pressed {
                        if stickMag <= 0.5 { h.stickWasAiming = false }
                        if !h.open, now - h.start >= Self.wheelHoldDelay || (stickMag > 0.5 && !h.stickWasAiming) {
                            h.open = true
                        }
                        if h.open, !h.cancelled, stickMag > 0.5,
                           let i = ActionWheels.slotIndex(x: rx, y: ry, count: h.wheel.slots.count) {
                            h.selected = i      // sticky: recentring keeps the pick
                        }
                        wheelHold = h
                    } else {
                        wheelHold = nil
                        let onDiscrete = onDiscrete
                        if !h.open {
                            // A tap: the button's own action, on release.
                            if let action = bindings.action(for: button), !action.continuous {
                                DispatchQueue.main.async { onDiscrete(action) }
                            }
                        } else if !h.cancelled, let i = h.selected, h.wheel.slots.indices.contains(i) {
                            let action = h.wheel.slots[i]
                            if action == .selfDestruct { selfDestructLatched = true }
                            else if !action.continuous { DispatchQueue.main.async { onDiscrete(action) } }
                        }
                    }
                }
                continue
            }
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

        // An open wheel owns the right stick (it picks a slot, it doesn't aim).
        if wheelHold?.open == true { c.desiredHeading = nil }
        if selfDestructLatched { c.selfDestruct = true }
        publishWheel()

        input?.controller = c
    }

    /// Close any wheel without executing it (menu took the pad, pad lost).
    /// Also drops a latched self-destruct.
    private func closeWheel() {
        wheelHold = nil
        selfDestructLatched = false
        publishWheel()
    }

    private func publishWheel() {
        let open = wheelHold.flatMap { $0.open && !$0.cancelled ? $0 : nil }
        updateWheelPump(running: wheelHold?.open == true)
        let id = open?.wheel.id
        let hi = open?.selected
        guard id != publishedWheel.id || hi != publishedWheel.highlighted else { return }
        publishedWheel = (id, hi)
        let wheel = open?.wheel
        DispatchQueue.main.async {
            MainActor.assumeIsolated { ActionWheelState.shared.apply(wheel: wheel, highlighted: hi) }
        }
    }

    private func updateWheelPump(running: Bool) {
        if running, wheelPump == nil {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                if ProcessInfo.processInfo.systemUptime - self.lastPoll > 0.05 { self.poll() }
            }
            RunLoop.main.add(timer, forMode: .common)
            wheelPump = timer
        } else if !running, let timer = wheelPump {
            timer.invalidate()
            wheelPump = nil
        }
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
