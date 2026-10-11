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
            // ïntf font sizes are used exactly as given, in the status bar's
            // own pixels: scale them with the canvas like the chrome.
            .novaTextScale(layout.scale)
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
        // Whole-jump portion, then the sub-jump remainder butted against it.
        if fullFrac > 0 { segment(layout, r, from: 0, to: fullFrac, style.intf.fuelFull) }
        if partialFrac > 0 { segment(layout, r, from: fullFrac, to: frac, style.intf.fuelPartial) }
    }

    /// A status bar filled to `value` (0…1) from its rect's anchored end
    /// (0x0045ea66 / 0x0045ebe8).
    private func bar(_ layout: NovaLayout, _ r: NovaRect, _ value: Double, _ c: NovaColor) -> some View {
        segment(layout, r, from: 0, to: min(1, max(0, value)), c)
    }

    /// The part of a bar rect between fractions `a` and `b` of its length.
    /// The original fills a wide rect from the left and a tall one (height
    /// ≥ width) from the bottom, in whole pixels.
    private func segment(_ layout: NovaLayout, _ r: NovaRect, from a: Double, to b: Double, _ c: NovaColor) -> some View {
        let w = CGFloat(r.width), h = CGFloat(r.height)
        let tall = h >= w
        let len = tall ? h : w
        let start = (len * CGFloat(a)).rounded(.down), end = (len * CGFloat(b)).rounded(.down)
        let size = max(0, end - start)
        return Rectangle().fill(color(c))
            .novaPlace(layout,
                       x: tall ? CGFloat(r.left) : CGFloat(r.left) + start,
                       y: tall ? CGFloat(r.top) + h - end : CGFloat(r.top),
                       w: tall ? w : size, h: tall ? size : h)
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
                    // The original panel has no hostility colour (UI-10).
                    .foregroundStyle(color(style.intf.brightText))
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
                // The original status row (UI-10): "Shield:"/"Armor:" N %, or
                // "Shields Down" / "No Shields" / "Disabled" / "Waiting", with
                // the TargetCode (or "Escort"/"Fighter") on the right. Hulls
                // with shïp Flags 0x0200 (or a përs with negative ShieldMod)
                // show only the TargetCode, centred.
                if model.targetHidesShieldArmorLine {
                    Text(model.targetCode).novaFont(.hud, size: subtitleSize)
                        .foregroundStyle(color(style.intf.dimText))
                        .frame(maxWidth: .infinity)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if !model.targetStatusLabel.isEmpty {
                            Text(model.targetStatusLabel).novaFont(.hud, size: subtitleSize)
                                .foregroundStyle(color(style.intf.dimText))
                        }
                        Text(model.targetStatusValue)
                            .novaFont(.hud, weight: .semibold, size: subtitleSize).monospacedDigit()
                            .foregroundStyle(color(style.intf.brightText))
                        Spacer(minLength: 0)
                        if !model.targetCode.isEmpty {
                            Text(model.targetCode).novaFont(.hud, size: subtitleSize)
                                .foregroundStyle(color(style.intf.dimText))
                        }
                    }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            // Planets are never drawn here in the original (UI-10).
            Text(model.noTargetText).novaFont(.hud, size: subtitleSize)
                .foregroundStyle(color(style.intf.dimText))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    /// EV Nova draws the target silhouette in red, the same for every contact
    /// (the original panel carries no hostility colour).
    private var targetTint: Color { Color(red: 0.85, green: 0.34, blue: 0.28) }

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
            if !model.navTitle.isEmpty {
                // The original's three states (0x0045e400; UI-10): "Hyperspace"
                // + the armed next hop, "Stellar Navigation" + the selected
                // stellar, or "Nav System Off".
                Text(model.navTitle).novaFont(.hud, size: subtitleSize)
                    .foregroundStyle(color(style.intf.dimText))
                if !model.navName.isEmpty {
                    Text(model.navName)
                        .novaFont(.hud, weight: .semibold, size: statusSize)
                        .foregroundStyle(color(model.navNameDim ? style.intf.dimText : style.intf.brightText))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                }
            } else if !model.navCourseSystemName.isEmpty {
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
            // One row per commodity aboard (0x004612c0), then Free (the
            // fleet's room) and, with mission cargo or junk, Special.
            ForEach(Array(model.cargoByCommodity.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    Text(row.name).novaFont(.hud, size: subtitleSize)
                        .foregroundStyle(color(style.intf.dimText))
                    Spacer(minLength: 2)
                    Text("\(row.tons)").novaFont(.hud, size: subtitleSize).monospacedDigit()
                        .foregroundStyle(color(style.intf.brightText))
                }
            }
            HStack(spacing: 4) {
                Text("Free:").novaFont(.hud, size: subtitleSize)
                    .foregroundStyle(color(style.intf.dimText))
                Text("\(max(0, model.cargoCapacity - model.cargoUsed))")
                    .novaFont(.hud, weight: .semibold, size: statusSize).monospacedDigit()
                    .foregroundStyle(color(style.intf.brightText))
            }
            if !model.cargoSpecial.isEmpty {
                HStack(spacing: 4) {
                    Text("Special:").novaFont(.hud, size: subtitleSize)
                        .foregroundStyle(color(style.intf.dimText))
                    Text(model.cargoSpecial).novaFont(.hud, size: subtitleSize)
                        .foregroundStyle(color(style.intf.brightText))
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            Spacer(minLength: 2)
            VStack(spacing: 1) {
                Text("Credits:").novaFont(.hud, size: subtitleSize)
                    .foregroundStyle(color(style.intf.dimText))
                Text(model.credits.creditsHUD)
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
    /// The sizes are the ïntf's own (`Ui_InstallGameplayInterfaceLayout`
    /// 0x004cda50 uses them unscaled); the canvas scale is applied through
    /// `novaTextScale` above, so they track the chrome at any window size.
    private var statusSize: CGFloat {
        (style.intf.statusFontSize > 0 ? CGFloat(style.intf.statusFontSize) : NovaFontRole.hud.baseSize)
    }
    private var subtitleSize: CGFloat {
        (style.intf.subtitleFontSize > 0 ? CGFloat(style.intf.subtitleFontSize) : NovaFontRole.hud.baseSize)
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
/// Stellars are the larger dots, ships the small ones. Without an IFF decoder
/// colours come straight from the theme's two `ïntf` radar colours so a plug-in
/// reskin fully applies: hostiles take `brightRadar` (the same hue as the player
/// marker), everything else `dimRadar`, and disabled/non-functional contacts a
/// dimmed `dimRadar`. An IFF decoder overrides both with allegiance colours —
/// see `radarColor`.
private struct RadarContactsView: View {
    @ObservedObject var model: GameHUDModel
    let brightRadar: NovaColor
    let dimRadar: NovaColor

    /// The player's own dot: BrightRadar, or IFF cyan (0,FFFF,FFFF) once an IFF
    /// is fitted — slot 0 goes through 0x00465f00 first (0x0045d600).
    private var playerMarker: Color {
        model.hasIFF ? Color(red: 0, green: 1, blue: 1) : novaSwiftUIColor(brightRadar)
    }

    /// Map a contact's relationship onto a colour. Without an IFF decoder the
    /// scope is the interface's own two-tone display: the alert colour for
    /// hostiles, the base colour for the rest — with disabled/dead contacts
    /// dimmed further so they read as inert rather than as a live neutral.
    ///
    /// With one fitted, the Bible's `ïntf` note applies — "having an IFF outfit
    /// will override these colors" — and every contact takes its allegiance
    /// colour instead (green friend / red hostile / blue neutral / grey hulk),
    /// the whole point of buying the thing. This used to be unconditional
    /// two-tone, so an IFF Decoder changed nothing on the authentic HUD.
    ///
    /// Without one, the original draws every contact in DimRadar and only the
    /// selected target blinks BrightRadar (OS-05).
    private func radarColor(_ rel: RadarRelationship, iff: Color? = nil) -> Color {
        if model.hasIFF { return iff ?? rel.color }
        return novaSwiftUIColor(dimRadar)
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
                TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
                    let blinkOn = Int(timeline.date.timeIntervalSinceReferenceDate / 0.25) % 2 == 0
                    Canvas { ctx, size in
                        // With an IFF the radar rect is filled black before
                        // the contacts (0x0045d0a0, L2); without one the
                        // interface PICT shows through.
                        if model.hasIFF {
                            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                        }
                        // Interference static (OS-05): this refresh shows only
                        // noise over the whole scope, no contacts.
                        if model.radarStatic {
                            if !model.radarPatterns.isEmpty {
                                if let cg = model.radarPatterns[128 + Int.random(in: 0..<10)] {
                                    let img = ctx.resolve(Image(decorative: cg, scale: 1))
                                    let w = CGFloat(cg.width), h = CGFloat(cg.height)
                                    var y: CGFloat = 0
                                    while y < size.height {
                                        var x: CGFloat = 0
                                        while x < size.width {
                                            ctx.draw(img, at: CGPoint(x: x, y: y), anchor: .topLeading)
                                            x += w
                                        }
                                        y += h
                                    }
                                }
                                return
                            }
                            for _ in 0..<Int(size.width * size.height / 12) {
                                let r = CGRect(x: .random(in: 0..<size.width), y: .random(in: 0..<size.height),
                                               width: 1, height: 1)
                                ctx.fill(Path(r), with: .color(novaSwiftUIColor(dimRadar)))
                            }
                            return
                        }
                        // Stellar objects: hollow ring outlines (EV Nova draws worlds
                        // as circles, distinct from the small filled ship dots).
                        for b in model.planetBlips {
                            let d = radarPlanetBlipDiameter(worldRadius: b.worldRadius)
                            let r = CGRect(x: cx + b.x * radius - d / 2, y: cy + b.y * radius - d / 2, width: d, height: d)
                            ctx.stroke(Path(ellipseIn: r), with: .color(radarColor(b.relationship, iff: b.iffColor)), lineWidth: 1)
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
                            let side: CGFloat = b.large ? 3 : 2
                            let r = CGRect(x: cx + b.x * radius - side / 2, y: cy + b.y * radius - side / 2,
                                           width: side, height: side)
                            if b.isTarget && !model.hasIFF {
                                // No IFF: the target alone blinks BrightRadar.
                                ctx.fill(Path(r), with: .color(novaSwiftUIColor(blinkOn ? brightRadar : dimRadar)))
                                continue
                            }
                            // With an IFF the target's dot alternates its IFF colour
                            // with BrightRadar (0x0045d600); no extra ring.
                            let dot: Color = (b.isTarget && blinkOn) ? novaSwiftUIColor(brightRadar)
                                                                     : radarColor(b.relationship, iff: b.iffColor)
                            ctx.fill(b.large ? Path(r) : Path(ellipseIn: r), with: .color(dot))
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
