import Foundation
import GameController
import NovaSwiftEngine

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
    /// map, dialog or panel open, and not landed). Discrete actions only fire
    /// while active; continuous state always applies (and releases) so a held
    /// button can never stick on across an overlay opening.
    var isActive: () -> Bool = { true }

    /// Buttons currently down, for edge-triggering discrete actions.
    private var held: Set<PadButton> = []

    init(input: InputController) {
        self.input = input
        NotificationCenter.default.addObserver(
            self, selector: #selector(changed),
            name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(changed),
            name: .GCControllerDidDisconnect, object: nil)
        GCController.startWirelessControllerDiscovery {}
        changed()
    }

    @objc private func changed() {
        let current = GCController.current
        isConnected = current?.extendedGamepad != nil
        controllerName = isConnected ? current?.vendorName : nil
        if !isConnected {
            input?.controller = ControlIntent()
            held.removeAll()
        }
    }

    /// Poll the current controller state into a fresh controller intent, and
    /// edge-fire any newly pressed discrete bindings.
    func poll() {
        guard let pad = GCController.current?.extendedGamepad else { return }
        var c = ControlIntent()

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
            // Screen up is +y on the stick; heading 0 = up, clockwise.
            c.desiredHeading = Double(atan2(rx, ry))
        }

        // Bindable buttons: continuous actions drive the intent while held;
        // discrete actions fire once on the press edge (release just clears).
        let active = isActive()
        for button in PadButton.allCases {
            let pressed = button.isPressed(on: pad)
            let wasHeld = held.contains(button)
            if pressed { held.insert(button) } else { held.remove(button) }
            guard let action = bindings.action(for: button) else { continue }

            switch action.flightEffect {
            case .turnLeft: if pressed { c.turnLeft = true }
            case .turnRight: if pressed { c.turnRight = true }
            case .thrust: if pressed { c.thrust = true }
            case .reverse: if pressed { c.reverse = true }
            case .afterburner: if pressed { c.afterburner = true }
            case .firePrimary: if pressed { c.firePrimary = true }
            case .fireSecondary: if pressed { c.fireSecondary = true }
            case .none:
                if pressed, !wasHeld, active {
                    let onDiscrete = onDiscrete
                    DispatchQueue.main.async { onDiscrete(action) }
                }
            }
        }

        input?.controller = c
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
