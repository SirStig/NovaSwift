import Foundation
import EVNovaEngine

/// Shared input sink. Each input source (keyboard, touch, game controller, mouse)
/// keeps its own intent; the combined `intent` the scene reads is their OR-merge,
/// so sources never clobber one another. This is the concrete home of the
/// `ControlIntent` abstraction.
final class InputController {
    var keyboard = ControlIntent()
    var touch = ControlIntent()
    var controller = ControlIntent()
    var mouse = ControlIntent()

    /// The merged intent the simulation consumes.
    var intent: ControlIntent {
        ControlIntent.combined(keyboard, touch, controller, mouse)
    }

    func reset() {
        keyboard = ControlIntent(); touch = ControlIntent()
        controller = ControlIntent(); mouse = ControlIntent()
    }

    // MARK: Keyboard

    func setKeyTurnLeft(_ on: Bool) { keyboard.turnLeft = on }
    func setKeyTurnRight(_ on: Bool) { keyboard.turnRight = on }
    func setKeyThrust(_ on: Bool) { keyboard.thrust = on }
    func setKeyReverse(_ on: Bool) { keyboard.reverse = on }
    func setKeyFire(_ on: Bool) { keyboard.firePrimary = on }

    /// Map a WASD / space character (arrow keys are handled via KeyEquivalent).
    @discardableResult
    func handleKeyChar(_ c: Character, pressed: Bool) -> Bool {
        switch c {
        case "a", "A": keyboard.turnLeft = pressed; return true
        case "d", "D": keyboard.turnRight = pressed; return true
        case "w", "W": keyboard.thrust = pressed; return true
        case "s", "S": keyboard.reverse = pressed; return true
        case " ": keyboard.firePrimary = pressed; return true
        default: return false
        }
    }
}
