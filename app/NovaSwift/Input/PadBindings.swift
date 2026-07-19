import Foundation
import GameController

/// Every bindable physical control on an extended gamepad. Raw values are the
/// stable persistence tokens (the controller-side analog of `KeyToken`).
///
/// The two thumbsticks are deliberately NOT bindable: left stick is always
/// steer/thrust and right stick is always absolute aim (`GameControllerInput`),
/// matching every twin-stick game a player has muscle memory from.
enum PadButton: String, CaseIterable, Codable, Identifiable {
    case buttonA, buttonB, buttonX, buttonY
    case leftShoulder, rightShoulder
    case leftTrigger, rightTrigger
    case leftThumbstickButton, rightThumbstickButton
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case buttonMenu, buttonOptions

    var id: String { rawValue }

    /// Generic label (Xbox-style face letters — what GameController's own
    /// generic profile uses). `displayName(on:)` upgrades it to the connected
    /// controller's real name ("Cross" on a DualSense, etc.).
    var genericLabel: String {
        switch self {
        case .buttonA: return "A"
        case .buttonB: return "B"
        case .buttonX: return "X"
        case .buttonY: return "Y"
        case .leftShoulder: return "LB"
        case .rightShoulder: return "RB"
        case .leftTrigger: return "LT"
        case .rightTrigger: return "RT"
        case .leftThumbstickButton: return "L3"
        case .rightThumbstickButton: return "R3"
        case .dpadUp: return "D-Pad ↑"
        case .dpadDown: return "D-Pad ↓"
        case .dpadLeft: return "D-Pad ←"
        case .dpadRight: return "D-Pad →"
        case .buttonMenu: return "Menu"
        case .buttonOptions: return "Options"
        }
    }

    /// The live element on a connected pad, for reading state and for showing
    /// the controller's own vendor name/symbol in the Controls UI.
    func element(on pad: GCExtendedGamepad) -> GCControllerElement? {
        switch self {
        case .buttonA: return pad.buttonA
        case .buttonB: return pad.buttonB
        case .buttonX: return pad.buttonX
        case .buttonY: return pad.buttonY
        case .leftShoulder: return pad.leftShoulder
        case .rightShoulder: return pad.rightShoulder
        case .leftTrigger: return pad.leftTrigger
        case .rightTrigger: return pad.rightTrigger
        case .leftThumbstickButton: return pad.leftThumbstickButton
        case .rightThumbstickButton: return pad.rightThumbstickButton
        case .dpadUp: return pad.dpad.up
        case .dpadDown: return pad.dpad.down
        case .dpadLeft: return pad.dpad.left
        case .dpadRight: return pad.dpad.right
        case .buttonMenu: return pad.buttonMenu
        case .buttonOptions: return pad.buttonOptions
        }
    }

    /// The connected controller's own name for this control (e.g. "Cross" on
    /// a DualSense, "A" on an Xbox pad), falling back to the generic label.
    func displayName(on pad: GCExtendedGamepad?) -> String {
        guard let pad, let element = element(on: pad) else { return genericLabel }
        return element.localizedName ?? genericLabel
    }

    /// The connected controller's SF Symbol for this control (e.g.
    /// "xmark.circle" on a DualSense) for glyph rendering in the Controls UI.
    func symbolName(on pad: GCExtendedGamepad?) -> String? {
        guard let pad, let element = element(on: pad) else { return nil }
        return element.sfSymbolsName
    }

    /// Whether this control is currently pressed. Triggers count as pressed
    /// past a small threshold so a feather touch doesn't fire weapons.
    func isPressed(on pad: GCExtendedGamepad) -> Bool {
        switch self {
        case .leftTrigger: return pad.leftTrigger.value > 0.1
        case .rightTrigger: return pad.rightTrigger.value > 0.1
        default: return (element(on: pad) as? GCControllerButtonInput)?.isPressed ?? false
        }
    }

    /// Which bindable control a `valueChangedHandler` element corresponds to —
    /// used by the Controls UI's "press a button to rebind" capture. The dpad
    /// reports as one composite element, so it resolves to whichever direction
    /// is actually held.
    static func match(_ element: GCControllerElement, on pad: GCExtendedGamepad) -> PadButton? {
        if element === pad.dpad || element === pad.dpad.up || element === pad.dpad.down
            || element === pad.dpad.left || element === pad.dpad.right {
            if pad.dpad.up.isPressed { return .dpadUp }
            if pad.dpad.down.isPressed { return .dpadDown }
            if pad.dpad.left.isPressed { return .dpadLeft }
            if pad.dpad.right.isPressed { return .dpadRight }
            return nil
        }
        for button in PadButton.allCases where button.element(on: pad) === element {
            return button.isPressed(on: pad) ? button : nil
        }
        return nil
    }
}

/// A rebindable controller map (action → pad button), the gamepad counterpart
/// of `KeyBindings`. Defaults give a full twin-stick scheme: sticks fly and
/// aim (fixed), face buttons fight, the d-pad handles navigation.
struct PadBindings: Codable, Equatable {
    private(set) var map: [GameAction: PadButton]

    init(map: [GameAction: PadButton] = PadBindings.defaults) { self.map = map }

    static let defaults: [GameAction: PadButton] = [
        // Flight: triggers throttle, stick-click boosts. Steering itself is
        // the (non-bindable) left stick.
        .accelerate: .rightTrigger, .decelerate: .leftTrigger,
        .afterburner: .leftThumbstickButton,
        // Combat on the face buttons + secondary cycling on the shoulders.
        .firePrimary: .buttonA, .fireSecondary: .buttonB,
        .selectSecondaryPrev: .leftShoulder, .selectSecondaryNext: .rightShoulder,
        .targetNext: .buttonX, .nearestHostile: .buttonY,
        .clearTarget: .rightThumbstickButton,
        // Navigation on the d-pad.
        .hyperjump: .dpadUp, .land: .dpadDown,
        .hailTarget: .dpadLeft, .board: .dpadRight,
        // Interface.
        .openMenu: .buttonMenu, .galaxyMap: .buttonOptions,
    ]

    func button(for action: GameAction) -> PadButton? { map[action] }

    func action(for button: PadButton) -> GameAction? {
        map.first(where: { $0.value == button })?.key
    }

    mutating func rebind(_ action: GameAction, to button: PadButton) {
        // One action per button (no duplicate bindings), same as KeyBindings.
        for (a, b) in map where b == button && a != action { map[a] = nil }
        map[action] = button
    }

    mutating func unbind(_ action: GameAction) { map[action] = nil }

    mutating func resetToDefaults() { map = PadBindings.defaults }

    // MARK: Persistence

    static let storageKey = "com.novaswift.padbindings.v1"

    static func load() -> PadBindings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return PadBindings()
        }
        // Stored map replaces the defaults wholesale (an action the player
        // unbound stays unbound rather than snapping back to its default).
        var m: [GameAction: PadButton] = [:]
        for (k, v) in decoded {
            if let a = GameAction(rawValue: k), let b = PadButton(rawValue: v) { m[a] = b }
        }
        return PadBindings(map: m)
    }

    func save() {
        let raw = Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value.rawValue) })
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
