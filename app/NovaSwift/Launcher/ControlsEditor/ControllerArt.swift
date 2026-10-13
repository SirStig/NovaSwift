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

    /// Letter on a face cap. South / east / west / north, with the swapped layout
    /// exchanged, so the picture matches the pad in hand. Callouts keep `name`.
    func faceLetter(_ b: PadButton) -> String {
        let swap = self == .switchPro
        switch b {
        case .buttonA: return swap ? "B" : "A"
        case .buttonB: return swap ? "A" : "B"
        case .buttonX: return swap ? "Y" : "X"
        case .buttonY: return swap ? "X" : "Y"
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
    /// Drawn outside the shell mask. Grip tabs sit past the outline.
    var spills = false
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
    /// Outer shell, the lip around the top case.
    var bodyTop = Color(white: 0.3)
    var bodyBottom = Color(white: 0.1)
    /// Lighter top case, inset from the outline.
    var caseTop = Color(white: 0.42)
    var caseBottom = Color(white: 0.22)
    var decor: [PadDecor] = []
    var controls: [PadControl] = []
    var notes: [PadFixedNote] = []

    /// Everything drawn (body, triggers, bumpers, back tabs), with a small margin.
    var bounds: CGRect {
        var r = body.boundingRect
        for c in controls { r = r.union(c.frame.insetBy(dx: -2, dy: -2)) }
        for d in decor { r = r.union(d.rect) }
        // Extra room under the outline for the chassis wall.
        r = r.insetBy(dx: -4, dy: -4)
        r.size.height += 4
        return r
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
                           bottom: Color = Color(white: 0.09), label: String? = nil, dashed: Bool = false,
                           spills: Bool = false) {
            art.decor.append(PadDecor(id: nextID, kind: kind, rect: rect, top: top, bottom: bottom,
                                      label: label, dashed: dashed, spills: spills))
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

        static let cap = Color(red: 0.20, green: 0.205, blue: 0.22)
        static let letter = Color(red: 0.94, green: 0.95, blue: 0.97)

        /// One cross plate, plus four arm hit-targets that only tint it.
        mutating func dpad(_ c: CGPoint, span: CGFloat) {
            deco(.roundRect(3.2), square(c, span * 1.08, span * 1.08), top: Color(white: 0.05), bottom: Color(white: 0.11))
            deco(.cross, square(c, span, span), top: Color(white: 0.34), bottom: Color(white: 0.16))
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

        /// Y top, A bottom, X left, B right. Caps are one neutral dome; the letter
        /// is the family's printing (swapped on Switch). No coloured jewels.
        mutating func face(_ style: PadStyle, _ c: CGPoint, offset: CGFloat, r: CGFloat) {
            let dish = (offset + r + 2.4) * 2
            let shade: Double = style == .playstation ? 0.14 : 0.22
            deco(.circle, square(c, dish, dish), top: Color.black.opacity(shade), bottom: Color.black.opacity(shade))
            let spots: [(PadButton, CGFloat, CGFloat)] = [(.buttonY, 0, -offset), (.buttonA, 0, offset),
                                                          (.buttonX, -offset, 0), (.buttonB, offset, 0)]
            for (b, dx, dy) in spots {
                art.controls.append(PadControl(button: b, kind: .round, center: CGPoint(x: c.x + dx, y: c.y + dy),
                                               size: CGSize(width: r * 2, height: r * 2), glyph: style.faceLetter(b),
                                               fill: Self.cap, glyphColor: Self.letter))
            }
        }

        /// Bumpers overlap the top edge; triggers sit just behind them. `top` is the
        /// body's top y. The outer end of each capsule lifts, matching the horn.
        mutating func shoulders(_ style: PadStyle, bump: (CGFloat, CGFloat), trig: (CGFloat, CGFloat), top: CGFloat) {
            let light = style == .playstation
            let tilt: Double = style == .steamDeck ? 2 : 6
            let bumpFill = light ? Color(red: 0.97, green: 0.97, blue: 0.98) : Color(red: 0.46, green: 0.47, blue: 0.51)
            let trigFill = light ? Color(red: 0.78, green: 0.80, blue: 0.84) : Color(red: 0.24, green: 0.245, blue: 0.27)
            let ink = light ? Color(red: 0.16, green: 0.17, blue: 0.19) : Color(red: 0.94, green: 0.95, blue: 0.97)
            let bumperX = (bump.0 + bump.1) / 2
            let triggerX = (trig.0 + trig.1) / 2
            for sign: CGFloat in [-1, 1] {
                let left = sign < 0
                art.controls.append(PadControl(
                    button: left ? .leftTrigger : .rightTrigger, kind: .trigger,
                    center: CGPoint(x: sign * triggerX, y: top - 6.2),
                    size: CGSize(width: trig.1 - trig.0, height: 12),
                    glyph: style.glyph(left ? .leftTrigger : .rightTrigger),
                    fill: trigFill, glyphColor: ink, rotation: -Double(sign) * tilt * 1.2))
                art.controls.append(PadControl(
                    button: left ? .leftShoulder : .rightShoulder, kind: .bumper,
                    center: CGPoint(x: sign * bumperX, y: top + 0.4),
                    size: CGSize(width: bump.1 - bump.0, height: 8.2),
                    glyph: style.glyph(left ? .leftShoulder : .rightShoulder),
                    fill: bumpFill, glyphColor: ink, rotation: -Double(sign) * tilt))
            }
        }

        mutating func small(_ b: PadButton, _ c: CGPoint, r: CGFloat, symbol: String) {
            art.controls.append(PadControl(button: b, kind: .round, center: c, size: CGSize(width: r * 2, height: r * 2),
                                           symbol: symbol, fill: Self.cap, glyphColor: Self.letter))
        }

        mutating func pill(_ b: PadButton, _ c: CGPoint, w: CGFloat, h: CGFloat, symbol: String? = nil) {
            art.controls.append(PadControl(button: b, kind: .pill, center: c, size: CGSize(width: w, height: h),
                                           symbol: symbol, fill: Self.cap, glyphColor: Self.letter))
        }
    }

    static func make(_ style: PadStyle) -> PadArt {
        switch style {
        case .xbox: return xbox()
        case .playstation: return playstation()
        case .switchPro: return switchPro()
        case .steamDeck: return deck()
        }
    }

    private enum Shell { case light, graphite, deck }

    private static func paint(_ art: inout PadArt, _ shell: Shell) {
        switch shell {
        case .light:
            art.bodyTop = Color(red: 0.93, green: 0.94, blue: 0.96)
            art.bodyBottom = Color(red: 0.64, green: 0.66, blue: 0.70)
            art.caseTop = Color(red: 0.97, green: 0.97, blue: 0.98)
            art.caseBottom = Color(red: 0.78, green: 0.80, blue: 0.84)
        case .graphite:
            art.bodyTop = Color(red: 0.38, green: 0.39, blue: 0.42)
            art.bodyBottom = Color(red: 0.14, green: 0.145, blue: 0.16)
            art.caseTop = Color(red: 0.46, green: 0.47, blue: 0.51)
            art.caseBottom = Color(red: 0.24, green: 0.25, blue: 0.28)
        case .deck:
            art.bodyTop = Color(red: 0.32, green: 0.33, blue: 0.36)
            art.bodyBottom = Color(red: 0.11, green: 0.115, blue: 0.13)
            art.caseTop = Color(red: 0.40, green: 0.41, blue: 0.44)
            art.caseBottom = Color(red: 0.22, green: 0.225, blue: 0.25)
        }
    }

    // MARK: Xbox

    private static func xbox() -> PadArt {
        var b = Builder()
        b.art.body = symmetricBody(start: pt(0, -40), [
            (pt(62, -40), pt(22, -40.5), pt(46, -42)),
            (pt(77, -16), pt(70, -38), pt(78, -28)),
            (pt(70, 30), pt(78, -4), pt(75, 14)),
            (pt(48, 56), pt(66, 44), pt(58, 56)),
            (pt(34, 38), pt(42, 54), pt(38, 46)),
            (pt(14, 24), pt(30, 32), pt(24, 26)),
            (pt(0, 22), pt(8, 23), pt(3, 22.5))])
        paint(&b.art, .graphite)
        // Plain centre disc with a dark hole. Not a logo.
        b.deco(.circle, b.square(pt(0, -28), 10, 10), top: Color(red: 0.34, green: 0.345, blue: 0.37), bottom: Color(red: 0.16, green: 0.165, blue: 0.18))
        b.deco(.circle, b.square(pt(0, -28), 4.4, 4.4), top: Color(red: 0.08, green: 0.08, blue: 0.09), bottom: Color(red: 0.04, green: 0.04, blue: 0.05))
        b.shoulders(.xbox, bump: (28, 64), trig: (34, 60), top: -40)
        b.stick(.leftThumbstickButton, pt(-41, -14), r: 13, role: "Steer / Thrust")
        b.stick(.rightThumbstickButton, pt(19, 11), r: 13, role: "Aim")
        b.dpad(pt(-19, 11), span: 25)
        b.face(.xbox, pt(41, -14), offset: 10.5, r: 6)
        b.small(.buttonOptions, pt(-12.5, -14), r: 3.6, symbol: "rectangle.on.rectangle")
        b.small(.buttonMenu, pt(12.5, -14), r: 3.6, symbol: "line.3.horizontal")
        return b.art
    }

    // MARK: PlayStation

    private static func playstation() -> PadArt {
        var b = Builder()
        b.art.body = symmetricBody(start: pt(0, -38), [
            (pt(66, -38), pt(24, -38.5), pt(50, -40)),
            (pt(80, -14), pt(74, -36), pt(82, -26)),
            (pt(72, 34), pt(82, -2), pt(78, 16)),
            (pt(46, 58), pt(66, 48), pt(56, 60)),
            (pt(32, 42), pt(40, 56), pt(36, 48)),
            (pt(10, 35), pt(28, 38), pt(20, 36)),
            (pt(0, 34), pt(5, 34.5), pt(2, 34))])
        paint(&b.art, .light)
        b.shoulders(.playstation, bump: (26, 62), trig: (30, 58), top: -38)
        b.stick(.leftThumbstickButton, pt(-21, 17), r: 12, role: "Steer / Thrust")
        b.stick(.rightThumbstickButton, pt(21, 17), r: 12, role: "Aim")
        b.dpad(pt(-41, -8), span: 25)
        b.face(.playstation, pt(41, -8), offset: 10, r: 5.8)
        // After the face dish, so the pad stays on top of that circle.
        b.deco(.roundRect(5.5), CGRect(x: -24, y: -28, width: 48, height: 28),
               top: Color(red: 0.16, green: 0.17, blue: 0.19), bottom: Color(red: 0.08, green: 0.085, blue: 0.10))
        b.deco(.circle, b.square(pt(0, 10), 8.4, 8.4), top: Color(red: 0.28, green: 0.29, blue: 0.31), bottom: Color(red: 0.14, green: 0.145, blue: 0.16))
        b.small(.buttonOptions, pt(-31, -29), r: 3.6, symbol: "rectangle.on.rectangle")
        b.small(.buttonMenu, pt(31, -29), r: 3.6, symbol: "line.3.horizontal")
        return b.art
    }

    // MARK: Switch Pro

    private static func switchPro() -> PadArt {
        var b = Builder()
        b.art.body = symmetricBody(start: pt(0, -39), [
            (pt(58, -39), pt(20, -39.5), pt(42, -41)),
            (pt(74, -16), pt(66, -37), pt(74, -28)),
            (pt(66, 32), pt(75, -4), pt(72, 14)),
            (pt(44, 54), pt(60, 46), pt(52, 56)),
            (pt(30, 36), pt(38, 52), pt(34, 44)),
            (pt(12, 24), pt(26, 30), pt(20, 26)),
            (pt(0, 23), pt(6, 23.5), pt(2, 23))])
        paint(&b.art, .graphite)
        b.deco(.roundRect(1.6), b.square(pt(-13, -12), 7.5, 7.5),
               top: Color(red: 0.28, green: 0.285, blue: 0.31), bottom: Color(red: 0.14, green: 0.145, blue: 0.16))
        b.deco(.circle, b.square(pt(13, -12), 8.4, 8.4), top: Color(red: 0.34, green: 0.345, blue: 0.37), bottom: Color(red: 0.16, green: 0.165, blue: 0.18))
        b.shoulders(.switchPro, bump: (28, 62), trig: (32, 58), top: -39)
        b.stick(.leftThumbstickButton, pt(-41, -15), r: 13, role: "Steer / Thrust")
        b.stick(.rightThumbstickButton, pt(21, 12), r: 13, role: "Aim")
        b.dpad(pt(-21, 12), span: 24)
        b.face(.switchPro, pt(41, -15), offset: 10.5, r: 6)
        b.pill(.buttonOptions, pt(-13, -25), w: 8, h: 3.6, symbol: "minus")
        b.pill(.buttonMenu, pt(13, -25), w: 8, h: 3.6, symbol: "plus")
        return b.art
    }

    // MARK: Steam Deck

    private static func deck() -> PadArt {
        var b = Builder()
        b.art.body = symmetricBody(start: pt(0, -56), [
            (pt(116, -54), pt(36, -56.5), pt(88, -57)),
            (pt(148, -26), pt(128, -50), pt(144, -40)),
            (pt(144, 26), pt(150, -12), pt(148, 8)),
            (pt(118, 56), pt(140, 40), pt(132, 52)),
            (pt(94, 47), pt(110, 55), pt(102, 50)),
            (pt(14, 51), pt(64, 47), pt(32, 50)),
            (pt(0, 52), pt(6, 51.5), pt(2, 52))])
        paint(&b.art, .deck)
        b.deco(.roundRect(7), CGRect(x: -79, y: -54, width: 158, height: 100),
               top: Color(red: 0.02, green: 0.022, blue: 0.028), bottom: Color(red: 0.02, green: 0.022, blue: 0.028))
        b.deco(.roundRect(4.5), CGRect(x: -75, y: -50, width: 150, height: 92),
               top: Color(red: 0.08, green: 0.11, blue: 0.16), bottom: Color(red: 0.015, green: 0.02, blue: 0.035))
        let grip = Color(red: 0.16, green: 0.165, blue: 0.18)
        let gripLo = Color(red: 0.10, green: 0.105, blue: 0.12)
        for sign: CGFloat in [-1, 1] {
            let pad = pt(sign * 88, 36)
            b.deco(.circle, b.square(pad, 32.4, 32.4), top: Color.black.opacity(0.35), bottom: Color.black.opacity(0.35))
            b.deco(.circle, b.square(pad, 30, 30), top: Color(red: 0.07, green: 0.075, blue: 0.09), bottom: Color(red: 0.05, green: 0.052, blue: 0.06))
            b.deco(.roundRect(2), b.square(pt(sign * 151.5, -10), 5, 16), top: grip, bottom: gripLo, dashed: true, spills: true)
            b.deco(.roundRect(2), b.square(pt(sign * 151.5, 14), 5, 16), top: grip, bottom: gripLo, dashed: true, spills: true)
        }
        b.shoulders(.steamDeck, bump: (92, 134), trig: (98, 128), top: -56)
        b.stick(.leftThumbstickButton, pt(-112, -26), r: 12, role: "Steer / Thrust")
        b.stick(.rightThumbstickButton, pt(112, 6), r: 12, role: "Aim")
        b.dpad(pt(-112, 8), span: 22)
        b.face(.steamDeck, pt(112, -26), offset: 9.5, r: 5.5)
        b.small(.buttonOptions, pt(-89, -14), r: 3.6, symbol: "rectangle.on.rectangle")
        b.small(.buttonMenu, pt(89, -14), r: 3.6, symbol: "line.3.horizontal")
        b.art.notes = [
            PadFixedNote(id: "l45", text: "L4 / L5 — set in Steam Input", anchor: pt(-151.5, 2)),
            PadFixedNote(id: "r45", text: "R4 / R5 — set in Steam Input", anchor: pt(151.5, 2)),
            PadFixedNote(id: "tpl", text: "Trackpad — Steam Input", anchor: pt(-103, 36)),
            PadFixedNote(id: "tpr", text: "Trackpad — Steam Input", anchor: pt(103, 36))]
        return b.art
    }
}
