import os

/// Categorized `os.Logger`s for the app target (input, scene lifecycle, HUD,
/// pilots, spaceport, settings, data loading). Filter in Console.app or
/// `log stream --predicate 'subsystem == "com.novaswift.app"'`, optionally adding
/// `&& category == "Input"` etc. to isolate one subsystem while chasing a bug.
enum Log {
    static let subsystem = "com.novaswift.app"

    static let input = Logger(subsystem: subsystem, category: "Input")
    static let scene = Logger(subsystem: subsystem, category: "Scene")
    static let hud = Logger(subsystem: subsystem, category: "HUD")
    static let radar = Logger(subsystem: subsystem, category: "Radar")
    static let pilot = Logger(subsystem: subsystem, category: "Pilot")
    static let spaceport = Logger(subsystem: subsystem, category: "Spaceport")
    static let settings = Logger(subsystem: subsystem, category: "Settings")
    static let data = Logger(subsystem: subsystem, category: "Data")
    static let audio = Logger(subsystem: subsystem, category: "Audio")
    static let story = Logger(subsystem: subsystem, category: "Story")
    /// Frame-timing / stress-test instrumentation: the per-phase breakdown flushed
    /// twice a second while the debug suite is attached, plus one-off frame-spike
    /// reports. Isolate with `category == "Perf"` while chasing a frame drop.
    static let perf = Logger(subsystem: subsystem, category: "Perf")
}
