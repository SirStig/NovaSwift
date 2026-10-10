import SwiftUI

/// A rebindable key map (action → key token). Tokens are stable strings like
/// "left", "space", "j" so they persist and display cleanly. Defaults follow
/// the original's table (`NovaPrefs_ResetKeyBindings` 0x004b4400, UI-15);
/// everything is user-rebindable in Settings → Controls.
struct KeyBindings: Codable, Equatable {
    private(set) var map: [GameAction: String]

    init(map: [GameAction: String] = KeyBindings.defaults) { self.map = map }

    /// The original's defaults: arrows fly, Space fires the primary, Control
    /// the secondary (W / Alt-W select it, S clears it), Z the afterburner;
    /// ` cycles targets (Shift back, Alt for escorts), R takes the nearest
    /// hostile (Alt the nearest ship), N clears the travel selection (Alt the
    /// ship target), 1–4 pick nav destinations; Y hails (Alt-Y the planet),
    /// L lands, M is the map, H arms the route, J jumps, B boards; Return
    /// dismisses a message, P opens Player Info, I mission info, E shows the
    /// Escort Commands panel and F / D / V / C (Alt-C) order them; U toggles
    /// the cloak (slot 0x29, DIK 0x16 — C is the escort Formation key in the
    /// original table, 0x004b4400).
    ///
    /// Known clash: every Control-arrow chord is a reserved macOS shortcut
    /// (Mission Control / move a Space), which the WindowServer takes before
    /// the app sees it, so turning while firing a secondary can switch Spaces.
    /// The `modernKeyBindings` enhancement's table moves the secondary to
    /// Return. iOS and tvOS cannot see a bare Control press at all, so there
    /// the secondary defaults to Return too (and dismissing a message is
    /// unbound). The Alt squad-cycle modifier and the meaning of several slots
    /// are open question Q-UI-04.
    static let defaults: [GameAction: String] = {
        var m: [GameAction: String] = [
            .accelerate: "up", .decelerate: "down", .turnLeft: "left", .turnRight: "right",
            .afterburner: "z",
            .firePrimary: "space", .fireSecondary: "control",
            .selectSecondaryNext: "w", .selectSecondaryPrev: "opt+w", .clearSecondary: "s",
            .toggleCloak: "u", .recallFighters: "",
            .eject: "opt+x", .selfDestruct: "opt+-",
            .targetNext: "`", .targetPrevious: "~", .targetEscortNext: "opt+`",
            .nearestHostile: "r", .targetNearest: "opt+r",
            .clearTarget: "n", .clearShipTarget: "opt+n",
            .selectNav1: "1", .selectNav2: "2", .selectNav3: "3", .selectNav4: "4",
            .hailTarget: "y", .hailStellar: "opt+y", .land: "l", .galaxyMap: "m",
            .hyperspaceArm: "h", .hyperjump: "j", .board: "b", .autopilot: "a",
            .dismissMessage: "return", .playerInfo: "p", .missionInfo: "i",
            .openEscorts: "e",
            .commandEscortAggressive: "f", .commandEscortDefensive: "d", .commandEscortHold: "v",
            .commandEscortFormation: "c", .commandEscortReturnHangar: "opt+c",
            .commandEscortEvasive: "", .shipInfo: "", .pauseGame: "",
            .openMenu: "escape",
        ]
        #if !os(macOS)
        m[.fireSecondary] = "return"
        m[.dismissMessage] = ""
        #endif
        return m
    }()

    /// The port's earlier layout, the `modernKeyBindings` enhancement: Return
    /// fires secondaries (no Control-arrow clash on macOS), Shift is the
    /// afterburner, P pauses, I opens ship info, X orders escorts evasive, Tab
    /// cycles targets, R/T take the nearest ship/hostile and U clears.
    static let modernDefaults: [GameAction: String] = [
        .accelerate: "up", .decelerate: "down", .turnLeft: "left", .turnRight: "right",
        .afterburner: "shift",
        .firePrimary: "space", .fireSecondary: "return",
        .selectSecondaryPrev: "opt+w", .selectSecondaryNext: "w", .toggleCloak: "c",
        .recallFighters: "g", .eject: "opt+x",
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
        // "I" for (ship) Info — a free key in this scheme; the pilot-info panel
        // is menu-driven and holds no binding, so there's no conflict.
        .shipInfo: "i",
        .pauseGame: "p", .openMenu: "escape",
        // Commands the modern layout gained with the original's table, on keys
        // it leaves free.
        .targetPrevious: "", .targetEscortNext: "", .clearShipTarget: "",
        .selectNav1: "1", .selectNav2: "2", .selectNav3: "3", .selectNav4: "4",
        .hyperspaceArm: "h", .dismissMessage: "", .playerInfo: "", .missionInfo: "",
        .clearSecondary: "s", .hailStellar: "opt+y", .selfDestruct: "opt+-",
        .commandEscortFormation: "", .commandEscortReturnHangar: "",
    ]

    func token(for action: GameAction) -> String { map[action] ?? "" }

    func action(for token: String, continuousOnly: Bool = false) -> GameAction? {
        for (action, t) in map where t == token {
            if continuousOnly && !action.continuous { continue }
            return action
        }
        return nil
    }

    /// Key Settings' edit (0x0048b6d0): bind `token` to `action` and leave any
    /// other holder alone — duplicates are allowed while editing and refused
    /// only at OK (`firstConflict`).
    mutating func assign(_ action: GameAction, to token: String) { map[action] = token }

    /// `ControlState_FindBindingConflict` 0x00466c10: the first action, in
    /// `order`, whose key another action also holds.
    func firstConflict(in order: [GameAction]) -> GameAction? {
        var count: [String: Int] = [:]
        for a in order { let t = token(for: a); if !t.isEmpty { count[t, default: 0] += 1 } }
        return order.first { count[token(for: $0), default: 0] > 1 }
    }

    /// The keys Key Settings won't capture (`NovaInput_PeekActiveCommand`
    /// 0x00466810 skips DIK 2–5, 0x3a–0x3f and 0x70–0x71): the number keys
    /// 1–4 (the Escort Commands group keys), Caps Lock and F1–F5.
    static func isCapturable(_ token: String) -> Bool {
        if ["1", "2", "3", "4", "capslock"].contains(token) { return false }
        // F1–F5 arrive as the AppKit function-key characters U+F704…U+F708.
        if let scalar = token.unicodeScalars.first, token.unicodeScalars.count == 1,
           (0xF704...0xF708).contains(scalar.value) { return false }
        return true
    }

    mutating func rebind(_ action: GameAction, to token: String) {
        // Clear any other action holding this token (no duplicate bindings).
        for (a, t) in map where t == token && a != action { map[a] = "" }
        map[action] = token
    }

    /// Reset to the original table, or with the `modernKeyBindings`
    /// enhancement to the port's layout.
    mutating func resetToDefaults(modern: Bool = false) {
        map = modern ? KeyBindings.modernDefaults : KeyBindings.defaults
    }

    // MARK: Persistence

    static let storageKey = "com.novaswift.keybindings.v1"

    /// The stored bindings. A fresh install gets the original table. An
    /// install from before the original table shipped keeps the layout it was
    /// playing with: one that never saved bindings (but has saved settings)
    /// is pinned to the port's old defaults. Actions added since a map was
    /// saved take their default key only when nothing else already holds it.
    static func load() -> KeyBindings {
        let defaults = UserDefaults.standard
        let stored = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        guard let stored else {
            guard defaults.data(forKey: GameSettings.storageKey) != nil else {
                // A fresh install: save the original table now, so a later
                // launch doesn't mistake it for a pre-existing one.
                let fresh = KeyBindings()
                fresh.save()
                return fresh
            }
            let pinned = KeyBindings(map: modernDefaults)
            pinned.save()
            return pinned
        }
        var m: [GameAction: String] = [:]
        for (k, v) in stored { if let a = GameAction(rawValue: k) { m[a] = v } }
        // Older maps predate the original table, so fill gaps from the layout
        // they were saved under.
        let base = stored["playerInfo"] == nil ? modernDefaults : KeyBindings.defaults
        let used = Set(m.values.filter { !$0.isEmpty })
        for action in GameAction.allCases where m[action] == nil {
            let token = base[action] ?? ""
            m[action] = used.contains(token) ? "" : token
        }
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
