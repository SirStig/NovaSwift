import SwiftUI
import GameController

/// The controller silhouettes the editor can draw. All art is procedural vector
/// paths in a fixed 1000×640 space (no bitmaps, no vendor marks): each style
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

struct PadControl: Identifiable {
    enum DpadDir { case up, down, left, right }
    enum Kind { case round, trigger, bumper, stick, dpadArm(DpadDir) }

    let button: PadButton
    let kind: Kind
    let center: CGPoint
    let size: CGSize
    var glyph = ""
    var symbol: String?
    /// Face colour; nil = neutral grey plastic.
    var fill: Color?
    var glyphColor: Color = .white
    var behindBody = false
    var fixedRole: String?

    var id: String { button.rawValue }
    var side: PadSide { center.x < 500 ? .left : .right }
    /// Triggers and bumpers on the right are the left ones mirrored.
    var mirrored: Bool { center.x >= 500 }
    var frame: CGRect { CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height) }
}

struct PadDecor: Identifiable {
    enum Kind { case circle, roundRect(CGFloat) }
    let id: Int
    let kind: Kind
    let rect: CGRect
    var top: Color = Color(white: 0.2)
    var bottom: Color = Color(white: 0.1)
    var label: String?
    var dashed = false
}

/// A greyed callout for something the editor shows but can't bind (back grips,
/// trackpads — those are Steam Input's).
struct PadFixedNote: Identifiable {
    let id = UUID()
    let text: String
    let anchor: CGPoint
    var side: PadSide { anchor.x < 500 ? .left : .right }
}

struct PadArt {
    static let canvas = CGSize(width: 1000, height: 640)

    var body: Path
    var bodyTop: Color
    var bodyBottom: Color
    var decor: [PadDecor] = []
    var controls: [PadControl] = []
    var notes: [PadFixedNote] = []

    // MARK: Parametric gamepad silhouette

    /// A symmetric gamepad outline: arched top, rounded shoulders, grips that
    /// swing outward and end in rounded feet, with a shallow cut between them.
    private struct Grip {
        var topHalf: CGFloat = 295, topY: CGFloat = 172, archY: CGFloat = 118
        var outerHalf: CGFloat = 435, outerY: CGFloat = 330
        var footY: CGFloat = 575, footOuter: CGFloat = 365, footInner: CGFloat = 268
        var cutY: CGFloat = 458, cutHalf: CGFloat = 190

        func path() -> Path {
            func P(_ dx: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 500 + dx, y: y) }
            let drop = footY - outerY
            var p = Path()
            p.move(to: P(-topHalf, topY))
            p.addCurve(to: P(topHalf, topY), control1: P(-topHalf * 0.45, archY), control2: P(topHalf * 0.45, archY))
            p.addCurve(to: P(outerHalf, outerY), control1: P(outerHalf * 0.92, topY - 6),
                       control2: P(outerHalf, topY + (outerY - topY) * 0.4))
            p.addCurve(to: P(footOuter, footY - 18), control1: P(outerHalf + 6, outerY + drop * 0.4),
                       control2: P(footOuter + 38, footY - 70))
            p.addCurve(to: P(footInner, footY - 14), control1: P(footOuter - 8, footY + 24),
                       control2: P(footInner + 8, footY + 24))
            p.addCurve(to: P(cutHalf, cutY), control1: P(footInner - 28, footY - 75),
                       control2: P(cutHalf + 48, cutY + 34))
            p.addCurve(to: P(-cutHalf, cutY), control1: P(cutHalf * 0.5, cutY - 16),
                       control2: P(-cutHalf * 0.5, cutY - 16))
            p.addCurve(to: P(-footInner, footY - 14), control1: P(-cutHalf - 48, cutY + 34),
                       control2: P(-footInner + 28, footY - 75))
            p.addCurve(to: P(-footOuter, footY - 18), control1: P(-footInner - 8, footY + 24),
                       control2: P(-footOuter + 8, footY + 24))
            p.addCurve(to: P(-outerHalf, outerY), control1: P(-footOuter - 38, footY - 70),
                       control2: P(-outerHalf - 6, outerY + drop * 0.4))
            p.addCurve(to: P(-topHalf, topY), control1: P(-outerHalf, topY + (outerY - topY) * 0.4),
                       control2: P(-outerHalf * 0.92, topY - 6))
            p.closeSubpath()
            return p
        }
    }

    // MARK: Building blocks

    private static func dpad(at c: CGPoint) -> [PadControl] {
        let off: CGFloat = 40
        func arm(_ b: PadButton, _ d: PadControl.DpadDir, _ dx: CGFloat, _ dy: CGFloat) -> PadControl {
            let size = dx == 0 ? CGSize(width: 44, height: 52) : CGSize(width: 52, height: 44)
            return PadControl(button: b, kind: .dpadArm(d), center: CGPoint(x: c.x + dx, y: c.y + dy), size: size)
        }
        return [arm(.dpadUp, .up, 0, -off), arm(.dpadDown, .down, 0, off),
                arm(.dpadLeft, .left, -off, 0), arm(.dpadRight, .right, off, 0)]
    }

    private static func face(at c: CGPoint, offset: CGFloat, radius r: CGFloat, style: PadStyle,
                             fills: [PadButton: Color], glyphColors: [PadButton: Color]) -> [PadControl] {
        let spots: [(PadButton, CGFloat, CGFloat)] = [(.buttonY, 0, -offset), (.buttonA, 0, offset),
                                                      (.buttonX, -offset, 0), (.buttonB, offset, 0)]
        return spots.map { b, dx, dy in
            PadControl(button: b, kind: .round, center: CGPoint(x: c.x + dx, y: c.y + dy),
                       size: CGSize(width: r * 2, height: r * 2), glyph: style.glyph(b),
                       fill: fills[b], glyphColor: glyphColors[b] ?? .white)
        }
    }

    private static func stick(_ b: PadButton, at c: CGPoint, role: String) -> PadControl {
        PadControl(button: b, kind: .stick, center: c, size: CGSize(width: 96, height: 96), fixedRole: role)
    }

    /// Shoulders and triggers for the left side and (mirrored) the right, laid
    /// out for a body whose top corners sit near x=205/795.
    private static func shoulders(style: PadStyle, bumperY: CGFloat = 150, triggerY: CGFloat = 92,
                                  inset: CGFloat = 245) -> [PadControl] {
        func make(_ l: PadButton, _ t: PadButton, x: CGFloat) -> [PadControl] {
            [PadControl(button: t, kind: .trigger, center: CGPoint(x: x, y: triggerY),
                        size: CGSize(width: 138, height: 84), glyph: style.glyph(t), behindBody: true),
             PadControl(button: l, kind: .bumper, center: CGPoint(x: x - 4 * (x < 500 ? 1 : -1), y: bumperY),
                        size: CGSize(width: 200, height: 44), glyph: style.glyph(l))]
        }
        return make(.leftShoulder, .leftTrigger, x: inset) + make(.rightShoulder, .rightTrigger, x: 1000 - inset)
    }

    private static func smallButtons(_ style: PadStyle, left: CGPoint, right: CGPoint, r: CGFloat = 17) -> [PadControl] {
        let (viewSym, menuSym): (String, String) = {
            switch style {
            case .switchPro: return ("minus", "plus")
            case .playstation: return ("square.and.arrow.up", "line.3.horizontal")
            default: return ("rectangle.on.rectangle", "line.3.horizontal")
            }
        }()
        return [PadControl(button: .buttonOptions, kind: .round, center: left, size: CGSize(width: r * 2, height: r * 2), symbol: viewSym),
                PadControl(button: .buttonMenu, kind: .round, center: right, size: CGSize(width: r * 2, height: r * 2), symbol: menuSym)]
    }

    // MARK: Styles

    static func make(_ style: PadStyle) -> PadArt {
        switch style {
        case .xbox: return xboxLike(.xbox)
        case .switchPro: return xboxLike(.switchPro)
        case .playstation: return playstation()
        case .steamDeck: return deck()
        }
    }

    private static let xboxFills: [PadButton: Color] = [
        .buttonA: Color(red: 0.36, green: 0.76, blue: 0.36), .buttonB: Color(red: 0.86, green: 0.27, blue: 0.27),
        .buttonX: Color(red: 0.27, green: 0.52, blue: 0.92), .buttonY: Color(red: 0.96, green: 0.80, blue: 0.22)]

    /// Offset-stick layout shared by the Xbox pad and the Switch Pro pad.
    private static func xboxLike(_ style: PadStyle) -> PadArt {
        let pro = style == .switchPro
        var grip = Grip()
        if pro { grip.footY = 590; grip.footOuter = 352; grip.footInner = 262; grip.outerHalf = 428 }
        var art = PadArt(body: grip.path(),
                         bodyTop: pro ? Color(white: 0.30) : Color(white: 0.27),
                         bodyBottom: pro ? Color(white: 0.13) : Color(white: 0.10))
        var id = 0
        func deco(_ kind: PadDecor.Kind, _ rect: CGRect, label: String? = nil,
                  top: Color = Color(white: 0.2), bottom: Color = Color(white: 0.09)) {
            art.decor.append(PadDecor(id: id, kind: kind, rect: rect, top: top, bottom: bottom, label: label)); id += 1
        }
        let ls = CGPoint(x: 272, y: 262), rs = CGPoint(x: 612, y: 398)
        let dp = CGPoint(x: 388, y: 398), fc = CGPoint(x: 728, y: 262)
        // Stick wells and the d-pad hub sit in the plastic.
        deco(.circle, CGRect(x: ls.x - 64, y: ls.y - 64, width: 128, height: 128), top: Color(white: 0.05), bottom: Color(white: 0.16))
        deco(.circle, CGRect(x: rs.x - 64, y: rs.y - 64, width: 128, height: 128), top: Color(white: 0.05), bottom: Color(white: 0.16))
        deco(.circle, CGRect(x: dp.x - 78, y: dp.y - 78, width: 156, height: 156), top: Color(white: 0.06), bottom: Color(white: 0.15))
        deco(.circle, CGRect(x: dp.x - 26, y: dp.y - 26, width: 52, height: 52), top: Color(white: 0.3), bottom: Color(white: 0.2))
        if pro {
            deco(.roundRect(5), CGRect(x: 424, y: 296, width: 30, height: 30), top: Color(white: 0.22), bottom: Color(white: 0.12))   // capture
            deco(.circle, CGRect(x: 546, y: 294, width: 34, height: 34), top: Color(white: 0.24), bottom: Color(white: 0.12))        // home
        } else {
            deco(.circle, CGRect(x: 468, y: 176, width: 64, height: 64), top: Color(white: 0.36), bottom: Color(white: 0.14))      // guide
            deco(.circle, CGRect(x: 478, y: 186, width: 44, height: 44), top: Color(white: 0.2), bottom: Color(white: 0.3))
        }
        art.controls = shoulders(style: style)
            + [stick(.leftThumbstickButton, at: ls, role: "Steer / Thrust"), stick(.rightThumbstickButton, at: rs, role: "Aim")]
            + dpad(at: dp)
            + face(at: fc, offset: 53, radius: 28, style: style,
                   fills: pro ? [:] : xboxFills,
                   glyphColors: pro ? [:] : [.buttonA: .black, .buttonB: .black, .buttonX: .black, .buttonY: .black])
            + smallButtons(style, left: pro ? CGPoint(x: 432, y: 232) : CGPoint(x: 442, y: 262),
                           right: pro ? CGPoint(x: 568, y: 232) : CGPoint(x: 558, y: 262))
        if pro {   // neutral caps with dark letters
            art.controls = art.controls.map { c in
                var c = c
                if case .round = c.kind, !c.glyph.isEmpty { c.fill = Color(white: 0.82); c.glyphColor = .black }
                return c
            }
        }
        return art
    }

    private static func playstation() -> PadArt {
        var grip = Grip()
        grip.topY = 176; grip.archY = 128; grip.outerHalf = 420; grip.footY = 592; grip.footOuter = 340
        grip.footInner = 252; grip.cutY = 470; grip.cutHalf = 160
        var art = PadArt(body: grip.path(), bodyTop: Color(white: 0.92), bodyBottom: Color(white: 0.62))
        var id = 0
        func deco(_ kind: PadDecor.Kind, _ rect: CGRect, label: String? = nil,
                  top: Color, bottom: Color) {
            art.decor.append(PadDecor(id: id, kind: kind, rect: rect, top: top, bottom: bottom, label: label)); id += 1
        }
        let ls = CGPoint(x: 386, y: 424), rs = CGPoint(x: 614, y: 424)
        let dp = CGPoint(x: 262, y: 282), fc = CGPoint(x: 738, y: 282)
        let dark = (Color(white: 0.20), Color(white: 0.08))
        // Dark centre panel with the touchpad, then wells.
        deco(.roundRect(60), CGRect(x: 330, y: 168, width: 340, height: 300), top: dark.0, bottom: dark.1)
        deco(.roundRect(20), CGRect(x: 360, y: 190, width: 280, height: 140), top: Color(white: 0.34), bottom: Color(white: 0.2), label: "touchpad")
        deco(.circle, CGRect(x: ls.x - 64, y: ls.y - 64, width: 128, height: 128), top: Color(white: 0.04), bottom: Color(white: 0.15))
        deco(.circle, CGRect(x: rs.x - 64, y: rs.y - 64, width: 128, height: 128), top: Color(white: 0.04), bottom: Color(white: 0.15))
        deco(.circle, CGRect(x: dp.x - 80, y: dp.y - 80, width: 160, height: 160), top: dark.0, bottom: dark.1)
        deco(.circle, CGRect(x: fc.x - 92, y: fc.y - 92, width: 184, height: 184), top: dark.0, bottom: dark.1)
        deco(.circle, CGRect(x: dp.x - 26, y: dp.y - 26, width: 52, height: 52), top: Color(white: 0.4), bottom: Color(white: 0.24))
        deco(.circle, CGRect(x: 484, y: 358, width: 32, height: 32), top: Color(white: 0.42), bottom: Color(white: 0.2))   // system button
        let tints: [PadButton: Color] = [.buttonA: Color(red: 0.45, green: 0.62, blue: 1), .buttonB: Color(red: 1, green: 0.42, blue: 0.42),
                                         .buttonX: Color(red: 0.96, green: 0.52, blue: 0.82), .buttonY: Color(red: 0.36, green: 0.86, blue: 0.62)]
        art.controls = shoulders(style: .playstation, bumperY: 154, triggerY: 96, inset: 250)
            + [stick(.leftThumbstickButton, at: ls, role: "Steer / Thrust"), stick(.rightThumbstickButton, at: rs, role: "Aim")]
            + dpad(at: dp)
            + face(at: fc, offset: 52, radius: 28, style: .playstation,
                   fills: Dictionary(uniqueKeysWithValues: tints.keys.map { ($0, Color(white: 0.16)) }), glyphColors: tints)
            + smallButtons(.playstation, left: CGPoint(x: 336, y: 232), right: CGPoint(x: 664, y: 232), r: 15)
        return art
    }

    private static func deck() -> PadArt {
        let body = RoundedRectangle(cornerRadius: 160, style: .continuous)
            .path(in: CGRect(x: 40, y: 112, width: 920, height: 480))
        var art = PadArt(body: body, bodyTop: Color(white: 0.24), bodyBottom: Color(white: 0.09))
        var id = 0
        func deco(_ kind: PadDecor.Kind, _ rect: CGRect, label: String? = nil, top: Color, bottom: Color, dashed: Bool = false) {
            art.decor.append(PadDecor(id: id, kind: kind, rect: rect, top: top, bottom: bottom, label: label, dashed: dashed)); id += 1
        }
        let ls = CGPoint(x: 150, y: 250), rs = CGPoint(x: 850, y: 400)
        let dp = CGPoint(x: 150, y: 400), fc = CGPoint(x: 850, y: 250)
        // Screen.
        deco(.roundRect(16), CGRect(x: 300, y: 150, width: 400, height: 280), top: Color(white: 0.02), bottom: Color(white: 0.09))
        deco(.roundRect(8), CGRect(x: 312, y: 162, width: 376, height: 256), top: Color(red: 0.08, green: 0.14, blue: 0.24), bottom: Color(red: 0.03, green: 0.05, blue: 0.10))
        deco(.circle, CGRect(x: ls.x - 64, y: ls.y - 64, width: 128, height: 128), top: Color(white: 0.04), bottom: Color(white: 0.15))
        deco(.circle, CGRect(x: rs.x - 64, y: rs.y - 64, width: 128, height: 128), top: Color(white: 0.04), bottom: Color(white: 0.15))
        deco(.circle, CGRect(x: dp.x - 78, y: dp.y - 78, width: 156, height: 156), top: Color(white: 0.05), bottom: Color(white: 0.14))
        deco(.circle, CGRect(x: dp.x - 26, y: dp.y - 26, width: 52, height: 52), top: Color(white: 0.3), bottom: Color(white: 0.2))
        // Trackpads: greyed — Steam Input's, not bindable here.
        deco(.circle, CGRect(x: 205, y: 450, width: 130, height: 130), top: Color(white: 0.16), bottom: Color(white: 0.08), label: "pad", dashed: true)
        deco(.circle, CGRect(x: 665, y: 450, width: 130, height: 130).offsetBy(dx: 0, dy: 0), top: Color(white: 0.16), bottom: Color(white: 0.08), label: "pad", dashed: true)
        // Back grips L4/L5, R4/R5 (rear — drawn at the lower rim).
        deco(.roundRect(14), CGRect(x: 78, y: 520, width: 70, height: 28), top: Color(white: 0.2), bottom: Color(white: 0.12), label: "L4 L5", dashed: true)
        deco(.roundRect(14), CGRect(x: 852, y: 520, width: 70, height: 28), top: Color(white: 0.2), bottom: Color(white: 0.12), label: "R4 R5", dashed: true)
        let fills: [PadButton: Color] = Dictionary(uniqueKeysWithValues: xboxFills.keys.map { ($0, Color(white: 0.15)) })
        art.controls = shoulders(style: .steamDeck, bumperY: 124, triggerY: 70, inset: 170)
            + [stick(.leftThumbstickButton, at: ls, role: "Steer / Thrust"), stick(.rightThumbstickButton, at: rs, role: "Aim")]
            + dpad(at: dp)
            + face(at: fc, offset: 52, radius: 28, style: .steamDeck, fills: fills, glyphColors: xboxFills)
            + smallButtons(.steamDeck, left: CGPoint(x: 252, y: 268), right: CGPoint(x: 748, y: 268), r: 17)
        art.notes = [PadFixedNote(text: "L4 / L5 — set in Steam Input", anchor: CGPoint(x: 100, y: 534)),
                     PadFixedNote(text: "R4 / R5 — set in Steam Input", anchor: CGPoint(x: 900, y: 534)),
                     PadFixedNote(text: "Trackpad — Steam Input", anchor: CGPoint(x: 270, y: 515)),
                     PadFixedNote(text: "Trackpad — Steam Input", anchor: CGPoint(x: 730, y: 515))]
        return art
    }
}
