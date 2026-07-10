import SwiftUI

/// The UI debug (measurement) overlay, shared by every authentic screen.
///
/// The whole UI is authored in fixed design-coordinate spaces — `NovaSpace`
/// (centre-relative native pixels, used by `NovaMenu`/`BareNovaPanel`) and
/// `NovaLayout` (top-left design units, used by `NovaCanvas`). Getting a control
/// to its authentic spot means finding the exact coordinate pair to pass to
/// `.novaPlace`. Without a way to *read* those coordinates off the running
/// screen, that's blind trial-and-error.
///
/// This overlay draws the grid + centre axes of whichever space it's placed in,
/// and — because it lives inside the same layer as that screen's content —
/// live-reports the design coordinate under your finger/cursor as the literal
/// `.novaPlace(...)` call to paste in. Toggle it from Settings ▸ Developer or
/// with ⇧⌘D. It's off by default and ships nothing visible until enabled.

// MARK: - Ambient flag

private struct NovaDebugKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Whether the UI debug measurement overlay is active. Injected once at the
    /// app root from `GameSettings.uiDebugOverlay`; every coordinate-space
    /// container (`NovaMenu`, `NovaCanvas`, `BareNovaPanel`) reads it.
    var novaDebugEnabled: Bool {
        get { self[NovaDebugKey.self] }
        set { self[NovaDebugKey.self] = newValue }
    }
}

extension View {
    func novaDebugEnabled(_ on: Bool) -> some View { environment(\.novaDebugEnabled, on) }
}

// MARK: - Grid overlay

/// A measurement grid for one coordinate space. Maps design units to the view
/// via `origin` (where design `(0,0)` sits) + `scale`, so it aligns pixel-exact
/// with content placed by `.novaPlace`. `centered` picks the readout convention:
/// `NovaSpace` reports offsets from the frame centre (what `novaPlace(space,
/// cx, cy)` wants); `NovaLayout` reports top-left design units.
struct NovaDebugGrid: View {
    let viewSize: CGSize
    let designSize: CGSize
    /// View-space point that design `(0,0)` maps to.
    let origin: CGPoint
    /// Design units → view points.
    let scale: CGFloat
    /// True for `NovaSpace` (labels are offsets from the design centre).
    let centered: Bool
    /// A short name for the space, shown in the header (e.g. "765×321 frame").
    var label: String = ""
    /// Grid spacing, in design units.
    var step: CGFloat = 50

    @State private var probe: CGPoint?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in draw(&ctx) }
                .allowsHitTesting(false)

            // Transparent capture layer: a tap/drag anywhere reports its
            // coordinate. Intercepts input while debug is on (that's the point —
            // point at where a control belongs and read the number); turn the
            // overlay off to interact with the screen again.
            Color.white.opacity(0.001)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { probe = $0.location })

            header
            if let p = probe { crosshair(p) }
        }
        .frame(width: viewSize.width, height: viewSize.height, alignment: .topLeading)
    }

    // design → view
    private func toView(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + dx * scale, y: origin.y + dy * scale)
    }
    // view → design label pair (centre-relative when `centered`)
    private func toDesign(_ p: CGPoint) -> (CGFloat, CGFloat) {
        let dx = (p.x - origin.x) / scale
        let dy = (p.y - origin.y) / scale
        return centered ? (dx - designSize.width / 2, dy - designSize.height / 2) : (dx, dy)
    }

    private func draw(_ ctx: inout GraphicsContext) {
        let g = Color.green
        // Frame border.
        let frame = CGRect(origin: toView(0, 0),
                           size: CGSize(width: designSize.width * scale, height: designSize.height * scale))
        ctx.stroke(Path(frame), with: .color(g.opacity(0.55)), lineWidth: 1)

        // Vertical lines every `step` design units.
        var dx: CGFloat = 0
        while dx <= designSize.width {
            let x = toView(dx, 0).x
            let onAxis = centered && abs(dx - designSize.width / 2) < 0.5
            var path = Path()
            path.move(to: CGPoint(x: x, y: frame.minY))
            path.addLine(to: CGPoint(x: x, y: frame.maxY))
            ctx.stroke(path, with: .color(g.opacity(onAxis ? 0.55 : 0.14)), lineWidth: onAxis ? 1 : 0.5)
            let value = centered ? Int(dx - designSize.width / 2) : Int(dx)
            ctx.draw(Text("\(value)").font(.system(size: 8, design: .monospaced)).foregroundColor(g.opacity(0.75)),
                     at: CGPoint(x: x + 2, y: frame.minY + 7), anchor: .leading)
            dx += step
        }
        // Horizontal lines every `step` design units.
        var dy: CGFloat = 0
        while dy <= designSize.height {
            let y = toView(0, dy).y
            let onAxis = centered && abs(dy - designSize.height / 2) < 0.5
            var path = Path()
            path.move(to: CGPoint(x: frame.minX, y: y))
            path.addLine(to: CGPoint(x: frame.maxX, y: y))
            ctx.stroke(path, with: .color(g.opacity(onAxis ? 0.55 : 0.14)), lineWidth: onAxis ? 1 : 0.5)
            let value = centered ? Int(dy - designSize.height / 2) : Int(dy)
            ctx.draw(Text("\(value)").font(.system(size: 8, design: .monospaced)).foregroundColor(g.opacity(0.75)),
                     at: CGPoint(x: frame.minX + 2, y: y + 1), anchor: .topLeading)
            dy += step
        }
    }

    private var header: some View {
        let title = label.isEmpty
            ? "UI DEBUG · \(Int(designSize.width))×\(Int(designSize.height))"
            : "UI DEBUG · \(label)"
        return Text(title)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(.green)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(Color.black.opacity(0.7))
            .position(x: toView(designSize.width / 2, 0).x, y: origin.y + 8)
            .allowsHitTesting(false)
    }

    private func crosshair(_ p: CGPoint) -> some View {
        let (cx, cy) = toDesign(p)
        let call = centered
            ? "novaPlace(space, \(Int(cx.rounded())), \(Int(cy.rounded())))"
            : "x: \(Int(cx.rounded()))  y: \(Int(cy.rounded()))"
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: p.x - 14, y: p.y)); path.addLine(to: CGPoint(x: p.x + 14, y: p.y))
                path.move(to: CGPoint(x: p.x, y: p.y - 14)); path.addLine(to: CGPoint(x: p.x, y: p.y + 14))
            }
            .stroke(Color.yellow, lineWidth: 1)

            Text(call)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.yellow)
                .padding(3)
                .background(Color.black.opacity(0.85))
                .fixedSize()
                .offset(x: min(p.x + 10, max(0, viewSize.width - 210)),
                        y: min(max(0, p.y - 20), max(0, viewSize.height - 18)))
        }
        .frame(width: viewSize.width, height: viewSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

extension NovaDebugGrid {
    /// Overlay for a `NovaSpace` screen (`NovaMenu`/`BareNovaPanel`). Placed
    /// inside the screen's own scaled layer, so its local coordinates already
    /// are the frame's native pixels — origin `(0,0)`, scale `1`, centre-relative.
    static func forSpace(_ space: NovaSpace, label: String = "") -> NovaDebugGrid {
        let size = CGSize(width: space.width, height: space.height)
        return NovaDebugGrid(viewSize: size, designSize: size, origin: .zero, scale: 1,
                             centered: true, label: label.isEmpty ? "\(Int(space.width))×\(Int(space.height)) frame" : label)
    }

    /// Overlay for a `NovaCanvas` screen (`NovaLayout`). Placed in the canvas's
    /// `GeometryReader`, so it maps design units through the layout's own
    /// origin/scale and reports top-left design coordinates.
    static func forLayout(_ layout: NovaLayout, viewSize: CGSize, label: String = "") -> NovaDebugGrid {
        NovaDebugGrid(viewSize: viewSize, designSize: layout.design, origin: layout.origin,
                      scale: layout.scale, centered: false,
                      label: label.isEmpty ? "\(Int(layout.design.width))×\(Int(layout.design.height)) canvas" : label)
    }
}
