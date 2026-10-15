import Foundation
#if !canImport(os)
import NovaSwiftKit
#endif
#if canImport(os)
import os
#endif

/// Categorized loggers for the mission/story runtime (control bits, missions,
/// cron events, pilot persistence). On Apple platforms these are real
/// `os.Logger`s (view in Console.app/`log stream` filtered by
/// `subsystem:com.novaswift.story`, or per-category with `category:<name>`);
/// off-Apple (Linux/Windows, e.g. the Godot bridge) they fall back to a tiny
/// stderr-printing shim with the same call surface, since `os.Logger` doesn't
/// exist there.
public enum Log {
    static let subsystem = "com.novaswift.story"

#if canImport(os)
    public static let mission = Logger(subsystem: subsystem, category: "Mission")
    public static let ncb = Logger(subsystem: subsystem, category: "NCB")
    public static let pilot = Logger(subsystem: subsystem, category: "Pilot")
#else
    public static let mission = FallbackLogger(category: "Mission")
    public static let ncb = FallbackLogger(category: "NCB")
    public static let pilot = FallbackLogger(category: "Pilot")
#endif
}

// `LogTag` lives in NovaSwiftEngine (a dependency of this module).

#if !canImport(os)
/// A string-interpolation type shaped like `os.Logger`'s `OSLogMessage` just
/// enough that call sites written as `"...\(value, privacy: .public)"` — the
/// house style throughout this codebase — keep compiling off-Apple without
/// editing every call site. `privacy:` is accepted and ignored: there's no
/// Console.app redaction story on Linux/Windows, so it always just interpolates.
///
/// `format:` is honoured rather than ignored, since dropping it would change
/// what the message *says* (`aimError=0.21` vs `aimError=0.2145873`), not just
/// how it's redacted. Only the shapes `os.Logger` actually offers and this
/// codebase actually reaches for are modelled — enough that adding a formatted
/// log line can't break the Linux/Windows build, which is exactly how the two
/// `.fixed(precision:)` sites in `AIBrain`/`Spawner` took every job in the
/// Godot CI workflow down with "extra argument 'format' in call".
public struct LogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral, CustomStringConvertible, Sendable {
    public enum Privacy: Sendable { case `public` }

    /// Stand-in for `OSLogFloatFormatting`, modelled as a struct with static
    /// members for the same reason the real one is: `.fixed` and
    /// `.fixed(precision:)` are both spellings a call site may use.
    public struct FloatFormat: Sendable {
        enum Kind: Sendable { case fixed(Int?), exponential(Int?), hybrid }
        let kind: Kind
        let explicitPositiveSign: Bool

        public static let fixed = FloatFormat(kind: .fixed(nil), explicitPositiveSign: false)
        public static func fixed(precision: Int, explicitPositiveSign: Bool = false) -> FloatFormat {
            FloatFormat(kind: .fixed(precision), explicitPositiveSign: explicitPositiveSign)
        }
        public static let exponential = FloatFormat(kind: .exponential(nil), explicitPositiveSign: false)
        public static func exponential(precision: Int, explicitPositiveSign: Bool = false) -> FloatFormat {
            FloatFormat(kind: .exponential(precision), explicitPositiveSign: explicitPositiveSign)
        }
        public static let hybrid = FloatFormat(kind: .hybrid, explicitPositiveSign: false)

        /// The `String(format:)` spec this maps to.
        var spec: String {
            let sign = explicitPositiveSign ? "+" : ""
            switch kind {
            case .fixed(let p):       return "%\(sign)\(p.map { ".\(max(0, $0))" } ?? "")f"
            case .exponential(let p): return "%\(sign)\(p.map { ".\(max(0, $0))" } ?? "")e"
            case .hybrid:             return "%\(sign)g"
            }
        }
    }

    /// Stand-in for `OSLogIntegerFormatting`.
    public struct IntegerFormat: Sendable {
        let radix: Int
        public static let decimal = IntegerFormat(radix: 10)
        public static let hex = IntegerFormat(radix: 16)
        public static let octal = IntegerFormat(radix: 8)
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var value = ""
        public init(literalCapacity: Int, interpolationCount: Int) { value.reserveCapacity(literalCapacity) }
        public mutating func appendLiteral(_ literal: String) { value += literal }
        public mutating func appendInterpolation<T>(_ value: T) { self.value += "\(value)" }
        public mutating func appendInterpolation<T>(_ value: T, privacy: Privacy) { self.value += "\(value)" }

        public mutating func appendInterpolation<T: BinaryFloatingPoint>(
            _ value: T, format: FloatFormat, privacy: Privacy = .public
        ) {
            self.value += String(format: format.spec, Double(value))
        }

        public mutating func appendInterpolation<T: BinaryInteger>(
            _ value: T, format: IntegerFormat, privacy: Privacy = .public
        ) {
            self.value += String(value, radix: format.radix)
        }
    }

    public let description: String
    public init(stringLiteral value: String) { description = value }
    public init(stringInterpolation: StringInterpolation) { description = stringInterpolation.value }
}

/// Minimal stand-in for the subset of `os.Logger`'s API this module uses
/// (`.debug`/`.info`/`.notice`/`.error`/`.fault`). Prints to stderr.
public struct FallbackLogger: Sendable {
    let category: String
    private func emit(_ level: String, _ message: LogMessage) {
        let text = message.description
        #if os(Windows)
        // A double-clicked (GUI-subsystem) process has no stderr; FileHandle.write traps on it, fputs just fails.
        fputs("[\(category)] \(text)\n", stderr)
        #else
        FileHandle.standardError.write("[\(category)] \(text)\n".data(using: .utf8)!)
        #endif
        // Mirror into the debug suite's in-memory log (no-op unless a frontend installed a sink).
        DebugLogSink.emit(level: level, category: category, message: text)
    }
    public func debug(_ message: LogMessage) { emit("debug", message) }
    public func info(_ message: LogMessage) { emit("info", message) }
    public func notice(_ message: LogMessage) { emit("notice", message) }
    public func error(_ message: LogMessage) { emit("error", message) }
    public func fault(_ message: LogMessage) { emit("fault", message) }
}
#endif
