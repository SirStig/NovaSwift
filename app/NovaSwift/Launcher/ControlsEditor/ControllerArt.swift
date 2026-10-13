import SwiftUI
import GameController

/// The controller silhouettes the editor can draw. All art is procedural vector
/// paths in millimetres (origin = body centre, y down) (no bitmaps, no vendor marks): each style
/// supplies a body, decor and hit-target controls, and `ControllerCanvas` scales
/// it to fit.
enum PadStyle: String, Codable, CaseIterable, Identifiable {
    case xbox, playstation, switchPro, steamDeck

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xbox: return "Xbox"
        case .playstation: return "PlayStation"
        case .switchPro: return "Switch Pro"
        case .steamDeck: return "Steam Deck"
        }
    }

    /// The family of a connected controller, nil when there is none (the editor
    /// then falls back to Xbox).
    static func detect(_ controller: GCController?) -> PadStyle? {
        guard let controller else { return nil }
        if controller.extendedGamepad is GCDualSenseGamepad || controller.extendedGamepad is GCDualShockGamepad { return .playstation }
        if controller.extendedGamepad is GCXboxGamepad { return .xbox }
        let name = ((controller.productCategory) + " " + (controller.vendorName ?? "")).lowercased()
        if name.contains("steam") { return .steamDeck }
        if name.contains("dualsense") || name.contains("dualshock") || name.contains("playstation") || name.contains("ps5") || name.contains("ps4") { return .playstation }
        if name.contains("xbox") { return .xbox }
        if name.contains("nintendo") || name.contains("switch") || name.contains("pro controller") { return .switchPro }
        return nil
    }

    /// Face-button/shoulder label as printed on this family's controller.
    func glyph(_ b: PadButton) -> String {
        switch (self, b) {
        case (.playstation, .buttonA): return "✕"
        case (.playstation, .buttonB): return "○"
        case (.playstation, .buttonX): return "□"
        case (.playstation, .buttonY): return "△"
        case (.switchPro, .buttonA): return "B"
        case (.switchPro, .buttonB): return "A"
        case (.switchPro, .buttonX): return "Y"
        case (.switchPro, .buttonY): return "X"
        case (_, .buttonA): return "A"
        case (_, .buttonB): return "B"
        case (_, .buttonX): return "X"
        case (_, .buttonY): return "Y"
        case (.xbox, .leftShoulder): return "LB"
        case (.xbox, .rightShoulder): return "RB"
        case (.xbox, .leftTrigger): return "LT"
        case (.xbox, .rightTrigger): return "RT"
        case (.switchPro, .leftShoulder): return "L"
        case (.switchPro, .rightShoulder): return "R"
        case (.switchPro, .leftTrigger): return "ZL"
        case (.switchPro, .rightTrigger): return "ZR"
        case (_, .leftShoulder): return "L1"
        case (_, .rightShoulder): return "R1"
        case (_, .leftTrigger): return "L2"
        case (_, .rightTrigger): return "R2"
        case (_, .leftThumbstickButton): return "L3"
        case (_, .rightThumbstickButton): return "R3"
        default: return ""
        }
    }

    /// What this family calls the control (callout caption).
    func name(_ b: PadButton) -> String {
        switch (self, b) {
        case (.playstation, .buttonA): return "Cross"
        case (.playstation, .buttonB): return "Circle"
        case (.playstation, .buttonX): return "Square"
        case (.playstation, .buttonY): return "Triangle"
        case (.playstation, .buttonOptions): return "Create"
        case (.playstation, .buttonMenu): return "Options"
        case (.switchPro, .buttonOptions): return "−"
        case (.switchPro, .buttonMenu): return "+"
        case (.xbox, .buttonOptions), (.steamDeck, .buttonOptions): return "View"
        case (.xbox, .buttonMenu), (.steamDeck, .buttonMenu): return "Menu"
        case (_, .dpadUp), (_, .dpadDown), (_, .dpadLeft), (_, .dpadRight): return b.genericLabel
        case (_, .leftThumbstickButton): return "L3 (click)"
        case (_, .rightThumbstickButton): return "R3 (click)"
        default: return glyph(b)
        }
    }

    var art: PadArt { PadArt.make(self) }
}

enum PadSide { case left, right }

/// One hit-target on the pad. Positions and sizes are millimetres on the real
/// device, origin at the body centre.
struct PadControl: Identifiable {
    enum DpadDir { case up, down, left, right }
    enum Kind { case round, stick, pill, trigger, bumper, dpadArm(DpadDir) }

    let button: PadButton
    let kind: Kind
    let center: CGPoint
    let size: CGSize
    var glyph = ""
    var symbol: String?
    /// Face colour; nil = neutral plastic.
    var fill: Color?
    var glyphColor: Color = .white
    var fixedRole: String?
    /// Degrees, clockwise; triggers/bumpers lean with the shoulder contour.
    var rotation: Double = 0

    var id: String { button.rawValue }
    var side: PadSide { center.x < 0 ? .left : .right }
    var mirrored: Bool { center.x >= 0 }
    var frame: CGRect { CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height) }
    var isTrigger: Bool { if case .trigger = kind { return true } else { return false } }
    var isBumper: Bool { if case .bumper = kind { return true } else { return false } }
    var isShoulder: Bool { isTrigger || isBumper }
}

struct PadDecor: Identifiable {
    enum Kind { case circle, roundRect(CGFloat), cross }
    let id: Int
    let kind: Kind
    var rect: CGRect
    var top: Color = Color(white: 0.2)
    var bottom: Color = Color(white: 0.1)
    var label: String?
    var dashed = false
}

/// A greyed callout for something the editor shows but can't bind (back grips,
/// trackpads — those are Steam Input's).
struct PadFixedNote: Identifiable {
    let id: String
    let text: String
    let anchor: CGPoint
    var side: PadSide { anchor.x < 0 ? .left : .right }
}

struct PadArt {
    var body = Path()
    var bodyTop = Color(white: 0.3)
    var bodyBottom = Color(white: 0.1)
    var decor: [PadDecor] = []
    var controls: [PadControl] = []
    var notes: [PadFixedNote] = []

    /// Everything drawn (body, triggers, bumpers, back tabs), with a small margin.
    var bounds: CGRect {
        var r = body.boundingRect
        for c in controls { r = r.union(c.frame.insetBy(dx: -2, dy: -2)) }
        for d in decor { r = r.union(d.rect) }
        return r.insetBy(dx: -2, dy: -2)
    }

    // MARK: Body outline

    /// A symmetric body from its right half: `start` is the top centre, each
    /// segment (to, c1, c2) continues clockwise to the bottom centre; the left
    /// half is the mirror image walked back.
    private static func symmetricBody(start: CGPoint, _ segs: [(CGPoint, CGPoint, CGPoint)]) -> Path {
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: -p.x, y: p.y) }
        var p = Path()
        p.move(to: start)
        var pts = [start]
        for (to, c1, c2) in segs { p.addCurve(to: to, control1: c1, control2: c2); pts.append(to) }
        for i in stride(from: segs.count, to: 0, by: -1) {
            p.addCurve(to: m(pts[i - 1]), control1: m(segs[i - 1].2), control2: m(segs[i - 1].1))
        }
        p.closeSubpath()
        return p
    }

    private static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    // MARK: Building blocks

    private struct Builder {
        var art = PadArt()
        var nextID = 0

        mutating func deco(_ kind: PadDecor.Kind, _ rect: CGRect, top: Color = Color(white: 0.2),
                           bottom: Color = Color(white: 0.09), label: String? = nil, dashed: Bool = false) {
            art.decor.append(PadDecor(id: nextID, kind: kind, rect: rect, top: top, bottom: bottom,
                                      label: label, dashed: dashed))
            nextID += 1
        }

        func square(_ c: CGPoint, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        }

        /// Recessed well (radius `r`) with a concave cap control inside it.
        mutating func stick(_ b: PadButton, _ c: CGPoint, r: CGFloat, role: String) {
            deco(.circle, square(c, r * 2, r * 2), top: Color(white: 0.03), bottom: Color(white: 0.2))
            art.controls.append(PadControl(button: b, kind: .stick, center: c,
                                           size: CGSize(width: r * 1.5, height: r * 1.5), fixedRole: role))
        }

        /// One cross plate, plus four arm hit-targets that only tint it.
        mutating func dpad(_ c: CGPoint, span: CGFloat) {
            deco(.cross, square(c, span, span), top: Color(white: 0.38), bottom: Color(white: 0.2))
            let t = span * 0.34, len = span / 2 - span * 0.1, off = span * 0.1 + len / 2
            func arm(_ b: PadButton, _ d: PadControl.DpadDir, _ dx: CGFloat, _ dy: CGFloat, vertical: Bool) {
                art.controls.append(PadControl(button: b, kind: .dpadArm(d),
                                               center: CGPoint(x: c.x + dx, y: c.y + dy),
                                               size: vertical ? CGSize(width: t, height: len) : CGSize(width: len, height: t)))
            }
            arm(.dpadUp, .up, 0, -off, vertical: true)
            arm(.dpadDown, .down, 0, off, vertical: true)
            arm(.dpadLeft, .left, -off, 0, vertical: false)
            arm(.dpadRight, .right, off, 0, vertical: false)
        }

        /// Y top, A bottom, X left, B right (the physical positions
        /// GameController reports; glyphs follow the family's printing).
        mutating func face(_ style: PadStyle, _ c: CGPoint, offset: CGFloat, r: CGFloat,
                           fills: [PadButton: Color], glyphColors: [PadButton: Color]) {
            let spots: [(PadButton, CGFloat, CGFloat)] = [(.buttonY, 0, -offset), (.buttonA, 0, offset),
                                                          (.buttonX, -offset, 0), (.buttonB, offset, 0)]
            for (b, dx, dy) in spots {
                art.controls.append(PadControl(button: b, kind: .round, center: CGPoint(x: c.x + dx, y: c.y + dy),
                                               size: CGSize(width: r * 2, height: r * 2), glyph: style.glyph(b),
                                               fill: fills[b], glyphColor: glyphColors[b] ?? .white))
            }
        }

        /// Triggers sit behind everything with ~40% showing above the bumper;
        /// bumpers are long bars along the shoulder, just behind the body's top
        /// edge and in front of the triggers.
        mutating func shoulders(_ style: PadStyle, bumperX: CGFloat, bumperY: CGFloat, bumperW: CGFloat,
                                triggerX: CGFloat, triggerY: CGFloat, triggerW: CGFloat, triggerH: CGFloat, tilt: Double) {
            for sign: CGFloat in [-1, 1] {
                let left = sign < 0
                art.controls.append(PadControl(
                    button: left ? .leftTrigger : .rightTrigger, kind: .trigger,
                    center: CGPoint(x: sign * triggerX, y: triggerY), size: CGSize(width: triggerW, height: triggerH),
                    glyph: style.glyph(left ? .leftTrigger : .rightTrigger), rotation: Double(sign) * tilt * 1.2))
                art.controls.append(PadControl(
                    button: left ? .leftShoulder : .rightShoulder, kind: .bumper,
                    center: CGPoint(x: sign * bumperX, y: bumperY), size: CGSize(width: bumperW, height: 8),
                    glyph: style.glyph(left ? .leftShoulder : .rightShoulder), rotation: Double(sign) * tilt))
            }
        }

        mutating func small(_ b: PadButton, _ c: CGPoint, r: CGFloat, symbol: String) {
            art.controls.append(PadControl(button: b, kind: .round, center: c, size: CGSize(width: r * 2, height: r * 2), symbol: symbol))
        }

        mutating func pill(_ b: PadButton, _ c: CGPoint, w: CGFloat, h: CGFloat, symbol: String? = nil) {
            art.controls.append(PadControl(button: b, kind: .pill, center: c, size: CGSize(width: w, height: h), symbol: symbol))
        }
    }

    private static let xboxFills: [PadButton: Color] = [
        .buttonA: Color(red: 0.36, green: 0.76, blue: 0.36), .buttonB: Color(red: 0.86, green: 0.27, blue: 0.27),
        .buttonX: Color(red: 0.27, green: 0.52, blue: 0.92), .buttonY: Color(red: 0.96, green: 0.80, blue: 0.22)]

    static func make(_ style: PadStyle) -> PadArt {
        switch style {
        case .xbox: return xbox()
        case .playstation: return playstation()
        case .switchPro: return switchPro()
        case .steamDeck: return deck()
        }
    }

    // MARK: Xbox Series (154 × 106 mm)

    private static func xbox() -> PadArt {
        var b = Builder()
        b.art.body = symmetricBody(start: pt(0, -47), [
            (pt(46, -50), pt(14, -48), pt(30, -51)),
            (pt(72, -33), pt(60, -49), pt(69, -42)),
            (pt(77, -4), pt(75, -27), pt(78, -16)),
            (pt(64, 44), pt(76, 18), pt(72, 34)),
            (pt(50, 53), pt(61, 52), pt(56, 56)),
            (pt(40, 47), pt(45, 52), pt(41, 51)),
            (pt(28, 34), pt(38, 40), pt(33, 35)),
            (pt(0, 30), pt(19, 31), pt(9, 30))])
        b.art.bodyTop = Color(white: 0.30); b.art.bodyBottom = Color(white: 0.11)
        b.deco(.circle, b.square(pt(0, -30), 14, 14), top: Color(white: 0.4), bottom: Color(white: 0.14))      // guide
        b.deco(.circle, b.square(pt(0, -30), 9.5, 9.5), top: Color(white: 0.16), bottom: Color(white: 0.3))
        b.deco(.roundRect(1.5), b.square(pt(0, -3), 6, 3), top: Color(white: 0.2), bottom: Color(white: 0.1))   // share
        b.shoulders(.xbox, bumperX: 46, bumperY: -54, bumperW: 38, triggerX: 52, triggerY: -56, triggerW: 24, triggerH: 22, tilt: 7)
        b.stick(.leftThumbstickButton, pt(-40, -12), r: 11, role: "Steer / Thrust")
        b.stick(.rightThumbstickButton, pt(20, 14), r: 11, role: "Aim")
        b.dpad(pt(-20, 14), span: 22)
        b.face(.xbox, pt(40, -12), offset: 8.5, r: 4.8, fills: xboxFills,
               glyphColors: [.buttonA: .black, .buttonB: .black, .buttonX: .black, .buttonY: .black])
        b.small(.buttonOptions, pt(-11, -13), r: 3.5, symbol: "rectangle.on.rectangle")
        b.small(.buttonMenu, pt(11, -13), r: 3.5, symbol: "line.3.horizontal")
        return b.art
    }

    // MARK: DualSense (160 × 106 mm)

    private static func playstation() -> PadArt {
        var b = Builder()
        b.art.body = symmetricBody(start: pt(0, -46), [
            (pt(46, -49), pt(14, -47), pt(30, -50)),
            (pt(72, -36), pt(60, -48), pt(69, -42)),
            (pt(80, -6), pt(77, -28), pt(81, -16)),
            (pt(66, 46), pt(80, 18), pt(76, 38)),
            (pt(50, 53), pt(62, 52), pt(56, 56)),
            (pt(40, 47), pt(45, 52), pt(41, 51)),
            (pt(30, 35), pt(38, 40), pt(34, 36)),
            (pt(0, 32), pt(20, 33), pt(10, 32))])
        b.art.bodyTop = Color(white: 0.96); b.art.bodyBottom = Color(white: 0.68)
        let dark = (Color(white: 0.20), Color(white: 0.07))
        b.deco(.roundRect(24), CGRect(x: -34, y: -52, width: 68, height: 82), top: dark.0, bottom: dark.1)
        // Lightbar hugging the touchpad's edges, then the touchpad itself.
        b.deco(.roundRect(5), CGRect(x: -26.5, y: -46, width: 53, height: 33), top: Color(red: 0.25, green: 0.5, blue: 1), bottom: Color(red: 0.15, green: 0.3, blue: 0.8))
        b.deco(.roundRect(4), CGRect(x: -24, y: -44, width: 48, height: 30), top: Color(white: 0.36), bottom: Color(white: 0.2))
        b.deco(.circle, b.square(pt(0, 6), 8, 8), top: Color(white: 0.5), bottom: Color(white: 0.2))             // PS button
        b.deco(.roundRect(1), b.square(pt(0, 14), 5, 2), top: Color(white: 0.4), bottom: Color(white: 0.25))      // mute
        b.shoulders(.playstation, bumperX: 47, bumperY: -53, bumperW: 38, triggerX: 53, triggerY: -55, triggerW: 24, triggerH: 22, tilt: 7)
        b.stick(.leftThumbstickButton, pt(-22, 16), r: 10.5, role: "Steer / Thrust")
        b.stick(.rightThumbstickButton, pt(22, 16), r: 10.5, role: "Aim")
        b.dpad(pt(-46, -14), span: 22)
        let tints: [PadButton: Color] = [.buttonA: Color(red: 0.45, green: 0.62, blue: 1), .buttonB: Color(red: 1, green: 0.42, blue: 0.42),
                                         .buttonX: Color(red: 0.96, green: 0.52, blue: 0.82), .buttonY: Color(red: 0.36, green: 0.86, blue: 0.62)]
        b.face(.playstation, pt(46, -14), offset: 9, r: 5, fills: tints.mapValues { _ in Color(white: 0.16) }, glyphColors: tints)
        b.pill(.buttonOptions, pt(-30, -36), w: 2.6, h: 7, symbol: nil)
        b.pill(.buttonMenu, pt(30, -36), w: 2.6, h: 7, symbol: nil)
        return b.art
    }

    // MARK: Switch Pro (152 × 106 mm)

    private static func switchPro() -> PadArt {
        var b = Builder()
        b.art.body = symmetricBody(start: pt(0, -46), [
            (pt(44, -49), pt(14, -47), pt(29, -50)),
            (pt(68, -36), pt(57, -48), pt(65, -42)),
            (pt(76, -6), pt(73, -27), pt(77, -16)),
            (pt(62, 46), pt(76, 20), pt(72, 38)),
            (pt(47, 54), pt(58, 54), pt(53, 57)),
            (pt(38, 47), pt(42, 53), pt(38, 51)),
            (pt(28, 34), pt(36, 40), pt(31, 35)),
            (pt(0, 30), pt(18, 31), pt(8, 30))])
        b.art.bodyTop = Color(white: 0.32); b.art.bodyBottom = Color(white: 0.12)
        b.deco(.roundRect(1), b.square(pt(-10, -16), 4.5, 4.5), top: Color(white: 0.24), bottom: Color(white: 0.12))   // capture
        b.deco(.circle, b.square(pt(10, -16), 7, 7), top: Color(white: 0.3), bottom: Color(white: 0.12))                // home
        b.shoulders(.switchPro, bumperX: 44, bumperY: -53, bumperW: 38, triggerX: 50, triggerY: -55, triggerW: 24, triggerH: 22, tilt: 7)
        b.stick(.leftThumbstickButton, pt(-42, -14), r: 11, role: "Steer / Thrust")
        b.stick(.rightThumbstickButton, pt(20, 12), r: 11, role: "Aim")
        b.dpad(pt(-20, 12), span: 20)
        // Dark caps with light letters, no coloured rings.
        let keys: [PadButton] = [.buttonA, .buttonB, .buttonX, .buttonY]
        b.face(.switchPro, pt(42, -14), offset: 8.5, r: 4.8, fills: Dictionary(uniqueKeysWithValues: keys.map { ($0, Color(white: 0.17)) }),
               glyphColors: Dictionary(uniqueKeysWithValues: keys.map { ($0, Color(white: 0.92)) }))
        b.pill(.buttonOptions, pt(-14, -28), w: 6, h: 2.4, symbol: "minus")
        b.pill(.buttonMenu, pt(14, -28), w: 6, h: 2.4, symbol: "plus")
        return b.art
    }

    // MARK: Steam Deck (298 × 117 mm)

    private static func deck() -> PadArt {
        var b = Builder()
        b.art.body = symmetricBody(start: pt(0, -58), [
            (pt(110, -58), pt(40, -58.5), pt(80, -58.5)),
            (pt(149, -20), pt(135, -58), pt(149, -42)),
            (pt(140, 40), pt(150, 0), pt(148, 25)),
            (pt(118, 58), pt(136, 52), pt(128, 58)),
            (pt(98, 50), pt(110, 58), pt(103, 55)),
            (pt(0, 46), pt(80, 46), pt(40, 46))])
        b.art.bodyTop = Color(white: 0.28); b.art.bodyBottom = Color(white: 0.09)
        b.deco(.roundRect(5), CGRect(x: -82, y: -47, width: 164, height: 94), top: Color(white: 0.02), bottom: Color(white: 0.08))   // bezel
        b.deco(.roundRect(3), CGRect(x: -78, y: -44, width: 156, height: 88), top: Color(red: 0.10, green: 0.17, blue: 0.28), bottom: Color(red: 0.03, green: 0.05, blue: 0.10))
        // Back tabs (L4/L5, R4/R5) under each grip, greyed.
        for sign: CGFloat in [-1, 1] {
            for dx: CGFloat in [-8, 8] {
                b.deco(.roundRect(1.5), b.square(pt(sign * 124 + dx, 60.5), 10, 4), top: Color(white: 0.22), bottom: Color(white: 0.12), dashed: true)
            }
            b.deco(.roundRect(4), b.square(pt(sign * 104, 28), 34, 34), top: Color(white: 0.17), bottom: Color(white: 0.08), label: "pad", dashed: true)   // trackpad
            b.deco(.roundRect(1.5), b.square(pt(sign * 132, 34), 7, 3), top: Color(white: 0.3), bottom: Color(white: 0.15))   // steam / QAM
        }
        b.shoulders(.steamDeck, bumperX: 112, bumperY: -62, bumperW: 52, triggerX: 114, triggerY: -66, triggerW: 44, triggerH: 20, tilt: 0)
        b.stick(.leftThumbstickButton, pt(-104, -30), r: 11, role: "Steer / Thrust")
        b.stick(.rightThumbstickButton, pt(104, -30), r: 11, role: "Aim")
        b.dpad(pt(-128, -2), span: 22)
        let keys: [PadButton] = [.buttonA, .buttonB, .buttonX, .buttonY]
        b.face(.steamDeck, pt(128, -2), offset: 8, r: 4.5, fills: Dictionary(uniqueKeysWithValues: keys.map { ($0, Color(white: 0.15)) }), glyphColors: xboxFills)
        b.small(.buttonOptions, pt(-132, -36), r: 3, symbol: "rectangle.on.rectangle")
        b.small(.buttonMenu, pt(132, -36), r: 3, symbol: "line.3.horizontal")
        b.art.notes = [
            PadFixedNote(id: "l45", text: "L4 / L5 — set in Steam Input", anchor: pt(-124, 62.5)),
            PadFixedNote(id: "r45", text: "R4 / R5 — set in Steam Input", anchor: pt(124, 62.5)),
            PadFixedNote(id: "tpl", text: "Trackpad — Steam Input", anchor: pt(-121, 28)),
            PadFixedNote(id: "tpr", text: "Trackpad — Steam Input", anchor: pt(121, 28))]
        return b.art
    }
}
