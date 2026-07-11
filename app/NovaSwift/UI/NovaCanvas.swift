import SwiftUI

/// The shared layout system for all authentic EV Nova UI.
///
/// EV Nova's interface is authored in a fixed **design coordinate space** — the
/// title screen in 1024×768, the status bar in its backdrop PICT's own size,
/// dialogs in their PICT's size — and every element (button, bar, image, text)
/// sits at exact coordinates in that space. `NovaLayout` maps that design space
/// onto whatever view size we're given, once, so *every* screen positions things
/// the same reliable way. Add UI by giving it design coordinates via `novaPlace`
/// — never by hand-rolling GeometryReader math per screen.
struct NovaLayout: Equatable {
    /// How the design space is fitted into the view.
    enum Fit {
        case fit        // whole design visible, letterboxed (menus, dialogs)
        case fill       // cover the view, cropping overflow
        case right      // scale to height, anchor to the right edge (status bar)
        case left       // scale to height, anchor to the left edge
        case top, bottom
    }

    let design: CGSize
    let viewSize: CGSize
    let fit: Fit

    var scale: CGFloat {
        switch fit {
        case .fit:  return min(sx, sy)
        case .fill: return max(sx, sy)
        case .left, .right: return sy   // fill height, anchor horizontally
        case .top, .bottom: return sx
        }
    }
    private var sx: CGFloat { design.width  > 0 ? viewSize.width  / design.width  : 1 }
    private var sy: CGFloat { design.height > 0 ? viewSize.height / design.height : 1 }

    /// Top-left of the mapped design region, in view coordinates.
    var origin: CGPoint {
        let w = design.width * scale, h = design.height * scale
        switch fit {
        case .fit, .fill: return CGPoint(x: (viewSize.width - w) / 2, y: (viewSize.height - h) / 2)
        case .left:  return CGPoint(x: 0, y: (viewSize.height - h) / 2)
        case .right: return CGPoint(x: viewSize.width - w, y: (viewSize.height - h) / 2)
        case .top:   return CGPoint(x: (viewSize.width - w) / 2, y: 0)
        case .bottom: return CGPoint(x: (viewSize.width - w) / 2, y: viewSize.height - h)
        }
    }

    /// Convert a design-space point to a view point.
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
    }
    func point(_ p: CGPoint) -> CGPoint { point(p.x, p.y) }

    /// Scale a scalar / size from design units to view units.
    func length(_ v: CGFloat) -> CGFloat { v * scale }
    func size(_ s: CGSize) -> CGSize { CGSize(width: s.width * scale, height: s.height * scale) }
    func center(ofRectAt origin: CGPoint, size: CGSize) -> CGPoint {
        point(origin.x + size.width / 2, origin.y + size.height / 2)
    }
}

/// Provides a `NovaLayout` for its content, computed once from the view size.
struct NovaCanvas<Content: View>: View {
    let design: CGSize
    var fit: NovaLayout.Fit = .fit
    @Environment(\.novaDebugEnabled) private var novaDebug
    @ViewBuilder var content: (NovaLayout) -> Content

    var body: some View {
        GeometryReader { geo in
            let layout = NovaLayout(design: design, viewSize: geo.size, fit: fit)
            ZStack {
                content(layout).novaTextScale(layout.scale)
                if novaDebug { NovaDebugGrid.forLayout(layout, viewSize: geo.size) }
            }
        }
    }
}

extension View {
    /// Place this view at a design-space rectangle (origin = top-left, in design units).
    func novaPlace(_ layout: NovaLayout, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        let s = layout.size(CGSize(width: w, height: h))
        let c = layout.center(ofRectAt: CGPoint(x: x, y: y), size: CGSize(width: w, height: h))
        return self.frame(width: s.width, height: s.height).position(c)
    }
    func novaPlace(_ layout: NovaLayout, origin: CGPoint, size: CGSize) -> some View {
        novaPlace(layout, x: origin.x, y: origin.y, w: size.width, h: size.height)
    }
}
