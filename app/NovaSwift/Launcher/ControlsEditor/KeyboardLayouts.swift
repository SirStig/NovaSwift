import SwiftUI

/// The keyboard sizes the editor can draw. Layouts are tables of keys in
/// "units" (1u = a standard key), so every preset scales to whatever space the
/// editor has.
enum KeyboardSize: String, Codable, CaseIterable, Identifiable {
    case full, tkl, seventyFive, sixtyFive, sixty, macLaptop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: return "Full (100%)"
        case .tkl: return "TKL (80%)"
        case .seventyFive: return "75%"
        case .sixtyFive: return "65%"
        case .sixty: return "60%"
        case .macLaptop: return "Mac laptop"
        }
    }

    /// Mac → its built-in layout, everywhere else a full-size board.
    static var automatic: KeyboardSize {
        #if os(macOS)
        return .macLaptop
        #else
        return .full
        #endif
    }
}

/// Which stored form of a key's binding the board is showing.
enum KeyLayer: String, CaseIterable, Identifiable {
    case base = "Base", shift = "Shift", alt = "Alt (⌥)"
    var id: String { rawValue }

    /// The layer a stored token lives on — so selecting an action can flip the
    /// board to where its key is.
    static func of(token: String) -> KeyLayer {
        if token.hasPrefix("opt+") { return .alt }
        if KeyboardLayouts.unshifted[token] != nil { return .shift }
        return .base
    }
}

/// One physical key on the drawn board.
struct KeyCap: Identifiable, Equatable {
    enum Shape { case rect, isoEnter }

    let id: String
    /// The base `KeyToken` this key produces; empty = decorative (Print Screen,
    /// the numpad, fn…) — drawn, but not bindable.
    let token: String
    let legend: String
    var frame: CGRect
    var shape: Shape = .rect

    var isBindable: Bool { !token.isEmpty }

    /// The stored token this key writes on `layer`, or nil when that layer
    /// can't bind it (modifiers have no Alt/Shift form; Shift only exists as
    /// the shifted glyph of digit/punctuation keys, since `KeyToken` folds
    /// Shift into the produced character).
    func token(on layer: KeyLayer) -> String? {
        guard isBindable else { return nil }
        switch layer {
        case .base: return token
        case .alt: return KeyboardLayouts.modifierTokens.contains(token) ? nil : "opt+" + token
        case .shift: return KeyboardLayouts.shifted[token]
        }
    }
}

struct KeyboardLayout {
    var keys: [KeyCap]
    var size: CGSize

    /// Every base token a key on this board can produce.
    var boardTokens: Set<String> { Set(keys.filter(\.isBindable).map(\.token)) }
}

enum KeyboardLayouts {
    static let modifierTokens: Set<String> = ["control", "option", "command", "shift"]

    /// Shifted glyph (as stored) for each base key that has one.
    static let shifted: [String: String] = {
        var m: [String: String] = ["`": "~", "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|",
                                   ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?"]
        for (d, s) in zip("1234567890", "!@#$%^&*()") { m[String(d)] = String(s) }
        return m
    }()
    static let unshifted: [String: String] = Dictionary(uniqueKeysWithValues: shifted.map { ($0.value, $0.key) })

    /// The physical key a stored token lives on (strips Alt, folds shifted glyphs).
    static func baseToken(of stored: String) -> String {
        var t = stored
        if t.hasPrefix("opt+") { t.removeFirst(4) }
        return unshifted[t] ?? t
    }

    // AppKit function-key characters, which is what `KeyPress.key.character` yields.
    static func fKey(_ n: Int) -> String { String(UnicodeScalar(UInt32(0xF703 + n))!) }
    static let forwardDelete = "\u{F728}", home = "\u{F729}", end = "\u{F72B}"
    static let pageUp = "\u{F72C}", pageDown = "\u{F72D}"

    static func legend(for token: String) -> String {
        switch token {
        case "escape": return "esc"
        case "delete": return "delete"
        case "tab": return "tab"
        case "return": return "return"
        case "shift": return "⇧"
        case "control": return "⌃"
        case "option": return "⌥"
        case "command": return "⌘"
        case "capslock": return "caps"
        case "space": return ""
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case forwardDelete: return "del"
        case home: return "home"
        case end: return "end"
        case pageUp: return "pg ↑"
        case pageDown: return "pg ↓"
        default:
            if let s = token.unicodeScalars.first, token.unicodeScalars.count == 1,
               (0xF704...0xF70F).contains(s.value) { return "F\(s.value - 0xF703)" }
            return token.uppercased()
        }
    }

    // MARK: Builder

    private enum Item {
        case key(String, CGFloat, String?)
        case deco(String, CGFloat)
        case gap(CGFloat)
    }
    private static func k(_ t: String, _ w: CGFloat = 1, _ legend: String? = nil) -> Item { .key(t, w, legend) }
    private static func d(_ legend: String, _ w: CGFloat = 1) -> Item { .deco(legend, w) }

    private struct Builder {
        var keys: [KeyCap] = []
        var width: CGFloat = 0, height: CGFloat = 0

        mutating func add(_ token: String, _ legend: String?, x: CGFloat, y: CGFloat, w: CGFloat = 1,
                          h: CGFloat = 1, shape: KeyCap.Shape = .rect) {
            keys.append(KeyCap(id: "k\(keys.count)", token: token,
                               legend: legend ?? KeyboardLayouts.legend(for: token),
                               frame: CGRect(x: x, y: y, width: w, height: h), shape: shape))
            width = max(width, x + w); height = max(height, y + h)
        }

        /// Lay `items` left to right from `x`; returns the x after the last one.
        @discardableResult
        mutating func row(_ items: [Item], x: CGFloat, y: CGFloat, h: CGFloat = 1) -> CGFloat {
            var cx = x
            for item in items {
                switch item {
                case .key(let t, let w, let l): add(t, l, x: cx, y: y, w: w, h: h); cx += w
                case .deco(let l, let w): add("", l, x: cx, y: y, w: w, h: h); cx += w
                case .gap(let w): cx += w
                }
            }
            return cx
        }
    }

    private static let letters1 = "qwertyuiop".map { String($0) }
    private static let letters2 = "asdfghjkl".map { String($0) }
    private static let letters3 = "zxcvbnm".map { String($0) }

    // MARK: Row groups (shared by every preset)

    private static func functionRow(_ b: inout Builder, x: CGFloat, y: CGFloat) {
        b.row([k("escape"), .gap(1)]
              + (1...4).map { k(fKey($0)) } + [.gap(0.5)]
              + (5...8).map { k(fKey($0)) } + [.gap(0.5)]
              + (9...12).map { k(fKey($0)) }, x: x, y: y)
    }

    private static func numberRow(_ b: inout Builder, x: CGFloat, y: CGFloat) {
        b.row(["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="].map { k($0) }
              + [k("delete", 2)], x: x, y: y)
    }

    private static func mainRows(_ b: inout Builder, x: CGFloat, y: CGFloat, iso: Bool, rightShift: CGFloat = 2.75) {
        // Tab row; the ISO Enter hangs down from here.
        let tabEnd = b.row([k("tab", 1.5)] + (letters1 + ["[", "]"]).map { k($0) }
                           + (iso ? [] : [k("\\", 1.5)]), x: x, y: y)
        if iso {
            b.add("return", "return", x: tabEnd, y: y, w: 1.5, h: 2, shape: .isoEnter)
        }
        // Home row.
        b.row([k("capslock", 1.75)] + (letters2 + [";", "'"]).map { k($0) }
                            + (iso ? [k("\\")] : [k("return", 2.25)]), x: x, y: y + 1)
        // Shift row.
        b.row([k("shift", iso ? 1.25 : 2.25)] + (iso ? [k("§")] : [])
              + (letters3 + [",", ".", "/"]).map { k($0) } + [k("shift", rightShift)], x: x, y: y + 2)
    }

    private static func bottomRow(_ b: inout Builder, x: CGFloat, y: CGFloat) {
        b.row([k("control", 1.25), k("option", 1.25), k("command", 1.25), k("space", 6.25),
               k("command", 1.25), k("option", 1.25), d("fn", 1.25), k("control", 1.25)], x: x, y: y)
    }

    private static func arrowKeys(_ b: inout Builder, x: CGFloat, y: CGFloat) {
        b.add("up", nil, x: x + 1, y: y)
        b.add("left", nil, x: x, y: y + 1)
        b.add("down", nil, x: x + 1, y: y + 1)
        b.add("right", nil, x: x + 2, y: y + 1)
    }

    // MARK: Presets

    static func layout(_ size: KeyboardSize, iso: Bool) -> KeyboardLayout {
        var b = Builder()
        switch size {
        case .full, .tkl:
            functionRow(&b, x: 0, y: 0)
            b.row([d("prt"), d("scr"), d("pause")], x: 15.5, y: 0)
            numberRow(&b, x: 0, y: 1.5)
            mainRows(&b, x: 0, y: 2.5, iso: iso)
            bottomRow(&b, x: 0, y: 5.5)
            b.row([d("ins"), k(KeyboardLayouts.home), k(KeyboardLayouts.pageUp)], x: 15.5, y: 1.5)
            b.row([k(KeyboardLayouts.forwardDelete), k(KeyboardLayouts.end), k(KeyboardLayouts.pageDown)], x: 15.5, y: 2.5)
            arrowKeys(&b, x: 15.5, y: 4.5)
            if size == .full {
                // The numpad shares its characters with the main block — a key
                // press can't tell them apart — so it is drawn but not bindable.
                b.row([d("num"), d("/"), d("*"), d("−")], x: 19, y: 1.5)
                b.row([d("7"), d("8"), d("9")], x: 19, y: 2.5)
                b.add("", "+", x: 22, y: 2.5, h: 2)
                b.row([d("4"), d("5"), d("6")], x: 19, y: 3.5)
                b.row([d("1"), d("2"), d("3")], x: 19, y: 4.5)
                b.add("", "↩", x: 22, y: 4.5, h: 2)
                b.add("", "0", x: 19, y: 5.5, w: 2)
                b.add("", ".", x: 21, y: 5.5)
            }
        case .seventyFive:
            b.row([k("escape")] + (1...12).map { k(fKey($0)) } + [k(KeyboardLayouts.forwardDelete), d("ins")], x: 0, y: 0)
            numberRow(&b, x: 0, y: 1.25)
            mainRows(&b, x: 0, y: 2.25, iso: iso, rightShift: 1.75)
            compactBottom(&b, y: 5.25)
            navColumn(&b, y: 1.25)
            b.add("up", nil, x: 14, y: 4.25)
            b.add(end, nil, x: 15, y: 4.25)
        case .sixtyFive:
            numberRow(&b, x: 0, y: 0)
            mainRows(&b, x: 0, y: 1, iso: iso, rightShift: 1.75)
            compactBottom(&b, y: 4)
            navColumn(&b, y: 0)
            b.add("up", nil, x: 14, y: 3)
            b.add(end, nil, x: 15, y: 3)
        case .sixty:
            numberRow(&b, x: 0, y: 0)
            mainRows(&b, x: 0, y: 1, iso: iso)
            bottomRow(&b, x: 0, y: 4)
        case .macLaptop:
            b.row([k("escape", 1.5)] + (1...12).map { k(fKey($0)) } + [d("⏻", 1.5)], x: 0, y: 0, h: 0.65)
            numberRow(&b, x: 0, y: 0.75)
            mainRows(&b, x: 0, y: 1.75, iso: iso)
            b.row([d("fn"), k("control"), k("option"), k("command", 1.25), k("space", 5.5),
                   k("command", 1.25), k("option")], x: 0, y: 4.75)
            // Inverted-T arrows with half-height up/down keys.
            b.add("left", nil, x: 12, y: 5.25, h: 0.5)
            b.add("up", nil, x: 13, y: 4.75, h: 0.5)
            b.add("down", nil, x: 13, y: 5.25, h: 0.5)
            b.add("right", nil, x: 14, y: 5.25, h: 0.5)
        }
        return KeyboardLayout(keys: b.keys, size: CGSize(width: b.width, height: b.height))
    }

    /// 65%/75% bottom row: modifiers, then the left/down/right arrows.
    private static func compactBottom(_ b: inout Builder, y: CGFloat) {
        b.row([k("control", 1.25), k("option", 1.25), k("command", 1.25), k("space", 6.25),
               k("command"), k("option"), .gap(1), k("left"), k("down"), k("right")], x: 0, y: y)
    }

    private static func navColumn(_ b: inout Builder, y: CGFloat) {
        for (i, t) in [pageUp, pageDown, home].enumerated() { b.add(t, nil, x: 15, y: y + CGFloat(i)) }
    }
}
