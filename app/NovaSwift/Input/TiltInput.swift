import Foundation
import NovaSwiftEngine
#if os(iOS)
import CoreMotion

/// Device-tilt steering for the "Tilt to Turn" control scheme. Reads Core
/// Motion's gravity vector and feeds a turn intent into the shared
/// `InputController.tilt` source. Only runs while the scheme is active (the
/// flight scene starts/stops it) so it costs nothing otherwise.
final class TiltInput {
    private weak var input: InputController?
    private let motion = CMMotionManager()
    private(set) var isActive = false

    init(input: InputController) { self.input = input }

    func start() {
        guard motion.isDeviceMotionAvailable else { return }
        if !motion.isDeviceMotionActive {
            motion.deviceMotionUpdateInterval = 1.0 / 60.0
            motion.startDeviceMotionUpdates()
        }
        isActive = true
    }

    func stop() {
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
        isActive = false
        input?.tilt = ControlIntent()
    }

    /// Poll the current tilt into a discrete turn. `sensitivity` (the player's
    /// "Tilt sensitivity" setting) lowers the tilt threshold as it rises.
    ///
    /// Steers off the gravity vector's x component — how far the device is rolled
    /// left/right while held in landscape. The exact axis/sign can vary by
    /// orientation; this is the tunable starting point.
    func poll(sensitivity: Double) {
        guard isActive, let dm = motion.deviceMotion else { return }
        var c = ControlIntent()
        let axis = dm.gravity.x
        let threshold = 0.16 / max(0.3, sensitivity)
        if axis > threshold { c.turnRight = true }
        else if axis < -threshold { c.turnLeft = true }
        input?.tilt = c
    }
}
#endif
