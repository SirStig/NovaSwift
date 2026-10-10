import Foundation

/// The original's data-loading bar (`FUN_004ab1b0` opens it,
/// `NovaUi_RedrawProgressBar` 0x004ab3d0 redraws it). The bar's rect is cölr
/// ProgressBar, offset from the window centre. Each redraw:
/// - frames the rect in ProgOutline;
/// - fills `(top+2, left+2, bottom−2, fillRight−1)` with ProgBright and frames
///   `(top+1, left+1, bottom−1, fillRight)` in ProgDim;
/// - paints `fillRight…right−1` black.
/// `fillRight = floor(left + 1 + done/total · 198)` (198 is a constant, not
/// the rect width; total = the number of shïp resources), capped at
/// `right − 1`. The opening animation grows the outline from the middle row,
/// one pixel up and down every 2 ticks.
public enum LoadingProgressBar {
    public static let fillSpan = 198.0
    public static let openingTicksPerStep = 2

    public static func fillRight(left: Int, right: Int, done: Double, total: Double) -> Int {
        let frac = total > 0 ? done / total : 0
        let f = Int((Double(left + 1) + frac * fillSpan).rounded(.down))
        return min(f, right - 1)
    }

    /// The outline's vertical extent `step` steps into the opening animation
    /// for a bar whose rect runs `top…bottom`; nil once fully open.
    public static func openingExtent(top: Int, bottom: Int, step: Int) -> (top: Int, bottom: Int)? {
        let mid = top + (bottom - top) / 2
        let t = mid - step, b = mid + step
        guard t > top || b < bottom else { return nil }
        return (max(t, top), min(b, bottom))
    }
}
