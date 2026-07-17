import SwiftUI
import NovaSwiftKit

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
                fuelBar(layout)

                if showRadar {
                    RadarContactsView(model: model,
                                      brightRadar: style.intf.brightRadar,
                                      dimRadar: style.intf.dimRadar)
                        .novaPlace(layout, origin: origin(style.intf.radarArea), size: size(style.intf.radarArea))
                }

                targetReadout()
                    .novaPlace(layout, origin: origin(style.intf.targetArea), size: size(style.intf.targetArea))

                weaponReadout
                    .novaPlace(layout, origin: origin(style.intf.weaponArea), size: size(style.intf.weaponArea))
                navReadout
                    .novaPlace(layout, origin: origin(style.intf.navArea), size: size(style.intf.navArea))
                cargoReadout
                    .novaPlace(layout, origin: origin(style.intf.cargoArea), size: size(style.intf.cargoArea))
            }
            // Honor the plug-in's ïntf.statusFont for every HUD readout in this
            // subtree; falls back to Geneva when the named family isn't a font
            // the player has imported (see hudFontFamily).
            .environment(\.novaHUDFontFamily, hudFontFamily)
        }
        .allowsHitTesting(false)
    }

    /// The plug-in-supplied HUD font (`ïntf.statusFont`), resolved to a family
    /// that's actually registered — otherwise Geneva (the `.hud` role's own
    /// fallback). `nil` when the resource names no font, leaving the HUD in
    /// Geneva. Most stock `ïntf`s name "Geneva" here, so this is usually a
    /// no-op; a total conversion that ships (and imports) a custom UI font is
    /// what it exists for.
    private var hudFontFamily: String? {
        let f = style.intf.statusFont
        guard !f.isEmpty else { return nil }
        return NovaFontFallback.resolve(f, fallback: NovaFontRole.hud.family)
    }

    /// EV Nova's fuel gauge is a jump meter, not a smooth bar: it fills in
    /// whole-hyperjump units painted in `ïntf.fuelFull`, and draws the leftover
    /// fuel that hasn't yet accumulated a full jump in `ïntf.fuelPartial`. We
    /// reproduce that by splitting the fill at the largest whole-jump boundary
    /// the current fuel clears (`jumps × 100 / maxFuel` of the rect), painting
    /// everything below it full and the remainder partial. With no ship state
    /// (maxFuel == 0) it collapses to a single fuelFull fill.
    @ViewBuilder
    private func fuelBar(_ layout: NovaLayout) -> some View {
        let r = style.intf.fuelArea
        let frac = min(1, max(0, model.fuel))
        let fullFrac: Double = model.maxFuel > 0
            ? min(frac, Double(model.jumps) * 100 / model.maxFuel)
            : frac
        let partialFrac = max(0, frac - fullFrac)
        // Whole-jump portion, left-anchored.
        if fullFrac > 0 {
            Rectangle().fill(color(style.intf.fuelFull))
                .novaPlace(layout, x: CGFloat(r.left), y: CGFloat(r.top),
                           w: CGFloat(r.width) * fullFrac, h: CGFloat(r.height))
        }
        // Partial (sub-jump) remainder, butted against the whole-jump portion.
        if partialFrac > 0 {
            Rectangle().fill(color(style.intf.fuelPartial))
                .novaPlace(layout, x: CGFloat(r.left) + CGFloat(r.width) * fullFrac, y: CGFloat(r.top),
                           w: CGFloat(r.width) * partialFrac, h: CGFloat(r.height))
        }
    }

    /// A status bar drawn left-anchored inside its rect, filled to `value` (0…1).
    private func bar(_ layout: NovaLayout, _ r: NovaRect, _ value: Double, _ c: NovaColor) -> some View {
        let v = CGFloat(min(1, max(0, value)))
        return Rectangle().fill(color(c))
            .novaPlace(layout, x: CGFloat(r.left), y: CGFloat(r.top),
                       w: CGFloat(r.width) * v, h: CGFloat(r.height))
    }

    /// The real target-lock display, laid out like EV Nova's: the target's name
    /// (bold, bright) and `shïp.Subtitle` centered up top, the ship's red
    /// silhouette below, and a bottom row pairing the shield/armor readout
    /// (bright) with the government label (dim). Falls back to a centered nav
    /// destination, then a centered dim "No Target". The shield/armor line
    /// respects the target's own `shïp.Flags` per the Bible: 0x0200 hides it
    /// outright, 0x0100 substitutes armor % for "Shields Down" once shields
    /// hit 0.
    @ViewBuilder
    private func targetReadout() -> some View {
        if !model.targetName.isEmpty {
            let sprite = model.targetShipTypeID.flatMap { targetSprite($0) }
            VStack(spacing: 2) {
                Text(model.targetName)
                    .novaFont(.hud, weight: .bold, size: statusSize)
                    // Hostile locks take the theme's radar-alert hue (the same
                    // brightRadar that paints a hostile blip), so a reskin's
                    // "danger" color drives the name too; friendly/neutral use
                    // the normal bright text color.
                    .foregroundStyle(model.targetHostile ? color(style.intf.brightRadar) : color(style.intf.brightText))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                if !model.targetSubtitle.isEmpty {
                    Text(model.targetSubtitle).novaFont(.hud, size: subtitleSize)
                        .foregroundStyle(color(style.intf.dimText))
                        .multilineTextAlignment(.center)
                }
                // The silhouette claims every point the text rows don't, kept
                // square by its aspect ratio, so the ship fills the `targetArea`
                // box the way the original's does instead of floating in it at a
                // fixed fraction of the box height. Greedy sizing rather than a
                // hardcoded side also means it can't overflow the padded column
                // or under-fill a reskin whose targetArea is a different shape.
                if let sprite {
                    ShipSilhouetteView(sprite: sprite, tint: targetTint)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer(minLength: 2)
                }
                // EV Nova packs the whole status line into a single row beneath the
                // ship picture: a status word on the left, the government/class label
                // on the right. "Disabled" takes precedence over the shield/armor
                // readout (a disabled hulk can't threaten you regardless of its
                // government); when the shield/armor line is hidden a hostile lock
                // falls back to the "Hostile" word so the state is never lost.
                // Hostility for a live ship is otherwise carried by the red name.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if model.targetDisabled {
                        Text("Disabled").novaFont(.hud, weight: .bold, size: subtitleSize)
                            .foregroundStyle(color(style.intf.dimText))
                    } else if !model.targetHidesShieldArmorLine {
                        Text(targetShieldArmorLine)
                            .novaFont(.hud, weight: .semibold, size: subtitleSize).monospacedDigit()
                            .foregroundStyle(color(style.intf.brightText))
                    } else if model.targetHostile {
                        Text("Hostile").novaFont(.hud, weight: .bold, size: subtitleSize)
                            .foregroundStyle(color(style.intf.brightRadar))
                    }
                    Spacer(minLength: 0)
                    if !model.targetGovtLabel.isEmpty {
                        Text(model.targetGovtLabel).novaFont(.hud, size: subtitleSize)
                            .foregroundStyle(color(style.intf.dimText))
                    }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if !model.navTargetName.isEmpty {
            VStack(spacing: 2) {
                Text(model.navTargetName)
                    .novaFont(.hud, weight: .bold, size: statusSize)
                    .foregroundStyle(color(style.intf.brightText))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Text(model.navTargetLandable ? "Landable" : "No landing clearance")
                    .novaFont(.hud, size: subtitleSize)
                    .foregroundStyle(color(style.intf.dimText))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            Text("No Target").novaFont(.hud, size: subtitleSize)
                .foregroundStyle(color(style.intf.dimText))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    /// EV Nova draws the target silhouette in red; a brighter red reads a
    /// hostile lock, a duller one a neutral/known contact.
    private var targetTint: Color {
        model.targetHostile ? Color(red: 0.98, green: 0.28, blue: 0.22)
                            : Color(red: 0.85, green: 0.34, blue: 0.28)
    }

    /// "Shield N%" while shields remain, "Armor N%" once they're gone. The
    /// original gated the armor readout on `shïp.Flags` 0x0100 and otherwise
    /// showed literal "Shields Down"; we show the armor % for every ship, since
    /// a bare "Shields Down" throws away the number the player is watching for.
    private var targetShieldArmorLine: String {
        model.targetShield > 0 ? "Shield \(Int(model.targetShield * 100))%"
                               : "Armor \(Int(model.targetArmor * 100))%"
    }

    /// The selected secondary weapon (EV Nova's status bar shows the *secondary*
    /// here) with its ammo count appended — e.g. "Polaron Multi-Torp. - 7".
    /// Centered and bright when armed; a dim "No Secondary Weapon" otherwise.
    private var weaponReadout: some View {
        VStack(spacing: 1) {
            if !model.weaponName.isEmpty {
                Text(weaponLabel).novaFont(.hud, weight: .semibold, size: statusSize)
                    .foregroundStyle(color(style.intf.brightText))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            } else {
                Text("No Secondary Weapon").novaFont(.hud, size: subtitleSize)
                    .foregroundStyle(color(style.intf.dimText))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// The secondary weapon name plus its remaining ammo, inline in EV Nova's
    /// "Name - N" form (no suffix for unlimited-ammo weapons).
    private var weaponLabel: String {
        model.weaponAmmo >= 0 ? "\(model.weaponName) - \(model.weaponAmmo)" : model.weaponName
    }

    /// The nav computer's rect (`ïntf.NavArea` — the real "navigation display"
    /// per the Bible): the plotted hyperspace destination and its jump count,
    /// centered, bright when a course is set; a dim "No Destination" otherwise.
    /// (The ship name/system that used to live here overflowed the box — that
    /// data belongs to the info/status screens, not the flight HUD, which
    /// matches the original, whose nav box shows only the destination.)
    private var navReadout: some View {
        VStack(spacing: 1) {
            if !model.navCourseSystemName.isEmpty {
                // Grayed while too close to the system's centre to actually engage
                // hyperspace right now — the same "fly further out" nudge the
                // no-jump-zone distance gate enforces, given a visual cue here.
                Text(model.navCourseSystemName)
                    .novaFont(.hud, weight: .semibold, size: statusSize)
                    .foregroundStyle(color(model.canJumpNow ? style.intf.brightText : style.intf.dimText))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Text("\(model.navCourseJumps) jump\(model.navCourseJumps == 1 ? "" : "s")")
                    .novaFont(.hud, size: subtitleSize).monospacedDigit()
                    .foregroundStyle(color(style.intf.dimText))
            } else {
                Text("No Destination").novaFont(.hud, size: subtitleSize)
                    .foregroundStyle(color(style.intf.dimText))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// EV Nova's bottom status readout (`ïntf.CargoArea`): free cargo space up
    /// top ("Free: N") and the credit balance below ("Credits:" / abbreviated
    /// value), centered, with the labels dim and the values bright.
    private var cargoReadout: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Text("Free:").novaFont(.hud, size: subtitleSize)
                    .foregroundStyle(color(style.intf.dimText))
                Text("\(max(0, model.cargoCapacity - model.cargoUsed))")
                    .novaFont(.hud, weight: .semibold, size: statusSize).monospacedDigit()
                    .foregroundStyle(color(style.intf.brightText))
            }
            Spacer(minLength: 2)
            VStack(spacing: 1) {
                Text("Credits:").novaFont(.hud, size: subtitleSize)
                    .foregroundStyle(color(style.intf.dimText))
                Text(model.credits.creditsAbbreviated)
                    .novaFont(.hud, weight: .semibold, size: statusSize).monospacedDigit()
                    .foregroundStyle(color(style.intf.brightText))
            }
            Spacer(minLength: 2)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
    private func color(_ c: NovaColor) -> Color { novaSwiftUIColor(c) }
}

/// A decoded `ïntf` colour as a SwiftUI `Color`, optionally scaled toward black
/// by `brightness` (1 = as authored, 0.5 = half-intensity) — used both for the
/// HUD readouts and to derive the radar's dimmed "disabled" contact tone from
/// the theme's `dimRadar` without needing a third stored colour.
fileprivate func novaSwiftUIColor(_ c: NovaColor, brightness: Double = 1) -> Color {
    Color(red: Double(c.r) / 255 * brightness,
          green: Double(c.g) / 255 * brightness,
          blue: Double(c.b) / 255 * brightness)
}

/// Radar contacts + player heading, drawn in the placed radar rect's local space.
/// Stellars are the larger dots, ships the small ones. Colours come straight
/// from the theme's two `ïntf` radar colours so a plug-in reskin fully applies:
/// hostiles take `brightRadar` (the same hue as the player marker), everything
/// else `dimRadar`, and disabled/non-functional contacts a dimmed `dimRadar`.
private struct RadarContactsView: View {
    @ObservedObject var model: GameHUDModel
    let brightRadar: NovaColor
    let dimRadar: NovaColor

    private var playerMarker: Color { novaSwiftUIColor(brightRadar) }

    /// Map a contact's relationship onto the theme's two radar colours. EV Nova's
    /// scope is a two-tone display: the alert colour for hostiles, the base
    /// colour for the rest — with disabled/dead contacts dimmed further so they
    /// read as inert rather than as a live neutral.
    private func radarColor(_ rel: RadarRelationship) -> Color {
        switch rel {
        case .hostile:                    return novaSwiftUIColor(brightRadar)
        case .friendlyOrOwned, .neutral:  return novaSwiftUIColor(dimRadar)
        case .disabled:                   return novaSwiftUIColor(dimRadar, brightness: 0.5)
        }
    }

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
                // The locked/selected contact blinks a bright white ring on top of
                // its own dot, driven independently of the HUD's own refresh rate —
                // same `TimelineView` idiom as the galaxy map's blinking markers.
                TimelineView(.periodic(from: .now, by: 0.35)) { timeline in
                    let blinkOn = Int(timeline.date.timeIntervalSinceReferenceDate / 0.35) % 2 == 0
                    Canvas { ctx, _ in
                        // Stellar objects: hollow ring outlines (EV Nova draws worlds
                        // as circles, distinct from the small filled ship dots).
                        for b in model.planetBlips {
                            let d = radarPlanetBlipDiameter(worldRadius: b.worldRadius)
                            let r = CGRect(x: cx + b.x * radius - d / 2, y: cy + b.y * radius - d / 2, width: d, height: d)
                            ctx.stroke(Path(ellipseIn: r), with: .color(radarColor(b.relationship)), lineWidth: 1)
                            if b.isTarget && blinkOn {
                                let ring = r.insetBy(dx: -2.5, dy: -2.5)
                                ctx.stroke(Path(ellipseIn: ring), with: .color(.white), lineWidth: 1.4)
                            }
                        }
                        // Ships: small filled dots. A co-op player keeps their own
                        // colour + name so they stand out from the two-tone scope.
                        for b in model.blips {
                            if let pc = b.playerColor {
                                let r = CGRect(x: cx + b.x * radius - 2, y: cy + b.y * radius - 2, width: 4, height: 4)
                                ctx.fill(Path(ellipseIn: r), with: .color(pc))
                                if let name = b.playerName {
                                    ctx.draw(Text(name).font(.system(size: 6, weight: .bold)).foregroundColor(pc),
                                             at: CGPoint(x: cx + b.x * radius, y: cy + b.y * radius - 6))
                                }
                                continue
                            }
                            let r = CGRect(x: cx + b.x * radius - 1, y: cy + b.y * radius - 1, width: 2, height: 2)
                            ctx.fill(Path(ellipseIn: r), with: .color(radarColor(b.relationship)))
                            if b.isTarget && blinkOn {
                                let ring = r.insetBy(dx: -2.5, dy: -2.5)
                                ctx.stroke(Path(ellipseIn: ring), with: .color(.white), lineWidth: 1.4)
                            }
                        }
                    }
                }
                .clipShape(Circle())   // contacts scroll off the rim, never pile on it
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
