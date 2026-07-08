import SwiftUI
import EVNovaKit

/// The authentic EV Nova main menu, rendered from the player's own assets: the
/// full-screen background picture (PICT 8000), the game logo (rlëD 8010) and the
/// six real menu buttons (rlëD 8050–8055, each with an up + highlighted frame).
/// Reached from the port's native launcher via "Play".
enum MainMenuAction: CaseIterable { case newPilot, openPilot, enterShip, setPrefs, aboutNova, quitNova }

struct MainMenuAssets {
    struct ButtonArt { let action: MainMenuAction; let normal: CGImage; let pressed: CGImage; let size: CGSize }
    let background: CGImage?
    let logo: CGImage?
    let logoSize: CGSize
    let buttons: [ButtonArt]

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

        // Column-major order (spïn 600–605): col 1 New/Open/Quit, col 2 Enter/Prefs/About.
        let specs: [(MainMenuAction, Int)] = [
            (.newPilot, 8050), (.openPilot, 8051), (.quitNova, 8052),
            (.enterShip, 8053), (.setPrefs, 8054), (.aboutNova, 8055),
        ]
        var buttons: [ButtonArt] = []
        for (action, id) in specs {
            guard let sheet = rle(id),
                  let n = sheet.frameCGImage(0), let p = sheet.frameCGImage(1) else { continue }
            buttons.append(.init(action: action, normal: n, pressed: p,
                                 size: CGSize(width: sheet.frameWidth, height: sheet.frameHeight)))
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
            let scale = min(geo.size.width / base.width, geo.size.height / base.height)

            ZStack {
                // Background, aspect-filled so it always covers the window.
                if let bg = assets.background {
                    Image(decorative: bg, scale: 1)
                        .resizable().interpolation(.medium)
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    Color.black
                }
                LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.45)],
                               startPoint: .top, endPoint: .bottom)

                VStack(spacing: 0) {
                    Spacer().frame(height: geo.size.height * 0.09)
                    logo(scale: scale)
                    Spacer()
                    buttonColumns(scale: scale)
                    Spacer().frame(height: geo.size.height * 0.10)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true } }
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

    @ViewBuilder
    private func logo(scale: CGFloat) -> some View {
        if let logo = assets.logo {
            Image(decorative: logo, scale: 1)
                .resizable().interpolation(.medium)
                .frame(width: assets.logoSize.width * scale, height: assets.logoSize.height * scale)
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.94)
                .animation(.spring(response: 0.6, dampingFraction: 0.85), value: appeared)
        }
    }

    private func buttonColumns(scale: CGFloat) -> some View {
        // The six buttons in column order: [New, Open, Quit] | [Enter, Prefs, About].
        let col1 = Array(assets.buttons.prefix(3))
        let col2 = Array(assets.buttons.dropFirst(3))
        return HStack(alignment: .top, spacing: 40 * scale) {
            column(col1, startIndex: 0, scale: scale)
            column(col2, startIndex: 3, scale: scale)
        }
    }

    private func column(_ arts: [MainMenuAssets.ButtonArt], startIndex: Int, scale: CGFloat) -> some View {
        VStack(spacing: 14 * scale) {
            ForEach(Array(arts.enumerated()), id: \.offset) { i, art in
                let index = startIndex + i
                MenuSpriteButton(art: art, scale: scale) { activate(art.action) }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 26)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8)
                        .delay(0.12 + Double(index) * 0.06), value: appeared)
            }
        }
    }

    private func activate(_ action: MainMenuAction) {
        model.audio.play(.uiSelect)
        switch action {
        case .newPilot, .enterShip: model.beginPlay()
        case .openPilot: model.beginPlay()          // continues to the game for now
        case .setPrefs: sheet = .settings
        case .aboutNova: sheet = .about
        case .quitNova: model.exitToLauncher()      // back to the port's native launcher
        }
    }
}

/// A button whose face is a real EV Nova sprite: the up frame normally, the
/// highlighted frame on hover (rollover) or press.
private struct MenuSpriteButton: View {
    let art: MainMenuAssets.ButtonArt
    let scale: CGFloat
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
            .onHover { hovering = $0 }
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
