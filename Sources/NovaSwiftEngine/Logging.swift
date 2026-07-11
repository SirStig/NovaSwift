import os

/// Categorized `os.Logger`s for the simulation core (flight physics, combat,
/// AI, world lifecycle). View in Console.app/`log stream` filtered by
/// `subsystem:com.evnova.engine`, or per-category with `category:<name>`.
public enum Log {
    static let subsystem = "com.evnova.engine"

    public static let physics = Logger(subsystem: subsystem, category: "Physics")
    public static let combat = Logger(subsystem: subsystem, category: "Combat")
    public static let ai = Logger(subsystem: subsystem, category: "AI")
    public static let world = Logger(subsystem: subsystem, category: "World")
}
