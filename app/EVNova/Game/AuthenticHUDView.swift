import SwiftUI
import EVNovaKit

/// The authentic EV Nova status bar, rendered from the player's own data via the
/// shared `NovaCanvas` layout: the `ïntf` backdrop PICT anchored to the right
/// edge, with the radar, shield / armor / fuel bars painted at the exact `ïntf`
/// rectangles and colors — the same coordinate system every other authentic
/// screen uses. Falls back to `GameHUDView` when the data has no `ïntf`.
struct AuthenticHUDStyle {
    let image: CGImage          // decoded backdrop PICT (e.g. #700)
    let intf: IntfRes
    var nativeSize: CGSize { CGSize(width: image.width, height: image.height) }
}

struct AuthenticHUDView: View {
    @ObservedObject var model: GameHUDModel
    let style: AuthenticHUDStyle

    var body: some View {
        // The status bar's design space is the backdrop PICT; anchor it to the
        // right edge and scale to fill the height.
        NovaCanvas(design: style.nativeSize, fit: .right) { layout in
            ZStack(alignment: .topLeading) {
                Image(decorative: style.image, scale: 1)
                    .interpolation(.none).resizable()
                    .novaPlace(layout, x: 0, y: 0, w: style.nativeSize.width, h: style.nativeSize.height)

                bar(layout, style.intf.shieldArea, model.shield, style.intf.shieldColor)
                bar(layout, style.intf.armorArea, model.armor, style.intf.armorColor)
                bar(layout, style.intf.fuelArea, model.fuel, style.intf.fuelFull)

                RadarContactsView(model: model,
                                  bright: color(style.intf.brightRadar),
                                  dim: color(style.intf.dimRadar))
                    .novaPlace(layout, origin: origin(style.intf.radarArea), size: size(style.intf.radarArea))

                shipLabel
                    .novaPlace(layout, origin: origin(style.intf.targetArea),
                               size: CGSize(width: style.intf.targetArea.width, height: 40))
            }
        }
        .allowsHitTesting(false)
    }

    /// A status bar drawn left-anchored inside its rect, filled to `value` (0…1).
    private func bar(_ layout: NovaLayout, _ r: NovaRect, _ value: Double, _ c: NovaColor) -> some View {
        let v = CGFloat(min(1, max(0, value)))
        return Rectangle().fill(color(c))
            .novaPlace(layout, x: CGFloat(r.left), y: CGFloat(r.top),
                       w: CGFloat(r.width) * v, h: CGFloat(r.height))
    }

    private var shipLabel: some View {
        VStack(spacing: 1) {
            Text(model.shipName).font(.system(size: 11, design: .monospaced).weight(.bold))
            if !model.systemName.isEmpty {
                Text(model.systemName).font(.system(size: 9, design: .monospaced))
            }
        }
        .foregroundStyle(color(style.intf.brightText))
    }

    private func origin(_ r: NovaRect) -> CGPoint { CGPoint(x: r.left, y: r.top) }
    private func size(_ r: NovaRect) -> CGSize { CGSize(width: r.width, height: r.height) }
    private func color(_ c: NovaColor) -> Color {
        Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}

/// Radar contacts + player heading, drawn in the placed radar rect's local space.
/// Stellars are the larger dim dots, ships the small bright ones (hostiles red).
private struct RadarContactsView: View {
    @ObservedObject var model: GameHUDModel
    let bright: Color
    let dim: Color

    var body: some View {
        GeometryReader { geo in
            let cx = geo.size.width / 2, cy = geo.size.height / 2
            let radius = min(geo.size.width, geo.size.height) / 2 - 2
            ZStack {
                Canvas { ctx, _ in
                    for b in model.planetBlips {
                        let r = CGRect(x: cx + b.x * radius - 2.5, y: cy + b.y * radius - 2.5, width: 5, height: 5)
                        ctx.fill(Path(ellipseIn: r), with: .color(dim))
                    }
                    for b in model.blips {
                        let r = CGRect(x: cx + b.x * radius - 1.5, y: cy + b.y * radius - 1.5, width: 3, height: 3)
                        ctx.fill(Path(ellipseIn: r),
                                 with: .color(b.hostile ? Color(red: 0.95, green: 0.3, blue: 0.25) : bright))
                    }
                }
                ZStack {
                    RadarPlayerArrow().fill(bright)
                    RadarPlayerArrow().stroke(.white.opacity(0.7), lineWidth: 0.5)
                }
                .frame(width: 9, height: 12)
                .rotationEffect(.degrees(model.headingDegrees))
                .position(x: cx, y: cy)
            }
        }
    }
}
