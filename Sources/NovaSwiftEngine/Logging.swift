import Foundation
#if canImport(os)
import os
#endif

/// Categorized loggers for the simulation core (flight physics, combat,
/// AI, world lifecycle). On Apple platforms these are real
/// `os.Logger`s (view in Console.app/`log stream` filtered by
/// `subsystem:com.novaswift.engine`, or per-category with `category:<name>`);
/// off-Apple (Linux/Windows, e.g. the Godot bridge) they fall back to a tiny
/// stderr-printing shim with the same call surface, since `os.Logger` doesn't
/// exist there.
public enum Log {
    static let subsystem = "com.novaswift.engine"

#if canImport(os)
    public static let physics = Logger(subsystem: subsystem, category: "Physics")
    public static let combat = Logger(subsystem: subsystem, category: "Combat")
    public static let ai = Logger(subsystem: subsystem, category: "AI")
    public static let world = Logger(subsystem: subsystem, category: "World")
#else
    public static let physics = FallbackLogger(category: "Physics")
    public static let combat = FallbackLogger(category: "Combat")
    public static let ai = FallbackLogger(category: "AI")
    public static let world = FallbackLogger(category: "World")
#endif
}

#if !canImport(os)
/// A string-interpolation type shaped like `os.Logger`'s `OSLogMessage` just
/// enough that call sites written as `"...\(value, privacy: .public)"` — the
/// house style throughout this codebase — keep compiling off-Apple without
/// editing every call site. `privacy:` is accepted and ignored: there's no
/// Console.app redaction story on Linux/Windows, so it always just interpolates.
public struct LogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral, CustomStringConvertible {
    public enum Privacy { case `public` }

    public struct StringInterpolation: StringInterpolationProtocol {
        var value = ""
        public init(literalCapacity: Int, interpolationCount: Int) { value.reserveCapacity(literalCapacity) }
        public mutating func appendLiteral(_ literal: String) { value += literal }
        public mutating func appendInterpolation<T>(_ value: T) { self.value += "\(value)" }
        public mutating func appendInterpolation<T>(_ value: T, privacy: Privacy) { self.value += "\(value)" }
    }

    public let description: String
    public init(stringLiteral value: String) { description = value }
    public init(stringInterpolation: StringInterpolation) { description = stringInterpolation.value }
}

/// Minimal stand-in for the subset of `os.Logger`'s API this module uses
/// (`.debug`/`.notice`/`.error`). Prints to stderr.
public struct FallbackLogger {
    let category: String
    public func debug(_ message: LogMessage) { FileHandle.standardError.write("[\(category)] \(message)\n".data(using: .utf8)!) }
    public func notice(_ message: LogMessage) { FileHandle.standardError.write("[\(category)] \(message)\n".data(using: .utf8)!) }
    public func error(_ message: LogMessage) { FileHandle.standardError.write("[\(category)] \(message)\n".data(using: .utf8)!) }
}
#endif
