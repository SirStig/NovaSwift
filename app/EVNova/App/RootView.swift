import SwiftUI

/// Routes between the launcher and the running game.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var menuAssets: MainMenuAssets?

    var body: some View {
        ZStack {
            switch model.screen {
            case .launcher:
                // The port's own native launcher (branding, settings, plug-ins,
                // import data) — always shown first.
                LauncherView()
                    .transition(.opacity)
            case .mainMenu:
                // The authentic EV Nova main menu, from the player's own assets.
                if let assets = menuAssets {
                    AuthenticMainMenuView(assets: assets)
                        .transition(.opacity)
                } else {
                    LoadingView().transition(.opacity)   // still decoding menu art
                }
            case .loading:
                LoadingView()
                    .transition(.opacity)
            case .game:
                GameContainerView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.screen)
        .task(id: model.data.hasBaseData) {
            // Decode the authentic main-menu assets from the player's data (once).
            if menuAssets == nil, model.data.game != nil {
                menuAssets = MainMenuAssets.load(model.data.game)
            }
        }
        .onAppear {
            model.data.reload()
            // Wire audio to the data and start menu music (if the player enabled it
            // and their data ships a track). Music carries through into the game.
            model.prepareAudioAndData()
            #if DEBUG
            if ProcessInfo.processInfo.environment["EVNOVA_AUTOPLAY"] != nil,
               model.data.hasBaseData {
                // Dev-only: jump straight into the game scene, skipping the main
                // menu. Never available in Release builds — a leftover exported
                // env var in a dev shell must not be able to bypass the menu for
                // a shipped app.
                model.finishLoadingIntoGame()
                return
            }
            #endif
            if model.data.hasBaseData, model.screen == .launcher {
                // With game data present, the authentic EV Nova menu IS the main
                // menu — skip the native launcher (that's only the no-data import gate).
                model.screen = .mainMenu
            }
        }
    }
}
