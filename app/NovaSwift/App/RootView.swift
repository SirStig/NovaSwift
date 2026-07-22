import SwiftUI

/// Routes between the launcher and the running game.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var menuAssets: MainMenuAssets?
    /// Data is loaded but the authentic menu's art wouldn't decode — show the
    /// modern menu rather than an endless loading screen.
    @State private var menuArtFailed = false
    #if os(tvOS)
    /// Drives the controller-required gate: shows/hides live with pairing.
    @ObservedObject private var padState = PadState.shared
    /// Dev/automation escape hatch — the simulator has no way to pair a pad.
    static let padGateDisabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["NOVASWIFT_NO_PAD_GATE"] != nil
        #else
        false
        #endif
    }()
    #endif

    var body: some View {
        ZStack {
            switch model.screen {
            case .launcher:
                // The port's own native launcher (branding, settings, plug-ins,
                // import data) — always shown first.
                LauncherView()
                    .transition(.opacity)
            case .mainMenu:
                // Nova Swift (modern) menu replaces the authentic one when the
                // player has chosen the modern presentation — it needs no decoded
                // PICT assets, so it shows immediately.
                if model.settings.modernMainMenu {
                    ModernMainMenuView()
                        .transition(.opacity)
                } else if let assets = menuAssets {
                    // The authentic EV Nova main menu, from the player's own assets.
                    AuthenticMainMenuView(assets: assets)
                        .transition(.opacity)
                } else if menuArtFailed {
                    // The data merged but its menu art won't decode — fall back
                    // to the port's own menu instead of sitting on the loading
                    // visual forever (the player can still play, and re-import
                    // from Settings).
                    ModernMainMenuView()
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
                    // Offer flight training before the game begins (first pilot only).
                    model.offerTutorialAfterNewPilot()
                }
                .transition(.opacity)
                .zIndex(10)
            }

            // After the intro (or immediately, when the scenario has none), offer
            // the new pilot a skippable flight-training run.
            if model.pendingTutorialOffer {
                TutorialOfferView(
                    onStart: { model.startTutorial(exit: .play) },
                    onSkip: { model.skipTutorialOffer() })
                    .transition(.opacity)
                    .zIndex(11)
            }

            // The flight-training sandbox itself — full-screen, over everything. On
            // finish it hands back per its exit (begin play, or return to menu).
            if let exit = model.tutorial {
                TutorialContainerView(
                    finishLabel: exit == .play ? "Begin Your Journey" : "Return to Menu",
                    onFinish: { model.finishTutorial() })
                    .transition(.opacity)
                    .zIndex(12)
            }

            // UI debug (measurement) overlay controls: an on-screen badge to
            // exit and a ⇧⌘D hotkey to toggle. The grid itself is drawn by each
            // coordinate-space container (see NovaDebug.swift) from the ambient
            // flag injected below.
            debugControls

            // A controller player clicked a text field on a device with no
            // fullscreen system keyboard — the pad-drivable keyboard overlay.
            // `.id` so each request starts with its own text/suggestions.
            if let request = model.padKeyboard {
                PadKeyboardView(request: request)
                    .id(request.id)
                    .zIndex(48)
                    .transition(.opacity)
            }

            // The controller-driven UI cursor, above everything so it can
            // click into any screen. Inert on tvOS / without a pad.
            ControllerCursorOverlay()
                .zIndex(50)

            #if os(tvOS)
            // NovaSwift is controller-required on Apple TV (the Siri Remote
            // can't fly a ship, and the whole UI is cursor-driven). Gate the
            // app until an extended gamepad pairs; lifts itself the moment
            // one connects. Matches the GCSupportedGameControllers Info.plist
            // declaration (ExtendedGamepad only).
            if !padState.isConnected, !Self.padGateDisabled {
                ControllerRequiredView()
                    .zIndex(60)
                    .transition(.opacity)
            }
            #endif
        }
        .environment(\.novaDebugEnabled, model.settings.uiDebugOverlay)
        .environment(\.novaUIScale, model.settings.uiScale)   // "Overall UI scale"
        .environment(\.novaTheme, model.uiTheme)              // cölr interface theme
        #if os(tvOS)
        // Keep the focus engine parked here (the controller cursor is the real
        // pointer; cursor targets are focusable(false)) and swallow Menu/B
        // presses — otherwise tvOS treats an unhandled Menu as "suspend the
        // app", which would quit to the home screen the moment a player
        // pressed their bound Menu button. Exiting the app remains available
        // via the TV/Home button.
        .focusable()
        .onExitCommand { }
        // Default button style: the system automatic style renders every
        // un-styled Button as a huge white focus card that overflows the
        // game's fixed-size panels. The compact style keeps buttons
        // label-sized and makes them controller-cursor clickable. Explicit
        // styles (`.plain`, NovaButtonStyle, …) still win where set.
        .buttonStyle(TVCompactButtonStyle())
        #endif

        .animation(.easeInOut(duration: 0.25), value: model.screen)
        .animation(.easeInOut(duration: 0.3), value: model.pendingIntro != nil)
        .animation(.easeInOut(duration: 0.3), value: model.pendingTutorialOffer)
        .animation(.easeInOut(duration: 0.3), value: model.tutorial != nil)
        .task(id: model.data.dataStamp) {
            // Decode the authentic main-menu assets from the player's data —
            // re-attempted after every reload until it succeeds, because a
            // partial import fails this decode and the failure must not latch:
            // keyed on hasBaseData it ran once against the first partial batch
            // and stuck the modern menu on even after the art arrived.
            if menuAssets == nil, model.data.game != nil {
                menuAssets = MainMenuAssets.load(model.data.game)
                // Only a *complete* data set that still won't decode is a real
                // art failure worth falling back to the modern menu for.
                menuArtFailed = menuAssets == nil && model.data.isBaseDataComplete
            }
        }
        .onChange(of: model.data.isBaseDataComplete) { _, complete in
            // The launcher is a pre-data setup guide only — there is no "demo"
            // to fall through to. The moment a *complete* data set is available
            // (import finishes while the guide is on screen), advance straight
            // into the authentic menu, mirroring the `onAppear` check below.
            // A partial import stays on the launcher: entering the menu with
            // files missing is how the app used to wedge on the loading visual.
            // While the Wi-Fi receiver is live, hold position even on complete
            // data — advancing unmounts the wizard and kills the server while
            // the browser may still be sending (the batch signal / Continue
            // button end that session; the webImportActive onChange below
            // then performs this advance).
            if complete, model.screen == .launcher, !model.webImportActive {
                model.screen = .mainMenu
            }
        }
        .onChange(of: model.webImportActive) { _, active in
            // The Wi-Fi import session just ended — perform the advance the
            // gate above deferred, if the data indeed came out complete.
            if !active, model.data.isBaseDataComplete, model.screen == .launcher {
                model.screen = .mainMenu
            }
        }
        .onAppear {
            model.data.reload()
            // Wire audio to the data and start menu music (if the player enabled it
            // and their data ships a track). Music carries through into the game.
            model.prepareAudioAndData()
            #if canImport(GameKit)
            // Skippable via env for automated/dev runs: the sign-in sheet is
            // system UI that would otherwise block scripted screenshots.
            if ProcessInfo.processInfo.environment["NOVASWIFT_NO_GAMECENTER"] == nil {
                model.gameCenter.authenticate()   // sign in for online co-op (safe if already signed in)
            }
            #endif
            #if canImport(CloudKit)
            // Game-data iCloud pass: upload this device's import if the cloud
            // doesn't have it yet; with no data, check for (and on tvOS,
            // restore) a set imported on another device. Best-effort.
            Task { await model.syncGameDataWithCloud() }
            #endif
            #if DEBUG
            // Dev/automation: start with the UI debug (measurement) overlay on —
            // includes the cursor-target outlines in ControllerCursorOverlay.
            if ProcessInfo.processInfo.environment["NOVASWIFT_UI_DEBUG"] != nil {
                model.settings.uiDebugOverlay = true
            }
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
            if model.data.isBaseDataComplete, model.screen == .launcher {
                // With complete game data present, the authentic EV Nova menu IS
                // the main menu — skip the native launcher (that's only the
                // no-data import gate). A partial import stays here so the setup
                // wizard can say what's still missing.
                model.screen = .mainMenu
            }
        }
    }

    /// Always-mounted so the ⇧⌘D shortcut works everywhere; the badge only shows
    /// while the overlay is on (a persistent reminder + one-tap exit on touch).
    @ViewBuilder private var debugControls: some View {
        #if !os(tvOS)
        // Hidden keyboard-shortcut catcher (macOS / hardware keyboard).
        // tvOS has no keyboard shortcuts; the badge below still works there.
        Button(action: toggleDebug) { Color.clear }
            .buttonStyle(.plain)   // not .novaPlain: 0×0 and hidden, nothing to cursor-click
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
            .keyboardShortcut("d", modifiers: [.command, .shift])
        #endif

        if model.settings.uiDebugOverlay {
            VStack {
                CursorButton(action: toggleDebug) {
                    Label("UI DEBUG · ⇧⌘D to exit", systemImage: "ruler")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.black.opacity(0.8), in: Capsule())
                        .foregroundStyle(.green)
                        .overlay(Capsule().strokeBorder(.green.opacity(0.5)))
                }
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
#if os(tvOS)
/// Full-screen "pair a controller" gate shown on Apple TV until an extended
/// gamepad connects. NovaSwift is a twin-stick game with a cursor-driven UI —
/// the Siri Remote genuinely can't play it, so this is shown up front rather
/// than letting the player wander into an unusable menu.
private struct ControllerRequiredView: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 26) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 96))
                    .foregroundStyle(LinearGradient(colors: [.white, novaAmber],
                                                    startPoint: .top, endPoint: .bottom))
                Text("Connect a Game Controller")
                    .novaFont(.title, weight: .bold, size: 34)
                    .foregroundStyle(.white)
                Text("NovaSwift needs a game controller — an Xbox, PlayStation, or other Bluetooth pad. The Siri Remote can't fly a starship.")
                    .novaFont(.body, size: 20)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 760)
                    .fixedSize(horizontal: false, vertical: true)
                Label("Pair one in Settings → Remotes & Devices → Bluetooth", systemImage: "dot.radiowaves.left.and.right")
                    .novaFont(.caption, size: 17)
                    .foregroundStyle(novaAmber)
                ProgressView()
                    .tint(novaAmber)
                    .padding(.top, 6)
            }
            .padding(60)
        }
    }
}
#endif

