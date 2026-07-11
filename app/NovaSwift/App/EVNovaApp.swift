import SwiftUI

/// Application entry point. One multiplatform SwiftUI app for iOS, iPadOS and
/// macOS. The launcher is the root; the game scene is presented from it.
@main
struct EVNovaApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                #if os(macOS)
                .frame(minWidth: 960, minHeight: 640)
                #endif
                .preferredColorScheme(.dark)
        }
        // Keep the standard title bar on macOS so the window's close / minimize /
        // zoom controls live in the title bar and never overlay the game or HUD.
        .windowResizability(.contentMinSize)
    }
}
