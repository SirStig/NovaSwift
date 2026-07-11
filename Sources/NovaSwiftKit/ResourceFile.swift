import Foundation

/// Errors surfaced while decoding a resource container.
public enum ResourceFileError: Swift.Error, CustomStringConvertible {
    case unrecognizedFormat
    case corrupt(String)

    public var description: String {
        switch self {
        case .unrecognizedFormat:
            return "Unrecognized resource container format (not a classic resource fork, .ndat, or BRGR Rez file)"
        case let .corrupt(detail):
            return "Corrupt resource container: \(detail)"
        }
    }
}

/// The container encodings we can read.
public enum ContainerFormat: String {
    case classic  // classic Macintosh resource fork, and `.ndat` (same bytes in the data fork)
    case rez      // Graphite/ResForge "BRGR" extended Rez format
}

/// Front door for loading EV Nova data. Detects the container format from the
/// bytes and dispatches to the right parser.
public enum ResourceFile {
    private static let brgrSignature: UInt32 = 0x4252_4752 // 'BRGR'

    /// Detect the container format without fully parsing.
    public static func detectFormat(_ data: Data) -> ContainerFormat? {
        guard data.count >= 16 else { return nil }
        let b = [UInt8](data.prefix(4))
        let magic = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        if magic == brgrSignature { return .rez }
        // Otherwise assume a classic resource fork / .ndat. The classic parser
        // validates the header and will throw if this guess is wrong.
        return .classic
    }

    /// Parse a resource container from raw bytes.
    public static func read(_ data: Data) throws -> ResourceCollection {
        switch detectFormat(data) {
        case .rez:
            let collection = try RezContainer.parse(data)
            Log.resource.debug("Parsed BRGR Rez container: \(collection.totalCount, privacy: .public) resource(s), \(collection.types.count, privacy: .public) type(s)")
            return collection
        case .classic:
            let collection = try ClassicResourceFork.parse(data)
            Log.resource.debug("Parsed classic resource fork: \(collection.totalCount, privacy: .public) resource(s), \(collection.types.count, privacy: .public) type(s)")
            return collection
        case nil:
            Log.resource.error("Unrecognized resource container format (\(data.count, privacy: .public) bytes) — not a classic resource fork, .ndat, or BRGR Rez file")
            throw ResourceFileError.unrecognizedFormat
        }
    }

    /// Parse a resource container from a file URL (reads the data fork; for a
    /// classic file whose resources live in the resource fork, pass a URL to
    /// `<path>/..namedfork/rsrc`).
    public static func read(contentsOf url: URL) throws -> ResourceCollection {
        do {
            return try read(try Data(contentsOf: url))
        } catch {
            Log.resource.error("Failed to load resource container at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}
