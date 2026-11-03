import SwiftUI

/// Application entry point. One multiplatform SwiftUI app for iOS, iPadOS and
/// macOS. The launcher is the root; the game scene is presented from it.
@main
struct NovaSwiftApp: App {
    @StateObject private var model = AppModel()

    init() {
        HangWatchdog.shared.start()
        CrashDiagnostics.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                #if os(macOS)
                .frame(minWidth: 960, minHeight: 640)
                #endif
                .preferredColorScheme(.dark)
        }
        #if os(macOS) && DEBUG
        .commands {
            // Layout crash hunt: usable from any screen (launcher, menus,
            // editor), not just the in-game console's `winstress`.
            CommandMenu("Debug") {
                Button("Toggle Window Stress (60 s)") {
                    if WindowStress.isRunning { WindowStress.stop() } else { WindowStress.start(seconds: 60) }
                }
                .keyboardShortcut("w", modifiers: [.control, .option, .command])
            }
        }
        #endif
        #if !os(tvOS)
        // Keep the standard title bar on macOS so the window's close / minimize /
        // zoom controls live in the title bar and never overlay the game or HUD.
        .windowResizability(.contentMinSize)
        #endif
    }
}
