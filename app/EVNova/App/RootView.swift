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
            case .game:
                GameContainerView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.screen)
        .onAppear { model.data.reload() }
    }
}
