import SwiftUI

/// A rebindable key map (action → key token). Tokens are stable strings like
/// "left", "space", "j" so they persist and display cleanly. Defaults follow
/// EV Nova's scheme; everything is user-rebindable in Settings → Controls.
struct KeyBindings: Codable, Equatable {
    private(set) var map: [GameAction: String]

    init(map: [GameAction: String] = KeyBindings.defaults) { self.map = map }

    // Real EV Nova default: Spacebar fires primary; secondaries are picked
    // with W (Alt-W to go backwards, `KeyToken`'s "opt+w") and fired with the
    // Control key. Bare Control can still be rebound to in Settings ->
    // Controls (via `ModifierKeyControls`/`ModifierFlagsBridge`), but it's
    // deliberately NOT the shipped default: every arrow direction chorded
    // with Control is a reserved macOS "symbolic hotkey" by default (Mission
    // Control / move-a-space / app windows), which the WindowServer resolves
    // before the event ever reaches this app — no in-app key handling can
    // intercept it. Shipping Control as the default made flying-while-firing
    // (turn + fire secondary, i.e. Control + an arrow) intermittently punt
    // the player out to Mission Control or another Space. Return has no such
    // conflict and is fully reachable through ordinary `onKeyPress`, so both
    // platforms default to it.
    private static let fireSecondaryDefault = "return"

    static let defaults: [GameAction: String] = [
        .accelerate: "up", .decelerate: "down", .turnLeft: "left", .turnRight: "right",
        .afterburner: "shift",
        .firePrimary: "space", .fireSecondary: fireSecondaryDefault,
        .selectSecondaryPrev: "opt+w", .selectSecondaryNext: "w", .toggleCloak: "c",
        .recallFighters: "g",
        // Matches the real game's default control scheme: Tab cycles targets
        // ("Target Select"), R snaps to the closest ("Closest Targ"), Y hails.
        .targetNearest: "r", .targetNext: "tab", .nearestHostile: "t", .clearTarget: "u",
        .land: "l", .hyperjump: "j", .galaxyMap: "m", .autopilot: "a",
        .hailTarget: "y", .board: "b",
        // Real EV Nova's Fleet Control keys — F/D/V match the original exactly
        // (Attack/Defend/Hold Position); "C" is already `toggleCloak` in this
        // port's scheme, so Formation has no analog and "Evasive" (a NovaSwift
        // addition with no original counterpart) takes a free key instead.
        .commandEscortAggressive: "f", .commandEscortDefensive: "d",
        .commandEscortEvasive: "x", .commandEscortHold: "v",
        .openEscorts: "e",
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
///
/// A token is either a bare key ("w", "space", "return", …) or, for a
/// modifier held alongside a real key, "<mod>+<key>" ("opt+w"). `<mod>` is
/// currently only "opt" — that's the one authentic EV Nova combo
/// (`selectSecondaryPrev`). Bare-modifier-only tokens ("control", "option",
/// "command" — no accompanying key) are also valid and stored the same way,
/// but `KeyToken.from` never produces them: SwiftUI's `onKeyPress` has no
/// `KeyPress` to report for a lone modifier tap, only for an actual key.
/// Those come from `ModifierFlagsBridge` instead (macOS only).
enum KeyToken {
    static func from(_ press: KeyPress) -> String {
        let base = baseToken(press)
        guard !base.isEmpty else { return "" }
        // Only Option changes the produced token: Shift is already folded into
        // `press.key.character`'s case/glyph by the time it gets here (so
        // Shift+1 already reads as its own character, not "shift+1"), and
        // Command-key combos are reserved for menu shortcuts elsewhere in the
        // app rather than flight controls.
        if press.modifiers.contains(.option) { return "opt+\(base)" }
        return base
    }

    /// The physical key identity, ignoring modifier composition — using
    /// `press.key.character` (not `press.characters`) matters here: on a US
    /// layout, Option+W *composes* to "∑" in `.characters`, which would make
    /// "Alt-W to go backwards" produce a different token every time depending
    /// on what Option happens to compose the base key into.
    private static func baseToken(_ press: KeyPress) -> String {
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
            // `press.characters` (not `.key.character`) is the signal that a
            // real key was actually pressed — it's empty for the odd event
            // with no usable key at all, same guard as before this handled Option.
            guard !press.characters.isEmpty else { return "" }
            return String(press.key.character).lowercased()
        }
    }

    /// Human-readable label for a token (for the Controls UI).
    static func label(_ token: String) -> String {
        if let range = token.range(of: "+") {
            let mod = String(token[token.startIndex..<range.lowerBound])
            let base = String(token[range.upperBound...])
            return modLabel(mod) + baseLabel(base)
        }
        switch token {
        case "control": return "⌃"
        case "option": return "⌥"
        case "command": return "⌘"
        default: return baseLabel(token)
        }
    }

    private static func modLabel(_ mod: String) -> String {
        switch mod {
        case "opt": return "⌥"
        case "ctrl": return "⌃"
        case "cmd": return "⌘"
        default: return ""
        }
    }

    private static func baseLabel(_ token: String) -> String {
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
