import os

/// Categorized `os.Logger`s for the mission/story runtime (control bits,
/// missions, cron events, pilot persistence). View in Console.app/`log stream`
/// filtered by `subsystem:com.novaswift.story`, or per-category with `category:<name>`.
public enum Log {
    static let subsystem = "com.novaswift.story"

    public static let mission = Logger(subsystem: subsystem, category: "Mission")
    public static let ncb = Logger(subsystem: subsystem, category: "NCB")
    public static let pilot = Logger(subsystem: subsystem, category: "Pilot")
}
