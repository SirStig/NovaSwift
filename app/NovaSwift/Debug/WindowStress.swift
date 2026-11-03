#if os(macOS)
import AppKit

/// Debug-only layout stress: hammers the key window with random resizes,
/// zooms and full-screen toggles at a few-millisecond cadence, far faster
/// than a hand can drag. Aimed at reproducing a field crash where AppKit threw
/// during a layout pass (`_NSAppKitCrashPoint`). Run it with the Xcode
/// "All Objective-C Exceptions" breakpoint on, from the console:
/// `winstress [seconds]` / `winstress stop`.
@MainActor
enum WindowStress {
    private static var task: Task<Void, Never>?

    static var isRunning: Bool { task != nil }

    static func start(seconds: Double) {
        stop()
        task = Task { @MainActor in
            let end = Date().addingTimeInterval(seconds)
            var step = 0
            while !Task.isCancelled, Date() < end {
                step += 1
                if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                    perform(step: step, on: window)
                }
                try? await Task.sleep(for: .milliseconds(Int.random(in: 5...80)))
            }
            task = nil
        }
    }

    static func stop() {
        task?.cancel()
        task = nil
    }

    private static func perform(step: Int, on window: NSWindow) {
        if step % 23 == 0 {
            window.toggleFullScreen(nil)
        } else if window.styleMask.contains(.fullScreen) {
            return   // let the transition finish; resizing mid-transition is a no-op
        } else if step % 41 == 0 {
            window.zoom(nil)
        } else {
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            let minSize = window.minSize
            var frame = window.frame
            frame.size.width = CGFloat.random(in: min(minSize.width, visible.width)...visible.width)
            frame.size.height = CGFloat.random(in: min(minSize.height, visible.height)...visible.height)
            window.setFrame(frame, display: true, animate: false)
        }
    }
}
#endif
