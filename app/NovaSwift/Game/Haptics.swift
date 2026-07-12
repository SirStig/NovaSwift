import Foundation
#if os(iOS)
import UIKit
#endif

/// Lightweight haptic feedback, gated by the player's "Haptic feedback" setting.
/// A no-op on platforms without a Taptic Engine (macOS). Callers fire it on
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
    }
}
