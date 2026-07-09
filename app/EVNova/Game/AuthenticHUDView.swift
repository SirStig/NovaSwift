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
    var showRadar: Bool = true

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

                if showRadar {
                    RadarContactsView(model: model, playerMarker: color(style.intf.brightRadar))
                        .novaPlace(layout, origin: origin(style.intf.radarArea), size: size(style.intf.radarArea))
                }

                targetReadout
                    .novaPlace(layout, origin: origin(style.intf.targetArea),
                               size: CGSize(width: style.intf.targetArea.width, height: 40))

                weaponReadout
                    .novaPlace(layout, origin: origin(style.intf.weaponArea), size: size(style.intf.weaponArea))
                navReadout
                    .novaPlace(layout, origin: origin(style.intf.navArea), size: size(style.intf.navArea))
                cargoReadout
                    .novaPlace(layout, origin: origin(style.intf.cargoArea), size: size(style.intf.cargoArea))
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

    /// The real target-lock display: the selected ship's name, government,
    /// and shield %, or the selected planet's name, or a dim "No Target".
    @ViewBuilder
    private var targetReadout: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !model.targetName.isEmpty {
                Text(model.targetName)
                    .novaFont(.hud, weight: .bold)
                    .foregroundStyle(model.targetHostile ? Color.red : color(style.intf.brightText))
                if !model.targetGovtLabel.isEmpty {
                    Text(model.targetGovtLabel).novaFont(.hud)
                        .foregroundStyle(color(style.intf.dimText))
                }
                Text("Shield \(Int(model.targetShield * 100))%")
                    .novaFont(.hud).monospacedDigit()
                    .foregroundStyle(color(style.intf.dimText))
            } else if !model.navTargetName.isEmpty {
                Text(model.navTargetName)
                    .novaFont(.hud, weight: .bold)
                    .foregroundStyle(color(style.intf.brightText))
                Text(model.navTargetLandable ? "Landable" : "No landing clearance")
                    .novaFont(.hud)
                    .foregroundStyle(color(style.intf.dimText))
            } else {
                Text("No Target").novaFont(.hud)
                    .foregroundStyle(color(style.intf.dimText))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Active weapon + remaining ammo (blank when unarmed — an empty box here
    /// reads as "no weapon selected", matching an unarmed shuttle).
    private var weaponReadout: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !model.weaponName.isEmpty {
                Text(model.weaponName).novaFont(.hud, weight: .semibold)
                    .foregroundStyle(color(style.intf.brightText))
                if model.weaponAmmo >= 0 {
                    Text("\(model.weaponAmmo) rounds").novaFont(.hud).monospacedDigit()
                        .foregroundStyle(color(style.intf.dimText))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The nav computer's rect: the player's own ship name/system, plus the
    /// plotted hyperspace course (`ïntf.NavArea` — the real "navigation
    /// display" per the Bible) when one is set. Replaces an earlier
    /// placeholder that showed fabricated speed/heading readouts here, which
    /// the real interface data has no field for at all.
    private var navReadout: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(model.shipName).novaFont(.hud, weight: .semibold)
                .foregroundStyle(color(style.intf.brightText))
            if !model.systemName.isEmpty {
                Text(model.systemName).novaFont(.hud)
                    .foregroundStyle(color(style.intf.dimText))
            }
            if !model.navCourseSystemName.isEmpty {
                Text("Course: \(model.navCourseSystemName)").novaFont(.hud)
                Text("\(model.navCourseJumps) jump\(model.navCourseJumps == 1 ? "" : "s")")
                    .novaFont(.hud).monospacedDigit()
            }
        }
        .foregroundStyle(color(style.intf.dimText))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Cargo hold usage — hidden entirely for holds with no capacity (e.g. an
    /// unmodified shuttle), matching how the bar areas above stay blank too.
    @ViewBuilder
    private var cargoReadout: some View {
        if model.cargoCapacity > 0 {
            Text("CARGO \(model.cargoUsed)/\(model.cargoCapacity)t")
                .novaFont(.hud).monospacedDigit()
                .foregroundStyle(color(style.intf.dimText))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func origin(_ r: NovaRect) -> CGPoint { CGPoint(x: r.left, y: r.top) }
    private func size(_ r: NovaRect) -> CGSize { CGSize(width: r.width, height: r.height) }
    private func color(_ c: NovaColor) -> Color {
        Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}

/// Radar contacts + player heading, drawn in the placed radar rect's local space.
/// Stellars are the larger dots, ships the small ones; both colored by relationship
/// to the player — red hostile, yellow neutral, green friendly/owned, grey disabled
/// or non-functional.
private struct RadarContactsView: View {
    @ObservedObject var model: GameHUDModel
    let playerMarker: Color

    var body: some View {
        GeometryReader { geo in
            let cx = geo.size.width / 2, cy = geo.size.height / 2
            let radius = min(geo.size.width, geo.size.height) / 2 - 2
            ZStack {
                Color.clear.onAppear {
                    // The one runtime check static analysis can't do: whether the
                    // rect this view actually got placed at (via `.novaPlace`,
                    // driven by the decoded `ïntf.radarArea`) resolved to a real
                    // on-screen size. If this logs ~0×0, the radar is invisible
                    // even though the view hierarchy and data are otherwise fine.
                    if geo.size.width < 2 || geo.size.height < 2 {
                        Log.radar.error("RadarContactsView got a degenerate size \(geo.size.width, privacy: .public)x\(geo.size.height, privacy: .public) — radar will render invisibly")
                    } else {
                        Log.radar.debug("RadarContactsView size=\(geo.size.width, privacy: .public)x\(geo.size.height, privacy: .public) planetBlips=\(model.planetBlips.count, privacy: .public) blips=\(model.blips.count, privacy: .public)")
                    }
                }
                Canvas { ctx, _ in
                    for b in model.planetBlips {
                        let r = CGRect(x: cx + b.x * radius - 2.5, y: cy + b.y * radius - 2.5, width: 5, height: 5)
                        ctx.fill(Path(ellipseIn: r), with: .color(b.relationship.color))
                    }
                    for b in model.blips {
                        let r = CGRect(x: cx + b.x * radius - 1.5, y: cy + b.y * radius - 1.5, width: 3, height: 3)
                        ctx.fill(Path(ellipseIn: r), with: .color(b.relationship.color))
                    }
                }
                ZStack {
                    RadarPlayerArrow().fill(playerMarker)
                    RadarPlayerArrow().stroke(.white.opacity(0.7), lineWidth: 0.5)
                }
                .frame(width: 9, height: 12)
                .rotationEffect(.degrees(model.headingDegrees))
                .position(x: cx, y: cy)
            }
        }
    }
}
