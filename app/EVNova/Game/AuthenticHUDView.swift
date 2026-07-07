import SwiftUI
import EVNovaKit

/// The authentic EV Nova status bar, rendered from the player's own data: the
/// `ïntf` resource's backdrop PICT drawn on the right edge, with the radar,
/// shield / armor / fuel bars painted at the exact rectangles and colors the
/// game defines. Falls back to `GameHUDView` when the data has no `ïntf`.
struct AuthenticHUDStyle {
    let image: CGImage          // decoded backdrop PICT (e.g. #700)
    let intf: IntfRes
    var nativeSize: CGSize { CGSize(width: image.width, height: image.height) }
}

struct AuthenticHUDView: View {
    @ObservedObject var model: GameHUDModel
    let style: AuthenticHUDStyle

    var body: some View {
        GeometryReader { geo in
            let scale = min(1.0, geo.size.height / style.nativeSize.height)
            let w = style.nativeSize.width * scale
            let h = style.nativeSize.height * scale

            ZStack(alignment: .topLeading) {
                Image(decorative: style.image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: w, height: h)

                radarOverlay(scale: scale)
                bar(style.intf.shieldArea, model.shield, style.intf.shieldColor, scale)
                bar(style.intf.armorArea, model.armor, style.intf.armorColor, scale)
                bar(style.intf.fuelArea, model.fuel, style.intf.fuelFull, scale)
                shipLabel(scale: scale)
            }
            .frame(width: w, height: h)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .allowsHitTesting(false)
    }

    // A status bar drawn left-anchored inside its rect, filled to `value` (0…1).
    private func bar(_ rect: NovaRect, _ value: Double, _ color: NovaColor, _ scale: CGFloat) -> some View {
        Rectangle()
            .fill(swiftColor(color))
            .frame(width: max(0, CGFloat(rect.width) * scale * CGFloat(min(1, max(0, value)))),
                   height: CGFloat(rect.height) * scale)
            .position(x: CGFloat(rect.left) * scale + CGFloat(rect.width) * scale * CGFloat(min(1, max(0, value))) / 2,
                      y: CGFloat(rect.top) * scale + CGFloat(rect.height) * scale / 2)
    }

    // Radar contacts + heading, inside the interface's radar rectangle.
    private func radarOverlay(scale: CGFloat) -> some View {
        let r = style.intf.radarArea
        let cx = (CGFloat(r.left) + CGFloat(r.width) / 2) * scale
        let cy = (CGFloat(r.top) + CGFloat(r.height) / 2) * scale
        let radius = CGFloat(r.width) / 2 * scale - 2
        return ZStack {
            ForEach(Array(model.planetBlips.enumerated()), id: \.offset) { _, b in
                Circle().fill(swiftColor(style.intf.dimRadar))
                    .frame(width: 4, height: 4)
                    .position(x: cx + b.x * radius, y: cy + b.y * radius)
            }
            ForEach(Array(model.blips.enumerated()), id: \.offset) { _, b in
                Circle().fill(swiftColor(style.intf.brightRadar))
                    .frame(width: 4, height: 4)
                    .position(x: cx + b.x * radius, y: cy + b.y * radius)
            }
            Image(systemName: "triangle.fill")
                .font(.system(size: 6 * scale + 4))
                .foregroundStyle(swiftColor(style.intf.brightRadar))
                .rotationEffect(.degrees(model.headingDegrees))
                .position(x: cx, y: cy)
        }
    }

    // Ship name / system in the interface's bright text color, near the top.
    private func shipLabel(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(model.shipName)
                .font(.system(size: 11, design: .monospaced).weight(.bold))
            if !model.systemName.isEmpty {
                Text(model.systemName).font(.system(size: 9, design: .monospaced))
            }
        }
        .foregroundStyle(swiftColor(style.intf.brightText))
        .position(x: style.nativeSize.width * scale / 2,
                  y: (CGFloat(style.intf.targetArea.top) + 14) * scale)
    }

    private func swiftColor(_ c: NovaColor) -> Color {
        Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}
