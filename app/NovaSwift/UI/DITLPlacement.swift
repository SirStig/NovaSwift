import SwiftUI
import NovaSwiftKit

/// A screen's `DLOG`/`DITL` layout bound to the `NovaSpace` of the frame PICT
/// it is drawn on. Every authentic screen asks for its control rects through
/// here, passing the stock rect as the fallback, so a plug-in's or TC's
/// replacement `DITL` moves the controls and their hit areas as it does in
/// the original (C I-1).
///
/// Coordinates: a `DITL` rect is relative to the window's top-left, where the
/// original also draws the backdrop PICT. `NovaMenu` centres that PICT, so an
/// item's `NovaSpace` offset is `left − frameWidth/2, top − frameHeight/2`.
/// The window itself is the `DLOG` size, centred (its position is ignored,
/// 0x008730a1); `windowSize` gives it to screens that draw their own chrome.
struct DITLPlacement {
    let layout: DITLLayout
    /// The coordinate origin's extent: the frame PICT the items sit on.
    let window: CGSize
    /// The `DLOG` window size, or the frame size when there is no `DLOG`.
    let windowSize: CGSize

    init(_ game: NovaGame?, _ id: Int, window frame: CGSize) {
        let layout = game?.ditlLayout(id) ?? DITLLayout(id: id, dialog: nil)
        self.layout = layout
        window = frame
        let size = layout.windowSize(fallback: NovaSize(width: Int(frame.width),
                                                         height: Int(frame.height)))
        windowSize = CGSize(width: size.width, height: size.height)
    }

    /// Bound to the frame PICT actually drawn (a TC's replacement art may be a
    /// different size from the stock one).
    init(_ game: NovaGame?, _ id: Int, frame: CGImage) {
        self.init(game, id, window: CGSize(width: frame.width, height: frame.height))
    }

    /// Item `index`'s rect in window pixels, or the stock rect when the
    /// resource doesn't supply it. Fallback given as the DITL stores it.
    func rect(_ index: Int, top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) -> CGRect {
        let r = layout.rect(index, fallback: NovaRect(top: Int(top), left: Int(left),
                                                       bottom: Int(bottom), right: Int(right)))
        return CGRect(x: r.left, y: r.top, width: r.width, height: r.height)
    }

    /// Item `index`'s rect, fallback given as origin + size.
    func rect(_ index: Int, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> CGRect {
        rect(index, top: y, left: x, bottom: y + h, right: x + w)
    }

    /// How far the loaded `DITL` moved item `index` (and how much it grew)
    /// relative to the stock rect. For the few screens whose stock positions
    /// carry hand-tuned nudges: they keep the nudge and follow the resource.
    func delta(_ index: Int, stock s: CGRect) -> (dx: CGFloat, dy: CGFloat, dw: CGFloat, dh: CGFloat) {
        let r = rect(index, x: s.minX, y: s.minY, w: s.width, h: s.height)
        return (r.minX - s.minX, r.minY - s.minY, r.width - s.width, r.height - s.height)
    }

    /// `NovaSpace` offset (from the frame centre) of a window-pixel point.
    func centreOffset(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - window.width / 2, y: p.y - window.height / 2)
    }

    /// The `DITL` index of the item that gets keyboard focus first, if any.
    var initialFocusIndex: Int? { layout.initialFocusIndex }
}

/// A DITL rect as the screens that keep `(left, top, w, h)` tuples use it.
typealias DITLItemRect = (left: Int, top: Int, w: Int, h: Int)

/// A resolver for dialog `id`: `(index, stockRect) → rect`, taking the loaded
/// `DITL`'s item when present and the stock rect otherwise.
func ditlItemLookup(_ game: NovaGame?, _ id: Int) -> (Int, DITLItemRect) -> DITLItemRect {
    let layout = game?.ditlLayout(id) ?? DITLLayout(id: id, dialog: nil)
    return { index, s in
        let r = layout.rect(index, fallback: NovaRect(top: s.top, left: s.left,
                                                      bottom: s.top + s.h, right: s.left + s.w))
        return (r.left, r.top, r.width, r.height)
    }
}

extension NovaSpace {
    /// The frame's pixel size (the `DITL` coordinate extent).
    var size: CGSize { CGSize(width: width, height: height) }
}

extension View {
    /// Place this view top-left anchored at a window-pixel rect resolved from a
    /// `DITLPlacement`.
    func ditlPlace(_ space: NovaSpace, _ placement: DITLPlacement, _ rect: CGRect) -> some View {
        let o = placement.centreOffset(rect.origin)
        return novaPlace(space, o.x, o.y)
    }
}

extension NovaButton {
    /// A three-slice button sized to DITL rect `rect`: the caps are 13 px
    /// each, so the tiled middle spans the rest of the item's width.
    init(graphics: SpaceportGraphics, title: String, ditl rect: CGRect, enabled: Bool = true,
         onQuantity: (() -> Void)? = nil, action: @escaping () -> Void) {
        self.init(graphics: graphics, title: title, width: max(0, rect.width - 26),
                  enabled: enabled, onQuantity: onQuantity, action: action)
    }
}

extension View {
    /// Place this view at a stock `NovaSpace` offset `(cx, cy)` (which may
    /// carry a hand-tuned nudge), shifted by however far the loaded `DITL`
    /// moved item `index` from its stock rect `stock`.
    func ditlPlace(_ space: NovaSpace, _ placement: DITLPlacement, _ index: Int,
                   stock: CGRect, at cx: CGFloat, _ cy: CGFloat) -> some View {
        let m = placement.delta(index, stock: stock)
        return novaPlace(space, cx + m.dx, cy + m.dy)
    }
}

// MARK: - Dialog keys (C I-10)

extension View {
    /// The original's dialog loop (0x004cfdd0) sends Return to the dialog's
    /// default item and Esc to its cancel item. Pass the action of each (nil
    /// when the dialog has none, or when that item is currently disabled —
    /// the original ignores the key then too).
    func novaDialogKeys(onDefault: (() -> Void)? = nil, onCancel: (() -> Void)? = nil) -> some View {
        background(NovaDialogKeyButtons(onDefault: onDefault, onCancel: onCancel))
    }
}

/// Invisible buttons that carry the default/cancel keyboard shortcuts.
private struct NovaDialogKeyButtons: View {
    let onDefault: (() -> Void)?
    let onCancel: (() -> Void)?

    var body: some View {
        #if os(tvOS)
        Color.clear.onExitCommand { onCancel?() }
        #else
        ZStack {
            if let onDefault {
                Button("", action: onDefault).keyboardShortcut(.defaultAction)
            }
            if let onCancel {
                Button("", action: onCancel).keyboardShortcut(.cancelAction)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        #endif
    }
}
