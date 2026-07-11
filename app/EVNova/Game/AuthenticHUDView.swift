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
    /// Resolves a target ship's `shïp` id → its sprite, so the target readout can
    /// draw the ship's red silhouette (see `ShipSilhouetteView`). Defaults to no
    /// art, so the HUD still renders (text-only) without a resolver wired up.
    var targetSprite: (Int) -> CGImage? = { _ in nil }

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

                targetReadout(layout)
                    .novaPlace(layout, origin: origin(style.intf.targetArea), size: size(style.intf.targetArea))

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

    /// The real target-lock display: the selected ship's name, `shïp.Subtitle`,
    /// government, and shield/armor line (or the selected planet's name, or a
    /// dim "No Target"). The shield/armor line respects the target's own
    /// `shïp.Flags` per the Bible: 0x0200 hides it outright, 0x0100 substitutes
    /// armor % for the literal "Shields Down" text once shields hit 0.
    /// The target box: the ship's red silhouette (when the target is a ship the
    /// data has art for) beside the text readout, sized to scale with the HUD.
    private func targetReadout(_ layout: NovaLayout) -> some View {
        let sprite = model.targetShipTypeID.flatMap { targetSprite($0) }
        // The placed box is `targetArea` design-units × layout.scale tall, so a
        // silhouette sized off that height scales in lockstep with the HUD.
        let boxSide = CGFloat(style.intf.targetArea.height) * layout.scale * 0.82
        return HStack(alignment: .center, spacing: 5) {
            if !model.targetName.isEmpty, let sprite {
                ShipSilhouetteView(sprite: sprite, tint: targetTint)
                    .frame(width: boxSide, height: boxSide)
            }
            targetText
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// EV Nova draws the target silhouette in red; a brighter red reads a
    /// hostile lock, a duller one a neutral/known contact.
    private var targetTint: Color {
        model.targetHostile ? Color(red: 0.98, green: 0.28, blue: 0.22)
                            : Color(red: 0.85, green: 0.34, blue: 0.28)
    }

    @ViewBuilder
    private var targetText: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !model.targetName.isEmpty {
                Text(model.targetName)
                    .novaFont(.hud, weight: .bold, size: statusSize)
                    .foregroundStyle(model.targetHostile ? Color.red : color(style.intf.brightText))
                if !model.targetSubtitle.isEmpty {
                    Text(model.targetSubtitle).novaFont(.hud, size: subtitleSize)
                        .foregroundStyle(color(style.intf.dimText))
                }
                if !model.targetGovtLabel.isEmpty {
                    Text(model.targetGovtLabel).novaFont(.hud, size: subtitleSize)
                        .foregroundStyle(color(style.intf.dimText))
                }
                if !model.targetHidesShieldArmorLine {
                    Text(targetShieldArmorLine)
                        .novaFont(.hud, size: subtitleSize).monospacedDigit()
                        .foregroundStyle(color(style.intf.dimText))
                }
            } else if !model.navTargetName.isEmpty {
                Text(model.navTargetName)
                    .novaFont(.hud, weight: .bold, size: statusSize)
                    .foregroundStyle(color(style.intf.brightText))
                Text(model.navTargetLandable ? "Landable" : "No landing clearance")
                    .novaFont(.hud, size: subtitleSize)
                    .foregroundStyle(color(style.intf.dimText))
            } else {
                Text("No Target").novaFont(.hud, size: subtitleSize)
                    .foregroundStyle(color(style.intf.dimText))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Shield N%" while shields remain; once depleted, literal "Shields Down"
    /// unless the target's `shïp.Flags` 0x0100 asks for its armor % instead.
    private var targetShieldArmorLine: String {
        if model.targetShield > 0 {
            return "Shield \(Int(model.targetShield * 100))%"
        } else if model.targetShowArmorWhenShieldsDown {
            return "Armor \(Int(model.targetArmor * 100))%"
        } else {
            return "Shields Down"
        }
    }

    /// Active weapon + remaining ammo (blank when unarmed — an empty box here
    /// reads as "no weapon selected", matching an unarmed shuttle).
    private var weaponReadout: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !model.weaponName.isEmpty {
                Text(model.weaponName).novaFont(.hud, weight: .semibold, size: statusSize)
                    .foregroundStyle(color(style.intf.brightText))
                if model.weaponAmmo >= 0 {
                    Text("\(model.weaponAmmo) rounds").novaFont(.hud, size: subtitleSize).monospacedDigit()
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
            Text(model.shipName).novaFont(.hud, weight: .semibold, size: statusSize)
                .foregroundStyle(color(style.intf.brightText))
            if !model.systemName.isEmpty {
                Text(model.systemName).novaFont(.hud, size: subtitleSize)
                    .foregroundStyle(color(style.intf.dimText))
            }
            if !model.navCourseSystemName.isEmpty {
                Text("Course: \(model.navCourseSystemName)").novaFont(.hud, size: subtitleSize)
                Text("\(model.navCourseJumps) jump\(model.navCourseJumps == 1 ? "" : "s")")
                    .novaFont(.hud, size: subtitleSize).monospacedDigit()
            }
        }
        .foregroundStyle(color(style.intf.dimText))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Cargo hold usage — hidden entirely for holds with no capacity (e.g. an
    /// unmodified shuttle), matching how the bar areas above stay blank too.
    /// The real `CargoArea` rect is sized for a per-commodity list (e.g.
    /// "Food 4t" / "Metal 2t"); `model.cargoByCommodity` supplies those lines
    /// when the caller has wired up a per-commodity source, on top of the
    /// aggregate total this always shows.
    @ViewBuilder
    private var cargoReadout: some View {
        if model.cargoCapacity > 0 {
            VStack(alignment: .leading, spacing: 1) {
                Text("CARGO \(model.cargoUsed)/\(model.cargoCapacity)t")
                    .novaFont(.hud, size: statusSize).monospacedDigit()
                    .foregroundStyle(color(style.intf.dimText))
                ForEach(model.cargoByCommodity, id: \.name) { item in
                    Text("\(item.name) \(item.tons)t")
                        .novaFont(.hud, size: subtitleSize).monospacedDigit()
                        .foregroundStyle(color(style.intf.dimText))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The `ïntf` resource's own font sizes (`StatusFontSize`/`SubtitleFontSize`)
    /// for the HUD's primary vs. secondary/descriptor lines, in design-space
    /// points — `.novaFont(size:)` scales them by the ambient `novaTextScale`
    /// the same way it scales every role's built-in `baseSize`. Falls back to
    /// the generic `.hud` role size if a given `ïntf` (e.g. an unusual
    /// government skin) leaves the field zeroed.
    ///
    /// The `hudTextTighten` factor pulls the readouts back toward the original's
    /// compact look: the status bar's `NovaCanvas(fit: .right)` scales to fill
    /// the *window* height (≈1.25× the 767pt design height on a desktop window),
    /// which scaled the text up in proportion; the original's text sat visibly
    /// smaller against the same chrome, so we shrink it a touch to match.
    private static let hudTextTighten: CGFloat = 0.8
    private var statusSize: CGFloat {
        (style.intf.statusFontSize > 0 ? CGFloat(style.intf.statusFontSize) : NovaFontRole.hud.baseSize) * Self.hudTextTighten
    }
    private var subtitleSize: CGFloat {
        (style.intf.subtitleFontSize > 0 ? CGFloat(style.intf.subtitleFontSize) : NovaFontRole.hud.baseSize) * Self.hudTextTighten
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
