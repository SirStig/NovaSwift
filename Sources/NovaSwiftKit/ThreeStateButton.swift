import Foundation

/// Geometry of the original's three-state button (`NovaUi_InitThreeStateButtonArt`
/// 0x004a2f50 + `NovaUi_DrawThreeStateButton` 0x004a3340), kept free of any UI
/// framework so the rules can be pinned by tests.
///
/// - Art: PICT 7500+3s (left cap), 7501+3s (middle), 7502+3s (right cap) for
///   state s = 0 normal, 1 pressed, 2 grey; masks are PICT 7600+3s… A missing
///   art PICT leaves a 12×24 slot that was painted black, so it draws as an
///   opaque black block; a missing mask PICT leaves its slot painted black,
///   which is a fully opaque mask.
/// - Draw: each cap keeps its own PICT width and is stretched to the button
///   height; the left cap sits at x 0 and the right cap ends at the button's
///   right edge. Both caps are drawn through their masks. The middle slice is
///   copied **without a mask** into the span between the caps with a plain
///   (scaling) CopyBits — it is stretched, not tiled.
/// - Visibility: `param4` 0 draws normal/pressed, −1 grey, −3 a caller PICT;
///   any other value draws only the restored background (the button is hidden).
public enum ThreeStateButton {
    /// Slot size the original reserves when a button PICT is missing.
    public static let missingSlotWidth = 12
    public static let missingSlotHeight = 24

    public enum State: Int { case normal = 0, pressed = 1, grey = 2 }

    /// `param4` handling: what the original draws for a given state argument.
    public enum Visibility: Equatable { case art, customPict, hidden }
    public static func visibility(param4: Int) -> Visibility {
        switch param4 {
        case 0, -1: return .art
        case -3:    return .customPict
        default:    return .hidden
        }
    }

    public static func artID(state: State, slice: Int) -> Int { 7500 + 3 * state.rawValue + slice }
    public static func maskID(state: State, slice: Int) -> Int { 7600 + 3 * state.rawValue + slice }

    /// Horizontal layout of the three slices inside a button `width` wide.
    public struct Layout: Equatable {
        public var leftCapWidth: Int
        public var rightCapX: Int                    // x of the right cap
        public var rightCapWidth: Int
        public var middleX: Int                      // middle span start
        public var middleWidth: Int                  // may be 0 (caps meet or overlap)
    }

    public static func layout(width: Int, leftCapWidth: Int?, rightCapWidth: Int?) -> Layout {
        let lw = leftCapWidth ?? missingSlotWidth
        let rw = rightCapWidth ?? missingSlotWidth
        let rx = width - rw
        return Layout(leftCapWidth: lw, rightCapX: rx, rightCapWidth: rw,
                      middleX: lw, middleWidth: max(0, rx - lw))
    }

    /// A pen stroke in button-local QuickDraw coordinates (y down), drawn with
    /// a 2×2 pen.
    public struct Segment: Equatable {
        public var fromX: Int, fromY: Int, toX: Int, toY: Int
        public init(_ fx: Int, _ fy: Int, _ tx: Int, _ ty: Int) {
            fromX = fx; fromY = fy; toX = tx; toY = ty
        }
    }

    /// The vector glyph the original draws instead of text when a button's
    /// label is exactly one of `^ & + -` (up arrow, down arrow, plus, minus).
    /// Sizes follow the button height: h/10 for the arrows, h/8 for plus, h/9
    /// for minus; the centre is `(left+right)/2, (top+bottom)/2`.
    public static func glyph(_ label: String, width: Int, height: Int) -> [Segment]? {
        guard label.count == 1, let c = label.first else { return nil }
        let cx = width / 2, cy = height / 2
        switch c {
        case "^":
            let s = height / 10
            return [Segment(cx, cy - s, cx - 2 * s, cy + s), Segment(cx, cy - s, cx + 2 * s, cy + s)]
        case "&":
            let s = height / 10
            return [Segment(cx, cy + s, cx - 2 * s, cy - s), Segment(cx, cy + s, cx + 2 * s, cy - s)]
        case "+":
            let s = height / 8
            return [Segment(cx - s, cy, cx + s, cy), Segment(cx, cy - s, cx, cy + s)]
        case "-":
            let s = height / 9
            return [Segment(cx - s, cy, cx + s, cy)]
        default:
            return nil
        }
    }

    /// Text label placement: left x = centre − width/2, baseline = vertical
    /// centre + 5.
    public static func labelOrigin(buttonWidth: Int, buttonHeight: Int, textWidth: Int) -> (x: Int, baseline: Int) {
        (buttonWidth / 2 - textWidth / 2, buttonHeight / 2 + 5)
    }

    /// Whether a pixel of a mask PICT lets the art through. Mask PICTs are
    /// drawn into a 1-bit canvas and used as a QuickDraw mask: black (dark)
    /// pixels are copied, white ones are not. The stock 7600 is a black pill on
    /// white.
    public static func maskOpaque(r: UInt8, g: UInt8, b: UInt8) -> Bool {
        (Int(r) + Int(g) + Int(b)) / 3 < 128
    }
}
