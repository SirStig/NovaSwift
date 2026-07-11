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
                    // Still decoding menu art — show the loading visual, but it
                    // must NOT auto-advance into the game (that would open the
                    // saved pilot the instant the menu is ready). `entersGame:
                    // false` keeps us on the menu once the art appears.
                    LoadingView(entersGame: false).transition(.opacity)
                }
            case .loading:
                LoadingView()
                    .transition(.opacity)
            case .game:
                GameContainerView()
                    .transition(.opacity)
            }

            // A new pilot's scenario intro, full-screen and outside any dialog's
            // sheet frame — see AppModel.pendingIntro.
            if let scenario = model.pendingIntro {
                IntroSequenceView(scenario: scenario) {
                    model.pendingIntro = nil
                    model.beginPlay()
                }
                .transition(.opacity)
                .zIndex(10)
            }

            // UI debug (measurement) overlay controls: an on-screen badge to
            // exit and a ⇧⌘D hotkey to toggle. The grid itself is drawn by each
            // coordinate-space container (see NovaDebug.swift) from the ambient
            // flag injected below.
            debugControls
        }
        .environment(\.novaDebugEnabled, model.settings.uiDebugOverlay)
        .animation(.easeInOut(duration: 0.25), value: model.screen)
        .animation(.easeInOut(duration: 0.3), value: model.pendingIntro != nil)
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
            if ProcessInfo.processInfo.environment["NOVASWIFT_AUTOPLAY"] != nil,
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

    /// Always-mounted so the ⇧⌘D shortcut works everywhere; the badge only shows
    /// while the overlay is on (a persistent reminder + one-tap exit on touch).
    @ViewBuilder private var debugControls: some View {
        // Hidden keyboard-shortcut catcher (macOS / hardware keyboard).
        Button(action: toggleDebug) { Color.clear }
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
            .keyboardShortcut("d", modifiers: [.command, .shift])

        if model.settings.uiDebugOverlay {
            VStack {
                Button(action: toggleDebug) {
                    Label("UI DEBUG · ⇧⌘D to exit", systemImage: "ruler")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.black.opacity(0.8), in: Capsule())
                        .foregroundStyle(.green)
                        .overlay(Capsule().strokeBorder(.green.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                Spacer()
            }
            .zIndex(20)
            .transition(.opacity)
        }
    }

    private func toggleDebug() {
        model.settings.uiDebugOverlay.toggle()
        model.commitSettings()
    }
}
