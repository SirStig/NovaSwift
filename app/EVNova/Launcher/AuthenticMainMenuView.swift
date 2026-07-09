import SwiftUI
import EVNovaKit

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
    }
    let background: CGImage?
    let logo: CGImage?
    let logoSize: CGSize
    let buttons: [ButtonArt]

    // Authentic button top-left positions (cölr resource), in spïn 600–605 order:
    // two columns of three — New/Open/Quit and Enter/Prefs/About.
    private static let positions: [CGPoint] = [
        CGPoint(x: 349, y: 400), CGPoint(x: 344, y: 464), CGPoint(x: 345, y: 528),
        CGPoint(x: 555, y: 401), CGPoint(x: 581, y: 464), CGPoint(x: 580, y: 528),
    ]

    static func load(_ game: NovaGame?) -> MainMenuAssets? {
        guard let game else { return nil }
        func rle(_ id: Int) -> SpriteSheet? {
            guard let d = game.resources.resource(NovaType.rleD, id)?.data else { return nil }
            return try? RLED.decode(d)
        }
        func pict(_ id: Int) -> CGImage? {
            guard let d = game.resources.resource(NovaType.pict, id)?.data,
                  let s = try? PICT.decode(d) else { return nil }
            return s.makeCGImage()
        }

        let specs: [(MainMenuAction, Int)] = [
            (.newPilot, 8050), (.openPilot, 8051), (.quitNova, 8052),
            (.enterShip, 8053), (.setPrefs, 8054), (.aboutNova, 8055),
        ]
        var buttons: [ButtonArt] = []
        for (i, spec) in specs.enumerated() {
            guard let sheet = rle(spec.1),
                  let n = sheet.frameCGImage(0), let p = sheet.frameCGImage(1) else { continue }
            buttons.append(.init(action: spec.0, normal: n, pressed: p,
                                 size: CGSize(width: sheet.frameWidth, height: sheet.frameHeight),
                                 origin: positions[min(i, positions.count - 1)]))
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
                let cropped = full.cropping(to: CGRect(x: 0, y: y, width: w, height: h)) ?? full
                logo = keyOutBlack(cropped)
                logoSize = CGSize(width: logo?.width ?? w, height: logo?.height ?? h)
            }
        }

        return MainMenuAssets(background: pict(8000), logo: logo, logoSize: logoSize, buttons: buttons)
    }

    /// PICT-sourced logo art is opaque with a black backing box (PICT has no
    /// alpha channel). Derive alpha from luminance and un-premultiply the
    /// color so the glow composites naturally over the starfield behind it —
    /// a `.screen` blend on the raw opaque art double-brightens every pixel
    /// where the glow overlaps a bright star instead of just masking the box.
    private static func keyOutBlack(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: width * 4,
                                   space: colorSpace,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = pixels[i], g = pixels[i + 1], b = pixels[i + 2]
            let alpha = max(r, max(g, b))
            if alpha == 0 {
                pixels[i + 3] = 0
            } else {
                pixels[i] = UInt8(min(255, Int(r) * 255 / Int(alpha)))
                pixels[i + 1] = UInt8(min(255, Int(g) * 255 / Int(alpha)))
                pixels[i + 2] = UInt8(min(255, Int(b) * 255 / Int(alpha)))
                pixels[i + 3] = alpha
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

struct AuthenticMainMenuView: View {
    @EnvironmentObject private var model: AppModel
    let assets: MainMenuAssets

    @State private var appeared = false
    @State private var sheet: Sheet?
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

                if let logo = assets.logo, assets.logoSize.height > 0 {
                    Image(decorative: logo, scale: 1)
                        .resizable().interpolation(.medium)
                        .novaPlace(layout,
                                   x: (base.width - assets.logoSize.width) / 2, y: 168,
                                   w: assets.logoSize.width, h: assets.logoSize.height)
                        .opacity(appeared ? 1 : 0)
                        .scaleEffect(appeared ? 1 : 0.94)
                        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: appeared)
                }

                buttons(layout: layout)
                pilotStatus(layout: layout)
                modernExtras   // port-added features not in the original menu
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true }
            model.audio.play(.uiSelect)         // menu appears
            model.prepareAudioAndData()         // ensure main-menu background music is playing
        }
        .sheet(item: $sheet) { which in
            NavigationStack {
                switch which {
                case .newPilot: NewPilotView()
                case .openPilot: PilotListView()
                case .settings: SettingsView()
                case .about: AboutView()
                case .plugins: PluginsView()
                case .importData: ImportDataView()
                }
            }
            .frame(minWidth: 420, minHeight: 520)
            .preferredColorScheme(.dark)
        }
    }

    /// The current-pilot/ship status readout for "Enter Ship" — a bright/dim
    /// two-tone line (echoing the `cölr` resource's `MenuColor1`/`MenuColor2`
    /// "bright & dim colors for main menu" fields; exact position and literal
    /// color aren't specified in the Nova Bible, so this is an authentic-styled
    /// best-effort placement, not a byte-verified one) shown under the button
    /// columns when a saved pilot exists to resume.
    @ViewBuilder private func pilotStatus(layout: NovaLayout) -> some View {
        if let save = model.roster.mostRecent {
            VStack(spacing: 3) {
                Text("Continue as \(save.displayName)")
                    .novaFont(.heading, weight: .bold)
                    .foregroundStyle(novaAmber)
                Text("\(save.snapshot.shipName) · \(save.snapshot.systemName.isEmpty ? "—" : save.snapshot.systemName) · \(save.snapshot.credits.formatted()) cr")
                    .novaFont(.caption)
                    .foregroundStyle(novaAmber.opacity(0.6))
            }
            .multilineTextAlignment(.center)
            .novaPlace(layout, x: (base.width - 400) / 2, y: 604, w: 400, h: 40)
            .opacity(appeared ? 1 : 0)
            .animation(.easeOut(duration: 0.4).delay(0.45), value: appeared)
        }
    }

    /// Modern, port-only affordances (features EV Nova never had): the plug-in
    /// manager and data import. Kept visually distinct from the game's own buttons,
    /// tucked in the bottom-left so they don't intrude on the authentic menu.
    private var modernExtras: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                extraButton("Plug-ins", "puzzlepiece.extension.fill") { sheet = .plugins }
                extraButton("Import Data", "square.and.arrow.down.fill") { sheet = .importData }
                Spacer()
            }
            .padding(.leading, 20)
            .padding(.bottom, 18)
        }
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.4).delay(0.5), value: appeared)
    }

    private func extraButton(_ label: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button { model.audio.play(.uiSelect); action() } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(label).font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.85))
    }

    private func buttons(layout: NovaLayout) -> some View {
        ForEach(Array(assets.buttons.enumerated()), id: \.offset) { i, art in
            MenuSpriteButton(art: art,
                             onRollover: { model.audio.play(.uiSelect) },
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
        case .enterShip: model.continueMostRecent()
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
    var onRollover: () -> Void = {}
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
            .onHover { h in
                hovering = h
                if h { onRollover() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressing = true }
                    .onEnded { _ in pressing = false; action() }
            )
    }
}
