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

        let logoSheet = rle(8010)
        return MainMenuAssets(background: pict(8000),
                              logo: logoSheet?.frameCGImage(0),
                              logoSize: CGSize(width: logoSheet?.frameWidth ?? 0,
                                               height: logoSheet?.frameHeight ?? 0),
                              buttons: buttons)
    }
}

struct AuthenticMainMenuView: View {
    @EnvironmentObject private var model: AppModel
    let assets: MainMenuAssets

    @State private var appeared = false
    @State private var sheet: Sheet?
    private enum Sheet: String, Identifiable { case settings, about; var id: String { rawValue } }

    private let base = CGSize(width: 1024, height: 768)

    var body: some View {
        GeometryReader { geo in
            // Aspect-fit the 1024×768 title art so button coordinates line up 1:1.
            let scale = min(geo.size.width / base.width, geo.size.height / base.height)
            let ox = (geo.size.width - base.width * scale) / 2
            let oy = (geo.size.height - base.height * scale) / 2
            let place: (CGFloat, CGFloat) -> CGPoint = { x, y in CGPoint(x: ox + x * scale, y: oy + y * scale) }

            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()

                if let bg = assets.background {
                    Image(decorative: bg, scale: 1)
                        .resizable().interpolation(.medium)
                        .frame(width: base.width * scale, height: base.height * scale)
                        .position(place(base.width / 2, base.height / 2))
                }

                buttons(scale: scale, place: place)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true }
            model.audio.play(.uiSelect)   // menu appears
        }
        .sheet(item: $sheet) { which in
            NavigationStack {
                switch which {
                case .settings: SettingsView()
                case .about: AboutView()
                }
            }
            .frame(minWidth: 420, minHeight: 520)
            .preferredColorScheme(.dark)
        }
    }

    private func buttons(scale: CGFloat, place: @escaping (CGFloat, CGFloat) -> CGPoint) -> some View {
        ForEach(Array(assets.buttons.enumerated()), id: \.offset) { i, art in
            MenuSpriteButton(art: art, scale: scale,
                             onRollover: { model.audio.play(.uiSelect) },
                             action: { activate(art.action) })
                .position(place(CGFloat(art.origin.x) + art.size.width / 2,
                                CGFloat(art.origin.y) + art.size.height / 2))
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 22)
                .animation(.spring(response: 0.5, dampingFraction: 0.8)
                    .delay(0.10 + Double(i) * 0.06), value: appeared)
        }
    }

    private func activate(_ action: MainMenuAction) {
        model.audio.play(.uiSelect)
        switch action {
        case .newPilot, .enterShip, .openPilot: model.beginPlay()
        case .setPrefs: sheet = .settings
        case .aboutNova: sheet = .about
        case .quitNova: model.exitToLauncher()
        }
    }
}

/// A button whose face is a real EV Nova sprite: the up frame normally, the
/// highlighted frame on hover (rollover) or press.
private struct MenuSpriteButton: View {
    let art: MainMenuAssets.ButtonArt
    let scale: CGFloat
    var onRollover: () -> Void = {}
    let action: () -> Void
    @State private var hovering = false
    @State private var pressing = false

    var body: some View {
        let highlighted = hovering || pressing
        Image(decorative: highlighted ? art.pressed : art.normal, scale: 1)
            .resizable().interpolation(.medium)
            .frame(width: art.size.width * scale, height: art.size.height * scale)
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
                    .onEnded { g in
                        pressing = false
                        let inside = abs(g.translation.width) < art.size.width * scale
                            && abs(g.translation.height) < art.size.height * scale
                        if inside { action() }
                    }
            )
    }
}
