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
                .frame(minWidth: 900, minHeight: 600)
                #endif
                .preferredColorScheme(.dark)
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        #endif
    }
}
