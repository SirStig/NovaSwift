import Foundation

/// Framework-free geometry for the authentic ("Classic") EV Nova UI, pulled out
/// of the SwiftUI-only code (`ClassicDITLDialog`, `ThreeStateButtonArt`,
/// `AuthenticHUDView`, `novaFrameScale`) so a second frontend (the Godot layer)
/// shares the same rules. The Apple app still carries its own copies; they can
/// be rewired to these later.
///
/// Everything here is pure arithmetic on ints / byte arrays — no CoreGraphics,
/// SwiftUI or Godot types — so it also builds on Linux / Windows.
public enum ClassicUIGeometry {

    // MARK: Dialog scaling

    /// The screen the original's dialogs were laid out against — the Apple
    /// app's `novaReferenceScreen`.
    public static let referenceScreen = (width: 1024.0, height: 768.0)

    /// The scale a 1:1 pixel layout of `frame` should be drawn at inside
    /// `viewport` (both in points). The Apple `novaFrameScale` rule — a dialog
    /// grows only as far as the *viewport* outgrows the original 1024×768
    /// screen (never below 1×, capped at `maxScale`), and never past fitting
    /// the frame — so a small dialog stays its true relative size instead of
    /// being blown up to fill the window. Snapped **down** to `step` (0.5) so
    /// nearest-neighbour art keeps even pixel sizes; a frame larger than the
    /// viewport shrinks to fit, unsnapped.
    public static func crispScale(frameWidth: Int, frameHeight: Int,
                                  viewportWidth: Double, viewportHeight: Double,
                                  maxScale: Double = 2.6, step: Double = 0.5) -> Double {
        guard frameWidth > 0, frameHeight > 0, viewportWidth > 0, viewportHeight > 0 else { return 1 }
        let frameFit = min(viewportWidth / Double(frameWidth), viewportHeight / Double(frameHeight))
        let screenFit = min(viewportWidth / referenceScreen.width, viewportHeight / referenceScreen.height)
        let scale = min(frameFit, maxScale, max(screenFit, 1))
        guard scale >= 1 else { return scale }
        return max(1, (scale / step).rounded(.down) * step)
    }

    /// Top-left of a `w`×`h` frame centred in a `screen`, integer halves (the
    /// original's `UiWindow_CreateFromDialogResource` centring).
    public static func centredOrigin(width w: Int, height h: Int,
                                     screenWidth: Int, screenHeight: Int) -> (x: Int, y: Int) {
        ((screenWidth - w) / 2, (screenHeight - h) / 2)
    }

    // MARK: Status bars (ïntf)

    /// A pixel rectangle (left, top, width, height) in the status bar's
    /// coordinate space.
    public struct PixelRect: Equatable {
        public var x: Int, y: Int, w: Int, h: Int
        public init(x: Int, y: Int, w: Int, h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }
    }

    /// The part of a bar rect between fractions `a` and `b` (0…1) of its
    /// length. The original fills a wide rect from the left and a tall one
    /// (height ≥ width) from the bottom, in whole pixels (0x0045ea66 /
    /// 0x0045ebe8). `rect` is `(left, top, width, height)`.
    public static func barSegment(left: Int, top: Int, width: Int, height: Int,
                                  from a: Double, to b: Double) -> PixelRect {
        let tall = height >= width
        let len = Double(tall ? height : width)
        let start = (len * a).rounded(.down), end = (len * b).rounded(.down)
        let size = Int(max(0, end - start))
        return tall
            ? PixelRect(x: left, y: top + height - Int(end), w: width, h: size)
            : PixelRect(x: left + Int(start), y: top, w: size, h: height)
    }

    /// The fuel gauge's two fills: whole-jump fraction (`fuelFull` colour) and
    /// the sub-jump remainder (`fuelPartial`), both as 0…1 fractions of the
    /// bar (`full` is `0…full`, `partial` is `full…full+partial`).
    public static func fuelSplit(fuelFraction: Double, jumps: Int, maxFuelUnits: Double)
        -> (full: Double, partial: Double) {
        let frac = min(1, max(0, fuelFraction))
        let full = maxFuelUnits > 0 ? min(frac, Double(jumps) * 100 / maxFuelUnits) : frac
        return (full, max(0, frac - full))
    }

    // MARK: Focus navigation

    /// One focusable rect (DITL pixel coordinates).
    public struct FocusRect: Equatable {
        public var left: Int, top: Int, right: Int, bottom: Int
        public init(left: Int, top: Int, right: Int, bottom: Int) {
            self.left = left; self.top = top; self.right = right; self.bottom = bottom
        }
        var cx: Double { Double(left + right) / 2 }
        var cy: Double { Double(top + bottom) / 2 }
    }

    /// Per-item neighbour indices `[up, down, left, right]`, -1 when there is
    /// none, derived from geometry: in each direction the nearest rect whose
    /// centre lies in that half-plane, scored by primary-axis distance plus
    /// twice the off-axis distance (so a button straight below beats one far
    /// to the side). Used so gamepad / keyboard focus follows what is drawn.
    public static func focusNeighbours(_ rects: [FocusRect]) -> [[Int]] {
        rects.indices.map { i in
            let r = rects[i]
            var best: [Int] = [-1, -1, -1, -1]
            var score: [Double] = [.infinity, .infinity, .infinity, .infinity]
            for j in rects.indices where j != i {
                let o = rects[j]
                let dx = o.cx - r.cx, dy = o.cy - r.cy
                // up, down, left, right: (primary distance, off-axis distance)
                let cands: [(Double, Double)] = [(-dy, abs(dx)), (dy, abs(dx)), (-dx, abs(dy)), (dx, abs(dy))]
                for d in 0..<4 {
                    let (primary, off) = cands[d]
                    guard primary > 0.5, off <= primary * 2 + 1 else { continue }   // ±~63° cone
                    let s = primary + 2 * off
                    if s < score[d] { score[d] = s; best[d] = j }
                }
            }
            return best
        }
    }
}

/// The composed three-state push button as RGBA bytes — the same compositing
/// `SpaceportGraphics.buttonSlices` + `ThreeStateButtonArt` do with CGImages,
/// done on plain byte arrays so the Godot bridge can hand back a finished
/// button for a given width / state.
public enum ThreeStateButtonRaster {
    /// A tightly packed RGBA8 image, row-major, top-left origin.
    public struct Image: Equatable {
        public var width: Int, height: Int
        public var rgba: [UInt8]
        public init(width: Int, height: Int, rgba: [UInt8]) {
            self.width = width; self.height = height; self.rgba = rgba
        }
        /// The opaque black slot the original leaves for a missing button PICT.
        public static var missingSlot: Image {
            let w = ThreeStateButton.missingSlotWidth, h = ThreeStateButton.missingSlotHeight
            var px = [UInt8](repeating: 0, count: w * h * 4)
            for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
            return Image(width: w, height: h, rgba: px)
        }
    }

    /// Clears `art`'s pixels wherever `mask` (nearest-sampled into the art's
    /// size, as `nv_DrawPict` scales it) is not opaque (`maskOpaque`).
    public static func applyMask(_ mask: Image, to art: Image) -> Image {
        var out = art
        guard art.width > 0, art.height > 0, mask.width > 0, mask.height > 0 else { return out }
        for y in 0..<art.height {
            let my = min(mask.height - 1, y * mask.height / art.height)
            for x in 0..<art.width {
                let mx = min(mask.width - 1, x * mask.width / art.width)
                let m = (my * mask.width + mx) * 4
                if !ThreeStateButton.maskOpaque(r: mask.rgba[m], g: mask.rgba[m + 1], b: mask.rgba[m + 2]) {
                    let p = (y * art.width + x) * 4
                    out.rgba[p] = 0; out.rgba[p + 1] = 0; out.rgba[p + 2] = 0; out.rgba[p + 3] = 0
                }
            }
        }
        return out
    }

    /// Composes a `width`×`height` button: middle stretched (unmasked) between
    /// the caps, caps at their own widths stretched to the button height,
    /// right cap flush right (`NovaUi_DrawThreeStateButton`). Nearest sampling.
    /// `left`/`right` should already be masked (`applyMask`).
    public static func compose(width: Int, height: Int,
                               left: Image?, middle: Image?, right: Image?) -> Image {
        let w = max(1, width), h = max(1, height)
        var out = Image(width: w, height: h, rgba: [UInt8](repeating: 0, count: w * h * 4))
        let lay = ThreeStateButton.layout(width: w, leftCapWidth: left?.width, rightCapWidth: right?.width)
        let mid = middle ?? .missingSlot, l = left ?? .missingSlot, r = right ?? .missingSlot
        blit(mid, into: &out, x: lay.middleX, width: lay.middleWidth, overwrite: true)
        blit(l, into: &out, x: 0, width: lay.leftCapWidth, overwrite: false)
        blit(r, into: &out, x: lay.rightCapX, width: lay.rightCapWidth, overwrite: false)
        return out
    }

    /// Stretches `src` into `dst` at column `x`, `width` wide, full height.
    /// `overwrite` copies every pixel; otherwise fully transparent source
    /// pixels leave the destination alone (a masked cap).
    private static func blit(_ src: Image, into dst: inout Image, x: Int, width: Int, overwrite: Bool) {
        guard width > 0, src.width > 0, src.height > 0 else { return }
        for dy in 0..<dst.height {
            let sy = min(src.height - 1, dy * src.height / dst.height)
            for ox in 0..<width {
                let dx = x + ox
                guard dx >= 0, dx < dst.width else { continue }
                let sx = min(src.width - 1, ox * src.width / width)
                let s = (sy * src.width + sx) * 4
                if !overwrite && src.rgba[s + 3] == 0 { continue }
                let d = (dy * dst.width + dx) * 4
                dst.rgba[d] = src.rgba[s]; dst.rgba[d + 1] = src.rgba[s + 1]
                dst.rgba[d + 2] = src.rgba[s + 2]; dst.rgba[d + 3] = src.rgba[s + 3]
            }
        }
    }
}
