import Foundation
import os
#if os(macOS)
import AppKit
#endif

/// Captures what a crash report from the field leaves out.
///
/// A TestFlight crash inside AppKit's layout pass (`_NSAppKitCrashPoint`) names
/// no app frame and no exception message, so there's nothing to act on. This
/// does two cheap things:
///
/// 1. An uncaught-exception handler writes the exception's name, reason and
///    symbolicated stack, the last `HangWatchdog` breadcrumb, and the window /
///    screen state to a file just before the process dies. The next launch logs
///    it and keeps it for `BugReport`.
/// 2. On macOS, window resize / full-screen / screen-change events drop
///    breadcrumbs, so the file (and any hang report) says what the window was
///    doing when layout threw.
///
/// Whether AppKit's `_crashOnException:` path always runs the handler isn't
/// guaranteed, so a missing file after a crash is itself a data point.
enum CrashDiagnostics {

    static func install() {
        archivePreviousReport()
        NSSetUncaughtExceptionHandler { exception in
            CrashDiagnostics.write(exception)
        }
        #if os(macOS)
        Task { @MainActor in WindowBreadcrumbs.shared.start() }
        #endif
    }

    /// The exception report from the previous run, if it ended in one.
    static func previousReport() -> String? {
        guard let url = previousURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Files

    private static var directory: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
    }
    private static var currentURL: URL? { directory?.appendingPathComponent("NovaSwift-exception.txt") }
    private static var previousURL: URL? { directory?.appendingPathComponent("NovaSwift-exception-previous.txt") }

    /// Move last run's report aside (so this run can write its own) and log it.
    private static func archivePreviousReport() {
        guard let current = currentURL, let previous = previousURL,
              let text = try? String(contentsOf: current, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: current, to: previous)
        Log.scene.fault("Previous run ended in an uncaught exception:\n\(text, privacy: .public)")
    }

    // MARK: Writing

    private static func write(_ exception: NSException) {
        guard let url = currentURL else { return }
        let crumb = HangWatchdog.lastBreadcrumb
        var lines = [
            "Uncaught exception at \(ISO8601DateFormatter().string(from: Date()))",
            "name:   \(exception.name.rawValue)",
            "reason: \(exception.reason ?? "(none)")",
            "last breadcrumb: \(crumb.text) (\(crumb.ageMs) ms ago)",
        ]
        if let info = exception.userInfo, !info.isEmpty { lines.append("userInfo: \(info)") }
        #if os(macOS)
        if Thread.isMainThread {
            lines.append(MainActor.assumeIsolated { WindowBreadcrumbs.windowSummary() })
        }
        #endif
        lines.append("stack:")
        lines.append(contentsOf: exception.callStackSymbols.map { "  \($0)" })
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

#if os(macOS)
/// Drops a `HangWatchdog` breadcrumb for window events that trigger a layout
/// pass: resize, full screen, display change, minimise.
@MainActor
final class WindowBreadcrumbs: NSObject {
    static let shared = WindowBreadcrumbs()
    private var started = false

    private static let events: [(Notification.Name, String)] = [
        (NSWindow.didResizeNotification, "resize"),
        (NSWindow.willEnterFullScreenNotification, "will enter full screen"),
        (NSWindow.didEnterFullScreenNotification, "entered full screen"),
        (NSWindow.willExitFullScreenNotification, "will exit full screen"),
        (NSWindow.didExitFullScreenNotification, "exited full screen"),
        (NSWindow.didChangeScreenNotification, "changed screen"),
        (NSWindow.didChangeBackingPropertiesNotification, "backing properties changed"),
        (NSWindow.didMiniaturizeNotification, "minimised"),
        (NSWindow.didDeminiaturizeNotification, "restored"),
    ]

    func start() {
        guard !started else { return }
        started = true
        for (name, _) in Self.events {
            NotificationCenter.default.addObserver(self, selector: #selector(windowEvent(_:)),
                                                   name: name, object: nil)
        }
    }

    @objc private func windowEvent(_ note: Notification) {
        guard let window = note.object as? NSWindow,
              let label = Self.events.first(where: { $0.0 == note.name })?.1 else { return }
        let size = window.frame.size
        HangWatchdog.note("window \(label) \(Int(size.width))x\(Int(size.height))")
    }

    /// Frame, full-screen state and display for every window, for the
    /// exception report.
    static func windowSummary() -> String {
        let windows = NSApplication.shared.windows.map { w -> String in
            let f = w.frame
            let full = w.styleMask.contains(.fullScreen) ? " fullscreen" : ""
            let screen = w.screen.map { "\($0.localizedName) @\($0.backingScaleFactor)x" } ?? "no screen"
            return "  \(Int(f.width))x\(Int(f.height)) at (\(Int(f.minX)),\(Int(f.minY)))\(full) on \(screen)"
        }
        return (["windows:"] + windows).joined(separator: "\n")
    }
}
#endif
