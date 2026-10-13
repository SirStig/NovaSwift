import Foundation

/// Where the off-Apple `FallbackLogger`s (Kit, Engine, Story) mirror every log
/// line, so a frontend's debug suite (the Godot dev console and bug report) can
/// keep an in-memory log. On Apple platforms the loggers are real `os.Logger`s
/// and never reach this; the Apple app reads them back through `OSLogStore`.
///
/// Install once at startup; `emit` is cheap and a no-op while no handler is set.
public enum DebugLogSink {
    public typealias Handler = @Sendable (_ level: String, _ category: String, _ message: String) -> Void

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var handler: Handler?
    }
    private static let box = Box()

    public static func install(_ newHandler: Handler?) {
        box.lock.lock(); box.handler = newHandler; box.lock.unlock()
    }

    public static func emit(level: String, category: String, message: String) {
        box.lock.lock(); let h = box.handler; box.lock.unlock()
        h?(level, category, message)
    }
}
