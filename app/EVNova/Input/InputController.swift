import Foundation
import EVNovaEngine

/// Shared input sink. Touch controls, hardware keyboard, and (later) game
/// controllers all write into this; the `GameScene` reads `intent` each frame.
/// This is the concrete home of the `ControlIntent` abstraction.
final class InputController {
    private(set) var intent = ControlIntent()

    func setTurnLeft(_ on: Bool) { intent.turnLeft = on }
    func setTurnRight(_ on: Bool) { intent.turnRight = on }
    func setThrust(_ on: Bool) { intent.thrust = on }
    func setReverse(_ on: Bool) { intent.reverse = on }
    func setFirePrimary(_ on: Bool) { intent.firePrimary = on }
    func setFireSecondary(_ on: Bool) { intent.fireSecondary = on }

    func reset() { intent = ControlIntent() }

    /// Map a WASD / space character to an intent (arrow keys are handled by the
    /// view via `KeyEquivalent`). Returns true if the key was handled.
    @discardableResult
    func handleKeyChar(_ c: Character, pressed: Bool) -> Bool {
        switch c {
        case "a", "A": setTurnLeft(pressed); return true
        case "d", "D": setTurnRight(pressed); return true
        case "w", "W": setThrust(pressed); return true
        case "s", "S": setReverse(pressed); return true
        case " ": setFirePrimary(pressed); return true
        default: return false
        }
    }
}
