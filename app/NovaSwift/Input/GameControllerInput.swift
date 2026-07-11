import Foundation
import GameController
import EVNovaEngine

/// Reads a connected MFi / Xbox / PlayStation controller and feeds the shared
/// `InputController`. Twin-stick style: left stick = turn + thrust, right stick
/// = absolute aim, A/right-trigger = fire. Polled each frame from the scene.
final class GameControllerInput {
    private weak var input: InputController?
    private(set) var isConnected = false

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
        isConnected = GCController.current?.extendedGamepad != nil
        if !isConnected { input?.controller = ControlIntent() }
    }

    /// Poll the current controller state into a fresh controller intent.
    func poll() {
        guard let pad = GCController.current?.extendedGamepad else { return }
        var c = ControlIntent()

        // Left stick: horizontal = turn, up = thrust.
        let lx = pad.leftThumbstick.xAxis.value
        let ly = pad.leftThumbstick.yAxis.value
        let deadzone: Float = 0.25
        if lx < -deadzone { c.turnLeft = true }
        if lx > deadzone { c.turnRight = true }
        if ly > deadzone { c.thrust = true }
        if ly < -deadzone { c.reverse = true }

        // Right stick: absolute aim (magnitude past deadzone).
        let rx = pad.rightThumbstick.xAxis.value
        let ry = pad.rightThumbstick.yAxis.value
        if hypot(rx, ry) > 0.5 {
            // Screen up is +y on the stick; heading 0 = up, clockwise.
            c.desiredHeading = Double(atan2(rx, ry))
        }

        // Thrust also on right trigger; fire on A or right shoulder/trigger.
        if pad.rightTrigger.value > 0.1 { c.thrust = true }
        if pad.buttonA.isPressed || pad.rightShoulder.isPressed { c.firePrimary = true }
        if pad.buttonB.isPressed { c.fireSecondary = true }
        if pad.leftTrigger.value > 0.1 { c.reverse = true }

        input?.controller = c
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
