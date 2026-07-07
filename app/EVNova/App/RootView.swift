import SwiftUI

/// Routes between the launcher and the running game.
struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            switch model.screen {
            case .launcher:
                LauncherView()
                    .transition(.opacity)
            case .loading:
                LoadingView()
                    .transition(.opacity)
            case .game:
                GameContainerView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.screen)
        .onAppear {
            model.data.reload()
            // Wire audio to the data and start menu music (if the player enabled it
            // and their data ships a track). Music carries through into the game.
            model.prepareAudioAndData()
            // Dev: EVNOVA_AUTOPLAY jumps straight into the game scene, so the live
            // system (with AI ships) can be inspected without clicking through the
            // launcher.
            if ProcessInfo.processInfo.environment["EVNOVA_AUTOPLAY"] != nil,
               model.data.hasBaseData {
                model.finishLoadingIntoGame()
            }
        }
    }
}
