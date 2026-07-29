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
                  let s = try? PICT.decode(d) else { return nil }
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
        if let rolloverSpin = game.spin(607), let sheet = rle(rolloverSpin.spriteID) {
            rolloverFrames = sheet.frameCGImages(0..<sheet.frameCount).map(\.image)
            rolloverSize = CGSize(width: sheet.frameWidth, height: sheet.frameHeight)
        }

        let specs: [(MainMenuAction, Int)] = [
            (.newPilot, 8050), (.openPilot, 8051), (.quitNova, 8052),
            (.enterShip, 8053), (.setPrefs, 8054), (.aboutNova, 8055),
        ]
        var buttons: [ButtonArt] = []
        for (i, spec) in specs.enumerated() {
            guard let sheet = rle(spec.1) else { continue }
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
            model.audio.play(.uiSelect)         // menu appears
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
                case .about:      AboutView(onClose: { sheet = nil })
                case .plugins:    PluginsView(onClose: { sheet = nil })
                case .importData: DataSetupWizard(onClose: { sheet = nil }, startAtImport: true)
                }
            }
            .transition(.opacity)
            .preferredColorScheme(.dark)
        }
    }

    /// The current-pilot/ship status readout for "Enter Ship" — a bright/dim
    /// two-tone line using the `cölr` resource's real `MenuColor1`/`MenuColor2`
    /// ("bright & dim colors for main menu") and Geneva, the game's real main
    /// menu font (`NovaFontRole.body`/`.caption`'s family — see NovaFont.swift).
    /// Drawn **directly on the backdrop's dark bottom band with no plate or
    /// border** — the bordered box it used to sit in read as a floating modern
    /// overlay and collided with the menu's centre knob. The readout itself is
    /// a port invention (the real menu has none), so it borrows the band the
    /// backdrop art leaves empty below the button columns. Falls back to the
    /// port's generic amber styling if the player's data has no cölr resource.
    @ViewBuilder private func pilotStatus(layout: NovaLayout) -> some View {
        // Shows the *selected* (loaded) pilot — the one Enter Ship will resume —
        // not merely the newest save, so the readout matches what happens next.
        if let save = model.roster.selected {
            let bright = assets.colr.map { color($0.menuColor1) } ?? novaAmber
            let dim = assets.colr.map { color($0.menuColor2) } ?? novaAmber.opacity(0.55)
            // Everything scales with the backdrop via `layout.scale`, so the
            // readout grows/shrinks as one piece with the window.
            let sc = layout.scale
            let game = model.data.game

            // The two field columns flank the red ship icon exactly as the
            // original main menu lays them out: Pilot Name / Ship Name / Ship
            // Class on the left, Legal Status / Combat Rating / Current Date on
            // the right — each a dim label above a bright value.
            HStack(alignment: .top, spacing: 14 * sc) {
                VStack(alignment: .leading, spacing: 7 * sc) {
                    infoField("Pilot Name", save.displayName, bright, dim, sc)
                    infoField("Ship Name", save.snapshot.shipName.isEmpty ? "—" : save.snapshot.shipName, bright, dim, sc)
                    infoField("Ship Class", game?.ship(save.player.shipType)?.displayName ?? "—", bright, dim, sc)
                }
                // Trailing, not leading: this box's far edge is away from the
                // ship icon, so anchoring the (internally left-aligned) text
                // block to the near/right edge instead keeps it flanking the
                // ship rather than pinned to the outer edge of a fixed-width
                // box regardless of how short the text is.
                .frame(width: 150 * sc, alignment: .trailing)

                // Roughly square and tall enough to match the three-field text
                // columns flanking it: ship sprites are square-ish, so the old
                // 88×54 letterboxed them down to 54pt of ship in an 88pt slot —
                // small enough that the hull was hard to make out at a glance.
                pilotShip(shipType: save.player.shipType)
                    .frame(width: 104 * sc, height: 100 * sc)
                    .padding(.top, 4 * sc)

                VStack(alignment: .leading, spacing: 7 * sc) {
                    infoField("Legal Status", legalStatusText(save), bright, dim, sc)
                    infoField("Combat Rating", save.snapshot.ratingTitle.isEmpty ? "Harmless" : save.snapshot.ratingTitle, bright, dim, sc)
                    infoField("Current Date", Self.menuDate(save.player.date), bright, dim, sc)
                }
                .frame(width: 150 * sc, alignment: .leading)
            }
            .fixedSize()
            // In the backdrop's dark red bottom band, below the button knob.
            .position(layout.point(base.width / 2, 706))
            .opacity(appeared ? 1 : 0)
            .animation(.easeOut(duration: 0.4).delay(0.45), value: appeared)
        }
    }

    /// One pilot-info cell: a small dim label above its bright value, the
    /// label/value colours coming from the cölr resource's Menu1/Menu2 pair.
    private func infoField(_ label: String, _ value: String,
                           _ bright: Color, _ dim: Color, _ sc: CGFloat) -> some View {
        // Font sizes scale with `sc` like the surrounding frames/spacing, so the
        // whole readout shrinks as one piece with the backdrop. Hard-coding the
        // point sizes (as before) left the text full-size while its columns
        // shrank on a small screen, overflowing the red band on mobile.
        VStack(alignment: .leading, spacing: 1 * sc) {
            Text(label).novaFont(.caption, size: 9 * sc).foregroundStyle(dim).lineLimit(1)
            Text(value).novaFont(.body, weight: .bold, size: 11 * sc).foregroundStyle(bright).lineLimit(1)
        }
    }

    /// The player's standing with the government of the system they're docked
    /// in, as the menu's short status label.
    private func legalStatusText(_ save: PilotSave) -> String {
        guard let game = model.data.game,
              let govt = game.system(save.player.currentSystem)?.government,
              let record = save.player.legalRecord[govt], record != 0
        else { return "No Record" }
        switch record {
        case ..<(-200): return "Enemy"
        case ..<0:      return "Criminal"
        case 1..<200:   return "Clean"
        default:        return "Trusted"
        }
    }

    /// EV Nova's long-form calendar date, e.g. "June 23rd, 1177 NC".
    private static func menuDate(_ d: GameDate) -> String {
        let months = ["January","February","March","April","May","June","July",
                      "August","September","October","November","December"]
        let month = (1...12).contains(d.month) ? months[d.month - 1] : "\(d.month)"
        let s: String
        switch d.day % 100 {
        case 11, 12, 13: s = "th"
        default:
            switch d.day % 10 { case 1: s = "st"; case 2: s = "nd"; case 3: s = "rd"; default: s = "th" }
        }
        return "\(month) \(d.day)\(s), \(d.year) NC"
    }

    /// The current pilot's ship in EV Nova's red silhouette style. Uses the
    /// **in-flight sprite** (which carries a real transparency mask) rather than
    /// the dedicated shipyard art (whose baked opaque background would tint into
    /// a solid red box) — so only the ship shape shows, with the scope scanlines.
    @ViewBuilder private func pilotShip(shipType id: Int) -> some View {
        if let game = model.data.game, let graphics = model.uiGraphics, let res = game.ship(id),
           let sprite = graphics.shipFallbackPicture(res) {
            ShipSilhouetteView(sprite: sprite)
        }
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
        slideTimer = Timer.scheduledTimer(withTimeInterval: Self.slideFrameInterval,
                                          repeats: true) { timer in
            Task { @MainActor in
                slideFrame += 1
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
                                     if hoveredAction != art.action { model.audio.play(.uiSelect) }
                                     hoveredAction = art.action
                                 } else if hoveredAction == art.action {
                                     hoveredAction = nil
                                 }
                             },
                             action: { activate(art.action) })
                .novaPlace(layout, origin: art.origin, size: art.size)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 22)
                .animation(.spring(response: 0.5, dampingFraction: 0.8)
                    .delay(0.10 + Double(i) * 0.06), value: appeared)
        }
    }

    private func activate(_ action: MainMenuAction) {
        model.audio.play(.uiSelect)
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
