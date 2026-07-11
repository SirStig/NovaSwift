import SwiftUI

/// A rebindable key map (action → key token). Tokens are stable strings like
/// "left", "space", "j" so they persist and display cleanly. Defaults follow
/// EV Nova's scheme; everything is user-rebindable in Settings → Controls.
struct KeyBindings: Codable, Equatable {
    private(set) var map: [GameAction: String]

    init(map: [GameAction: String] = KeyBindings.defaults) { self.map = map }

    static let defaults: [GameAction: String] = [
        .accelerate: "up", .decelerate: "down", .turnLeft: "left", .turnRight: "right",
        .afterburner: "shift",
        .firePrimary: "space", .fireSecondary: "return",
        .selectSecondaryPrev: "[", .selectSecondaryNext: "]", .toggleCloak: "c",
        // Matches the real game's default control scheme: Tab cycles targets
        // ("Target Select"), R snaps to the closest ("Closest Targ"), Y hails.
        .targetNearest: "r", .targetNext: "tab", .nearestHostile: "t", .clearTarget: "u",
        .land: "l", .hyperjump: "j", .galaxyMap: "m", .autopilot: "a",
        .hailTarget: "y", .board: "b",
        .pauseGame: "p", .openMenu: "escape",
    ]

    func token(for action: GameAction) -> String { map[action] ?? "" }

    func action(for token: String, continuousOnly: Bool = false) -> GameAction? {
        for (action, t) in map where t == token {
            if continuousOnly && !action.continuous { continue }
            return action
        }
        return nil
    }

    mutating func rebind(_ action: GameAction, to token: String) {
        // Clear any other action holding this token (no duplicate bindings).
        for (a, t) in map where t == token && a != action { map[a] = "" }
        map[action] = token
    }

    mutating func resetToDefaults() { map = KeyBindings.defaults }

    // MARK: Persistence

    static let storageKey = "com.novaswift.keybindings.v1"

    static func load() -> KeyBindings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return KeyBindings()
        }
        var m = KeyBindings.defaults
        for (k, v) in decoded { if let a = GameAction(rawValue: k) { m[a] = v } }
        return KeyBindings(map: m)
    }

    func save() {
        let raw = Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// Maps SwiftUI key presses to stable tokens and back to human labels.
enum KeyToken {
    static func from(_ press: KeyPress) -> String {
        switch press.key {
        case .leftArrow: return "left"
        case .rightArrow: return "right"
        case .upArrow: return "up"
        case .downArrow: return "down"
        case .space: return "space"
        case .return: return "return"
        case .tab: return "tab"
        case .escape: return "escape"
        case .delete: return "delete"
        default:
            if let c = press.characters.first, !press.characters.isEmpty {
                return String(c).lowercased()
            }
            return ""
        }
    }

    /// Human-readable label for a token (for the Controls UI).
    static func label(_ token: String) -> String {
        switch token {
        case "": return "—"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "space": return "Space"
        case "return": return "Return"
        case "tab": return "Tab"
        case "escape": return "Esc"
        case "shift": return "Shift"
        case "delete": return "Delete"
        default: return token.uppercased()
        }
    }
}
