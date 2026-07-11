import os

/// Categorized `os.Logger`s for the data layer (resource decoding, containers,
/// graphics, plug-in catalog). View in Console.app/`log stream` filtered by
/// `subsystem:com.novaswift.kit`, or per-category with `category:<name>`.
public enum Log {
    static let subsystem = "com.novaswift.kit"

    public static let resource = Logger(subsystem: subsystem, category: "Resource")
    public static let interface = Logger(subsystem: subsystem, category: "Interface")
    public static let graphics = Logger(subsystem: subsystem, category: "Graphics")
    public static let data = Logger(subsystem: subsystem, category: "Data")
}
