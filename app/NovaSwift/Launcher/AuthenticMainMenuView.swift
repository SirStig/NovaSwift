import SwiftUI
import NovaSwiftKit
import NovaSwiftStory

/// The authentic EV Nova main menu, rendered from the player's own assets: the
/// full-screen background picture (PICT 8000), the game logo (rlëD 8010) and the
/// six real menu buttons (rlëD 8050–8055, each with an up + highlighted frame),
/// placed at the exact coordinates the game's data defines. Reached from the
/// port's native launcher via "Play".
enum MainMenuAction: CaseIterable { case newPilot, openPilot, enterShip, setPrefs, aboutNova, quitNova }

struct MainMenuAssets {
    struct ButtonArt {
        let action: MainMenuAction
        let normal: CGImage
        let pressed: CGImage
        let size: CGSize
        /// Top-left position in the 1024×768 design space (from the cölr resource).
        let origin: CGPoint
        /// This button's frame from the main-screen rollover sheet (spïn 607) —
        /// shown centred at cölr's `rollover` anchor while the button is hovered.
        let rolloverIcon: CGImage?
    }
    /// One of the three animated shutter strips that slide across the main
    /// menu's button rows (`cölr` Slide1-3 + `spïn` 608/609/610, whose PICTs are
    /// literally named "Slide upper/middle/lower").
    struct SlideStrip {
        /// Vertically-stacked frames, in play order: frame 0 is the retracted
        /// state — which matches backdrop PICT 8000 exactly, so the strip starts
        /// invisible against it — and the last frame is fully extended.
        let frames: [CGImage]
        /// Top-left position in the 1024×768 design space (`cölr` Slide1-3).
        let origin: CGPoint
        let size: CGSize
    }

    let background: CGImage?
    let logo: CGImage?
    let logoSize: CGSize
    let buttons: [ButtonArt]
    /// The three sliding shutter strips, top to bottom. Empty when the data
    /// doesn't supply them (a plug-in/TC with no `spïn` 608-610).
    /// The player data's live cölr #128 resource (colors, fonts, button/logo
    /// layout) — nil only if the resource is missing, in which case callers fall
    /// back to hand-coded values that mirror the base game's cölr contents.
    let colr: ColrRes?
    /// The main-screen rollover sheet's 7th frame — the gold "ATMOS" wordmark —
    /// shown at rest when no button is hovered.
    let slides: [SlideStrip]
    let rolloverDefault: CGImage?
    let rolloverSize: CGSize

    // Fallback button top-left positions, used only when `game.colr()` can't be
    // decoded — matches cölr #128's Button1X/Y..Button6X/Y in the base game
    // (spïn 600–605 order: two columns of three — New/Open/Quit and
    // Enter/Prefs/About).
    private static let fallbackPositions: [CGPoint] = [
        CGPoint(x: 349, y: 400), CGPoint(x: 344, y: 464), CGPoint(x: 345, y: 528),
        CGPoint(x: 555, y: 401), CGPoint(x: 581, y: 464), CGPoint(x: 580, y: 528),
    ]
    /// Fallback shutter-strip anchors — cölr #128's Slide1X/Y..Slide3X/Y. Each
    /// sits within a pixel or two of the matching left-column button row above,
    /// which is what identifies them as that row's backing plate.
    private static let fallbackSlideAnchors: [CGPoint] = [
        CGPoint(x: 343, y: 399), CGPoint(x: 337, y: 462), CGPoint(x: 337, y: 526),
    ]

    static func load(_ game: NovaGame?) -> MainMenuAssets? {
        guard let game else { return nil }
        let colr = game.colr()
        let positions = colr?.buttonPositions ?? fallbackPositions
        func rle(_ id: Int) -> SpriteSheet? {
            guard let d = game.resources.resource(NovaType.rleD, id)?.data else { return nil }
            return try? RLED.decode(d)
        }
        func pict(_ id: Int) -> CGImage? {
            guard let d = game.resources.resource(NovaType.pict, id)?.data,
                  let s = PICT.decodeLogged(d, id: id) else { return nil }
            return s.makeCGImage()
        }

        // Main-screen rollover images (spïn 607 → rlëD 8020 in the base game): a
        // 7-frame sheet of red silhouette icons, one per button in the same
        // Button1..6 order as cölr's buttonPositions/spïn 600-605 (frame 2 is a
        // literal "EXIT" icon, which lines up exactly with the Quit button at
        // index 2 — confirming the ordering), plus a 7th frame that's the gold
        // "ATMOS" wordmark shown when nothing is hovered.
        var rolloverFrames: [CGImage] = []
        var rolloverSize = CGSize(width: 136, height: 98)
        if let sheet = game.spinSheet(607) {
            rolloverFrames = sheet.frameCGImages(0..<sheet.frameCount).map(\.image)
            rolloverSize = CGSize(width: sheet.frameWidth, height: sheet.frameHeight)
        }

        // Menu buttons are spïn 600-605 (0x004ad960), each an rlëD or PICT sheet.
        let specs: [(MainMenuAction, Int)] = [
            (.newPilot, 600), (.openPilot, 601), (.quitNova, 602),
            (.enterShip, 603), (.setPrefs, 604), (.aboutNova, 605),
        ]
        var buttons: [ButtonArt] = []
        for (i, spec) in specs.enumerated() {
            guard let sheet = game.spinSheet(spec.1) else { continue }
            // Normal (frame 0) + pressed (frame 1) from one grid build, not two.
            let pair = sheet.frameCGImages(0...1)
            guard let n = pair.first(where: { $0.index == 0 })?.image,
                  let p = pair.first(where: { $0.index == 1 })?.image else { continue }
            buttons.append(.init(action: spec.0, normal: n, pressed: p,
                                 size: CGSize(width: sheet.frameWidth, height: sheet.frameHeight),
                                 origin: positions[min(i, positions.count - 1)],
                                 rolloverIcon: i < rolloverFrames.count ? rolloverFrames[i] : nil))
        }
        guard !buttons.isEmpty else { return nil }

        // Logo: spïn 606 ("Main screen logo") → sprite id. In EV Nova's data this
        // is a PICT sheet of 7 stacked frames (654×209 each); we take the last
        // frame (the settled logo). Some data may store it as rlëD instead.
        var logo: CGImage?
        var logoSize = CGSize.zero
        if let spin = game.spin(606) {
            let tileW = spin.tileWidth, tileH = spin.tileHeight
            if let sheet = rle(spin.spriteID), let f = sheet.frameCGImage(0) {
                logo = f
                logoSize = CGSize(width: sheet.frameWidth, height: sheet.frameHeight)
            } else if let full = pict(spin.spriteID) {
                let w = tileW > 0 ? min(tileW, full.width) : full.width
                let h = tileH > 0 ? min(tileH, full.height) : full.height
                let lastFrame = max(0, spin.tilesDown - 1)
                let y = min(lastFrame * h, max(0, full.height - h))
                // Keep the RAW opaque frame — the logo sheet bakes its own
                // starfield + nebula glow around the letters, all on black. It's
                // composited with a `.screen` blend (see the view), where the
                // near-black background adds nothing and only the glow/letters
                // lift over the menu's own backdrop. Keying black out instead
                // left the logo's baked stars to *replace* the backdrop in a
                // 654×209 rectangle — the mismatched-brightness box that read as
                // "the logo is a different brightness than the rest of the UI".
                logo = full.cropping(to: CGRect(x: 0, y: y, width: w, height: h)) ?? full
                logoSize = CGSize(width: logo?.width ?? w, height: logo?.height ?? h)
            }
        }

        // The three sliding shutter strips (`spïn` 608/609/610 → PICT 8030/8031/
        // 8032, named "Slide upper/middle/lower" in the data). Each is a single
        // tall PICT holding `tilesDown` frames stacked vertically — 11/10/11
        // frames of 338×63, 351×64 and 351×65 respectively in the base game —
        // and each is positioned by one of `cölr`'s Slide1-3 anchors, which sit
        // within a pixel or two of the button rows they belong to.
        //
        // They render as a one-shot flourish when the menu appears: frame 0 is
        // the strip retracted (visually identical to backdrop PICT 8000 at those
        // coordinates, which is how we know it's the start of the run, not the
        // end) and the panels slide inward from both edges to their resting
        // extent. Drawn beneath the buttons, so the buttons land on top of their
        // finished backing plates.
        var slides: [MainMenuAssets.SlideStrip] = []
        let slideAnchors: [CGPoint] = colr.map { [$0.slide1, $0.slide2, $0.slide3] }
            ?? Self.fallbackSlideAnchors
        for (i, spinID) in [608, 609, 610].enumerated() {
            guard let spin = game.spin(spinID) else { continue }
            var frames: [CGImage] = []
            var frameSize = CGSize(width: spin.tileWidth, height: spin.tileHeight)
            if let sheet = rle(spin.spriteID) {
                frames = sheet.frameCGImages(0..<sheet.frameCount).map(\.image)
                frameSize = CGSize(width: sheet.frameWidth, height: sheet.frameHeight)
            } else if let full = pict(spin.spriteID) {
                let w = spin.tileWidth > 0 ? min(spin.tileWidth, full.width) : full.width
                let h = spin.tileHeight > 0 ? min(spin.tileHeight, full.height) : full.height
                guard h > 0 else { continue }
                let count = spin.tilesDown > 0 ? spin.tilesDown : full.height / max(1, h)
                frames = (0..<count).compactMap { row in
                    full.cropping(to: CGRect(x: 0, y: row * h, width: w, height: h))
                }
                frameSize = CGSize(width: w, height: h)
            }
            guard !frames.isEmpty else { continue }
            slides.append(.init(frames: frames,
                                origin: slideAnchors[min(i, slideAnchors.count - 1)],
                                size: frameSize))
        }

        return MainMenuAssets(background: pict(8000), logo: logo, logoSize: logoSize, buttons: buttons, colr: colr,
                              slides: slides,
                              rolloverDefault: rolloverFrames.count > 6 ? rolloverFrames[6] : rolloverFrames.last,
                              rolloverSize: rolloverSize)
    }

}

struct AuthenticMainMenuView: View {
    @EnvironmentObject private var model: AppModel
    let assets: MainMenuAssets

    @State private var appeared = false
    @State private var sheet: Sheet?
    @State private var hoveredAction: MainMenuAction?
    /// How many frames of the shutter-strip run have played. Starts at 0 (the
    /// retracted state, pixel-identical to the backdrop) and counts up to each
    /// strip's last frame, where it rests.
    @State private var slideFrame = 0
    @State private var slideTimer: Timer?
    /// Frame cadence for the shutter run. `cölr` gives the strips a position but
    /// no delay — unlike `spöb`/`shän`, which carry an explicit `AnimDelay` — so
    /// this is the port's own choice: 1/20 s, which plays the base game's 10-11
    /// frame strips in about half a second. Quick enough to read as a flourish
    /// on entry rather than a loading delay.
    private static let slideFrameInterval: TimeInterval = 1.0 / 20.0
    private enum Sheet: String, Identifiable {
        case newPilot, openPilot, settings, about, plugins, importData
        var id: String { rawValue }
    }

    private let base = CGSize(width: 1024, height: 768)

    var body: some View {
        // The whole menu lives in EV Nova's 1024×768 design space via the shared
        // NovaCanvas — every element positions at exact game coordinates.
        NovaCanvas(design: base, fit: .fit) { layout in
            ZStack(alignment: .topLeading) {
                Color.black

                if let bg = assets.background {
                    Image(decorative: bg, scale: 1)
                        .resizable().interpolation(.medium)
                        .novaPlace(layout, x: 0, y: 0, w: base.width, h: base.height)
                }

                slideStrips(layout: layout)

                if let logo = assets.logo, assets.logoSize.height > 0 {
                    // The logo frame is not just the letters — it bakes in the
                    // surrounding title-screen region (the cockpit-frame edges,
                    // the starfield, the planet glow below) exactly as it sits in
                    // backdrop PICT 8000. It is therefore drawn **opaque at its
                    // authored LogoX/LogoY** (cölr #128 offsets 224–227), so its
                    // baked surroundings land pixel-on-pixel over 8000's matching
                    // art and only the logo itself reads as "added". Keying the
                    // black (leaves its own stars → a brighter box) or a `.screen`
                    // blend (double-exposes the shared chrome/planet) both broke
                    // that alignment; the fallback origin matches the base game's
                    // real LogoX/LogoY for when the cölr can't be decoded.
                    let logoOrigin = assets.colr?.logo
                        ?? CGPoint(x: (base.width - assets.logoSize.width) / 2, y: 162)
                    Image(decorative: logo, scale: 1)
                        .resizable().interpolation(.medium)
                        .novaPlace(layout,
                                   x: logoOrigin.x, y: logoOrigin.y,
                                   w: assets.logoSize.width, h: assets.logoSize.height)
                        // Only a fade — no scaleEffect, which would break the
                        // pixel-exact overlay and reveal a doubled seam.
                        .opacity(appeared ? 1 : 0)
                        .animation(.easeOut(duration: 0.6), value: appeared)
                }

                buttons(layout: layout)
                rolloverIndicator(layout: layout)
                pilotStatus(layout: layout)
                modernExtras   // port-added features not in the original menu
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .overlay { dialogOverlay }
        .onDisappear {
            slideTimer?.invalidate()
            slideTimer = nil
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true }
            startSlideAnimation()               // cölr Slide1-3 shutter flourish
            model.prepareAudioAndData()         // ensure main-menu background music is playing
        }
    }

    /// The active dialog, shown as a **full-screen overlay** rather than a macOS
    /// `.sheet`. A sheet renders a fixed-size centred card; our `NovaDialog`/
    /// `DialogChrome` already fill their surface with the dimmed title-screen
    /// backdrop, so a sheet card just doubled the panel ("an extra view behind
    /// it"). As an overlay the backdrop fills the window and only the metal
    /// panel floats over the menu — exactly like the in-game spaceport dialogs.
    @ViewBuilder private var dialogOverlay: some View {
        if let which = sheet {
            Group {
                switch which {
                case .newPilot:   NewPilotView(onClose: { sheet = nil })
                case .openPilot:  PilotListView(onClose: { sheet = nil })
                case .settings:   SettingsView(onClose: { sheet = nil })
                case .about:
                    // About Nova (`Menu_RunAboutNovaDialog` 0x00486120): the
                    // data's own dësc 32767 in the generic dësc dialog. The
                    // port's About is under Settings > Support.
                    if let game = model.data.game, let desc = game.desc(32767) {
                        DescTextDialog(title: "", text: game.descText(32767),
                                       graphicID: desc.pictureID, onClose: { sheet = nil })
                    } else {
                        AboutView(onClose: { sheet = nil })
                    }
                case .plugins:    PluginsView(onClose: { sheet = nil })
                case .importData: DataSetupWizard(onClose: { sheet = nil }, startAtImport: true)
                }
            }
            .transition(.opacity)
            .preferredColorScheme(.dark)
        }
    }

    /// The loaded-pilot readout, drawn as the original's main-menu redraw
    /// (`FUN_004873b0`) draws it: STR# 2002 labels in cölr MenuColor2 and values
    /// in MenuColor1, in the cölr menu font, at fixed offsets from the menu
    /// centre (see `MainMenuReadout`), with the ship's targeting PICT
    /// (3000 + class) composited additively below the centre knob. A killed
    /// pilot shows "<name> has been killed" (or the Kenny line); with no pilot
    /// loaded the menu shows STR# 2002 #276 once the bottom shutter has landed,
    /// and #275 while a new pilot is being created.
    @ViewBuilder private func pilotStatus(layout: NovaLayout) -> some View {
        let bright = assets.colr.map { color($0.menuColor1) } ?? novaAmber
        let dim = assets.colr.map { color($0.menuColor2) } ?? novaAmber.opacity(0.55)
        let cx = base.width / 2, cy = base.height / 2
        let fontSize = CGFloat(assets.colr.map { $0.menuFontSize > 0 ? $0.menuFontSize : 9 } ?? 9)
        let game = model.data.game

        if sheet == .newPilot {
            centredLine(s2002(MainMenuReadout.creatingPilotString), dim, fontSize, layout)
        } else if let save = model.roster.selected {
            if model.killedPilotID == save.id {
                centredLine(MainMenuReadout.killedLine(pilotName: save.displayName,
                                                       killedText: s2002(MainMenuReadout.killedString)),
                            dim, fontSize, layout)
            } else {
                ForEach(Array(MainMenuReadout.lines.enumerated()), id: \.offset) { _, line in
                    readoutText(lineText(line, save: save, game: game), lineIsLabel(line) ? dim : bright, fontSize,
                                x: cx + CGFloat(line.dx), baseline: cy + CGFloat(line.baselineDY), layout)
                }
                if let pict = targetingPict(shipType: save.player.shipType) {
                    Image(decorative: pict, scale: 1)
                        .resizable().interpolation(.none)
                        // Transfer mode 0x22 (addOver): the black ground adds nothing.
                        .blendMode(.plusLighter)
                        .novaPlace(layout, x: cx - CGFloat(pict.width / 2),
                                   y: cy + CGFloat(MainMenuReadout.shipPictTopDY),
                                   w: CGFloat(pict.width), h: CGFloat(pict.height))
                }
            }
        } else if slideSettled(2) {
            centredLine(s2002(MainMenuReadout.noPilotString), dim, fontSize, layout)
        }
    }

    private func s2002(_ i: Int) -> String { model.data.game?.stringList(2002)?.string(at: i) ?? "" }

    /// One readout string with its baseline at `baseline` (the original's text
    /// draw puts the glyph box top at baseline − font size).
    private func readoutText(_ text: String, _ colour: Color, _ size: CGFloat,
                             x: CGFloat, baseline: CGFloat, _ layout: NovaLayout) -> some View {
        Text(text)
            .font(.custom(assets.colr?.menuFont.isEmpty == false ? assets.colr!.menuFont : NovaFontRole.body.family,
                          size: size * layout.scale))
            .foregroundStyle(colour)
            .lineLimit(1)
            .fixedSize()
            .frame(width: layout.length(400), height: layout.length(size * 1.5), alignment: .topLeading)
            .position(layout.point(x + 200, baseline - size + size * 0.75))
    }

    /// A line centred between centre ∓ 150 at baseline centre + 0x136.
    private func centredLine(_ text: String, _ colour: Color, _ size: CGFloat,
                             _ layout: NovaLayout) -> some View {
        let half = CGFloat(MainMenuReadout.centredLineHalfWidth)
        let baseline = base.height / 2 + CGFloat(MainMenuReadout.centredLineBaselineDY)
        return Text(text)
            .font(.custom(assets.colr?.menuFont.isEmpty == false ? assets.colr!.menuFont : NovaFontRole.body.family,
                          size: size * layout.scale))
            .foregroundStyle(colour)
            .lineLimit(1)
            .fixedSize()
            .frame(width: layout.length(half * 2), height: layout.length(size * 1.5))
            .position(layout.point(base.width / 2, baseline - size + size * 0.75))
    }

    private func lineText(_ line: MainMenuReadout.Line, save: PilotSave, game: NovaGame?) -> String {
        switch line.kind {
        case .label(let i): return s2002(i)
        case .value(let f): return readoutValue(f, save: save, game: game)
        }
    }

    private func lineIsLabel(_ line: MainMenuReadout.Line) -> Bool {
        if case .label = line.kind { return true }
        return false
    }

    private func readoutValue(_ field: MainMenuReadout.Line.Field, save: PilotSave, game: NovaGame?) -> String {
        let ship = game?.ship(save.player.shipType)
        switch field {
        case .pilotName:    return save.displayName
        case .shipName:     return save.snapshot.shipName
        case .shipClass:    return ship?.displayName ?? ""
        case .shipSubtitle: return ship?.subtitle ?? ""
        case .combatRating: return game.map { OriginalText(game: $0).combatRating(save.player.combatRating) } ?? save.snapshot.ratingTitle
        case .legalStatus:  return legalStatusText(save, game: game)
        case .date:
            let d = save.player.date
            let ch = game?.startingChar()
            let str137 = game?.stringList(137)
            return MainMenuReadout.date(day: d.day, month: d.month, year: d.year,
                                        prefix: ch?.datePrefix ?? "", suffix: ch?.dateSuffix ?? "",
                                        str137: { str137?.string(at: $0) })
        }
    }

    /// The "legal status in current system" value
    /// (`NovaUi_DrawSystemFactionConflictStatus` 0x00468d90, gated by
    /// `System_HasUsableTravelDestination` 0x00468af0): the STR# 134 name for the
    /// record against the system government's crime tolerance, overridden by
    /// dominated stellars; "N/A" (STR# 2002 #396) in a system with no usable
    /// stellar or under a xenophobic government.
    private func legalStatusText(_ save: PilotSave, game: NovaGame?) -> String {
        guard let game else { return "" }
        return LegalStatus.label(inSystem: save.player.currentSystem, player: save.player, game: game)
    }

    /// The ship's targeting PICT: 3000 + (class − 128), or — when the class has
    /// none — the one of the earlier class whose hull sprite it shares
    /// (`FUN_004aeda0`).
    private func targetingPict(shipType id: Int) -> CGImage? {
        guard let game = model.data.game, let graphics = model.uiGraphics else { return nil }
        if game.resources.resource(NovaType.pict, 3000 + id - 128) != nil {
            return graphics.pict(3000 + id - 128)
        }
        guard let base = game.shan(id)?.baseSpriteID,
              let donor = game.ships().map(\.id).sorted()
                .first(where: { $0 < id && game.shan($0)?.baseSpriteID == base }),
              game.resources.resource(NovaType.pict, 3000 + donor - 128) != nil
        else { return nil }
        return graphics.pict(3000 + donor - 128)
    }

    /// Whether shutter strip `index` has reached its last frame (or there is
    /// no such strip).
    private func slideSettled(_ index: Int) -> Bool {
        guard index < assets.slides.count else { return true }
        return slideFrame >= assets.slides[index].frames.count - 1
    }

    /// The three sliding shutter strips (`cölr` Slide1-3 / `spïn` 608-610),
    /// drawn between the backdrop and the buttons so each row's panels settle
    /// underneath the button that sits on them.
    ///
    /// Each strip holds at its own last frame once the run finishes, so a strip
    /// with fewer frames than its neighbours (the base game's middle strip has
    /// 10 against the others' 11) simply arrives a frame earlier rather than
    /// looping or snapping back.
    @ViewBuilder private func slideStrips(layout: NovaLayout) -> some View {
        ForEach(Array(assets.slides.enumerated()), id: \.offset) { _, strip in
            let idx = min(slideFrame, strip.frames.count - 1)
            Image(decorative: strip.frames[idx], scale: 1)
                .resizable().interpolation(.medium)
                .novaPlace(layout, x: strip.origin.x, y: strip.origin.y,
                           w: strip.size.width, h: strip.size.height)
        }
    }

    /// Run the shutter strips once, from retracted to their resting extent.
    /// Idempotent: re-entering the menu restarts the run from frame 0.
    private func startSlideAnimation() {
        slideTimer?.invalidate()
        let last = assets.slides.map(\.frames.count).max().map { $0 - 1 } ?? 0
        guard last > 0 else { return }
        slideFrame = 0
        // Each strip plays snd 602 as it starts and 603 as it lands (`FUN_0048bfb0`).
        let landings = assets.slides.map { $0.frames.count - 1 }
        for _ in landings { model.audio.playMenuSlide(landed: false) }
        slideTimer = Timer.scheduledTimer(withTimeInterval: Self.slideFrameInterval,
                                          repeats: true) { timer in
            Task { @MainActor in
                slideFrame += 1
                for landing in landings where landing == slideFrame { model.audio.playMenuSlide(landed: true) }
                if slideFrame >= last {
                    slideFrame = last
                    timer.invalidate()
                    slideTimer = nil
                }
            }
        }
    }

    /// The main menu's centre indicator, at cölr's real `RolloverX`/`RolloverY`
    /// anchor (fallback (444, 465) matches the base game's real cölr #128
    /// values) — the gold "ATMOS" wordmark at rest, swapping to the hovered
    /// button's red silhouette icon (spïn 607) with a crossfade + scale-in as
    /// the pointer moves between buttons.
    @ViewBuilder private func rolloverIndicator(layout: NovaLayout) -> some View {
        let origin = assets.colr?.rollover ?? CGPoint(x: 444, y: 465)
        let size = assets.rolloverSize
        ZStack {
            if let icon = currentRolloverIcon {
                Image(decorative: icon, scale: 1)
                    .resizable().interpolation(.medium)
                    .transition(.opacity.combined(with: .scale(scale: 0.82)))
                    .id(hoveredAction)
            }
        }
        .animation(.easeOut(duration: 0.15), value: hoveredAction)
        .novaPlace(layout, x: origin.x, y: origin.y, w: size.width, h: size.height)
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.4).delay(0.55), value: appeared)
    }

    private var currentRolloverIcon: CGImage? {
        guard let hoveredAction, let art = assets.buttons.first(where: { $0.action == hoveredAction })
        else { return assets.rolloverDefault }
        return art.rolloverIcon ?? assets.rolloverDefault
    }

    /// `NovaColor` (the `cölr` resource's raw 0x00RRGGBB fields) as a SwiftUI
    /// `Color` — same conversion AuthenticHUDView.swift uses for `IntfRes` colors.
    private func color(_ c: NovaColor) -> Color {
        Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }

    /// Modern, port-only affordances (features EV Nova never had): the plug-in
    /// manager. Kept visually distinct from the game's own buttons, tucked in the
    /// bottom-left so it doesn't intrude on the authentic menu. (Flight Training
    /// and Import Data now live in Settings.)
    private var modernExtras: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                // Flight Training and Import Data moved into Settings (this menu
                // only appears once base data is present).
                extraButton("Plug-ins", "puzzlepiece.extension.fill") { sheet = .plugins }
                Spacer()
            }
            .padding(.leading, 20)
            .padding(.bottom, 18)
        }
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.4).delay(0.5), value: appeared)
    }

    private func extraButton(_ label: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        CursorButton { model.audio.play(.uiSelect); action() } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(label).font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        }
        .foregroundStyle(.white.opacity(0.85))
    }

    private func buttons(layout: NovaLayout) -> some View {
        ForEach(Array(assets.buttons.enumerated()), id: \.offset) { i, art in
            MenuSpriteButton(art: art,
                             onHoverChange: { isHovering in
                                 if isHovering {
                                     hoveredAction = art.action
                                 } else if hoveredAction == art.action {
                                     hoveredAction = nil
                                 }
                             },
                             action: { activate(art.action) })
                .novaPlace(layout, origin: art.origin, size: art.size)
                // The original blits each menu button only once the shutter
                // strip of its row has finished sliding.
                .opacity(slideSettled(MainMenuReadout.slideIndex(forButton: i)) ? 1 : 0)
                .allowsHitTesting(slideSettled(MainMenuReadout.slideIndex(forButton: i)))
        }
    }

    /// A menu command plays snd 600, waits for it, plays snd 601, then acts
    /// (`FUN_0048bc20`).
    private func activate(_ action: MainMenuAction) {
        model.audio.playMenuTransition { perform(action) }
    }

    private func perform(_ action: MainMenuAction) {
        switch action {
        case .newPilot: sheet = .newPilot
        case .openPilot: sheet = .openPilot
        case .enterShip:
            // Resume the loaded pilot; if there's no unambiguous one to resume
            // (none selected, or several pilots and no explicit choice), open the
            // picker instead of silently grabbing the newest save.
            if !model.enterShip() { sheet = .openPilot }
        case .setPrefs: sheet = .settings
        case .aboutNova: sheet = .about
        case .quitNova:
            #if os(macOS)
            NSApplication.shared.terminate(nil)
            #endif
        }
    }
}

/// A button whose face is a real EV Nova sprite: the up frame normally, the
/// highlighted frame on hover (rollover) or press.
private struct MenuSpriteButton: View {
    let art: MainMenuAssets.ButtonArt
    var onHoverChange: (Bool) -> Void = { _ in }
    let action: () -> Void
    @State private var hovering = false
    @State private var pressing = false

    // The button is sized/positioned by novaPlace; the resizable image fills it.
    var body: some View {
        let highlighted = hovering || pressing
        Image(decorative: highlighted ? art.pressed : art.normal, scale: 1)
            .resizable().interpolation(.medium)
            .scaleEffect(pressing ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: highlighted)
            .contentShape(Rectangle())
            // Controller cursor presses these on every platform — on tvOS
            // it's the only pointer there is.
            .cursorClickable(action)
            #if !os(tvOS)
            .onHover { h in
                hovering = h
                onHoverChange(h)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressing = true }
                    .onEnded { _ in pressing = false; action() }
            )
            #endif
    }
}
