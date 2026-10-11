import Foundation
#if os(macOS)
import AppKit
#endif

/// The Caps Lock *toggle state* (not a key press), which EV Nova reads each
/// frame with `GetKeyState(VK_CAPITAL) & 1` to switch on its 2x mode
/// (`Frame_SpaceflightLoop` 0x00417600).
///
/// - macOS: `NSEvent.modifierFlags` is the live modifier state, `.capsLock`
///   included, so it is polled on demand.
/// - iOS / iPadOS: there is no global query. A hardware keyboard reports the
///   toggle state as `EventModifiers.capsLock` on every key event
///   (`KeyPress.modifiers`, i.e. `UIKey.modifierFlags.alphaShift`), so
///   `KeyboardControls` records it here on each key press; it is current as of
///   the last key event.
enum CapsLockState {
    #if os(macOS)
    static var isOn: Bool { NSEvent.modifierFlags.contains(.capsLock) }
    #else
    nonisolated(unsafe) private static var lastReported = false
    static var isOn: Bool { lastReported }
    /// Record the toggle state a hardware-keyboard event carried.
    static func note(_ on: Bool) { lastReported = on }
    #endif
}
