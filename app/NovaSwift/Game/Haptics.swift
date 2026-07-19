import Foundation
import CoreHaptics
import GameController
#if os(iOS)
import UIKit
#endif

/// Lightweight haptic feedback, gated by the player's "Haptic feedback" setting.
/// Fires the device's Taptic Engine (iOS) and, when a game controller with
/// haptics is connected (DualSense/DualShock, Xbox), rumbles the pad too — so
/// controller players on any platform feel the same cues. Callers fire it on
/// discrete moments (target lock, landing, a nearby explosion) — never per frame.
enum Haptics {
    /// Mirrors `GameSettings.hapticsEnabled`; pushed from the scene when settings
    /// load or change so call sites don't each need the settings object.
    static var enabled = true

    enum Strength { case light, medium, heavy, selection }

    static func play(_ strength: Strength) {
        guard enabled else { return }
        #if os(iOS)
        switch strength {
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .light:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .heavy:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
        #endif
        rumbleController(strength)
    }

    // MARK: Controller rumble

    /// One haptic transient on the connected controller. Quietly does nothing
    /// on pads without haptics (most MFi pads, the Siri Remote).
    private static func rumbleController(_ strength: Strength) {
        guard let engine = controllerEngine() else { return }
        let (intensity, sharpness): (Float, Float)
        switch strength {
        case .selection: (intensity, sharpness) = (0.3, 0.7)
        case .light: (intensity, sharpness) = (0.4, 0.4)
        case .medium: (intensity, sharpness) = (0.7, 0.5)
        case .heavy: (intensity, sharpness) = (1.0, 0.6)
        }
        do {
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: 0)
            let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Haptics are decorative; never let a failure surface.
        }
    }

    /// Engine for the current controller, rebuilt when the pad changes or the
    /// engine resets. Identity is tracked via the controller object itself.
    private static var cachedEngine: CHHapticEngine?
    private static weak var engineController: GCController?

    private static func controllerEngine() -> CHHapticEngine? {
        guard let controller = GCController.current, controller.haptics != nil else { return nil }
        if let cachedEngine, engineController === controller { return cachedEngine }
        guard let engine = controller.haptics?.createEngine(withLocality: .default) else { return nil }
        engine.resetHandler = { cachedEngine = nil }
        do { try engine.start() } catch { return nil }
        cachedEngine = engine
        engineController = controller
        return engine
    }
}
