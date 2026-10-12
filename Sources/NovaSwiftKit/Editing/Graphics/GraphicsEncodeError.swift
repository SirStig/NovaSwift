import Foundation

/// Failure of one of the editor's graphics/sound encoders or importers.
public enum GraphicsEncodeError: Swift.Error, CustomStringConvertible, Equatable {
    /// Width/height/frame count that can't be encoded (zero, too large, mismatched).
    case badGeometry(String)
    /// The RGBA buffer is not `width * height * 4` bytes.
    case bufferSize(expected: Int, actual: Int)
    /// A feature this encoder deliberately does not cover.
    case unsupported(String)
    /// An input file/buffer that could not be parsed.
    case badInput(String)

    public var description: String {
        switch self {
        case let .badGeometry(m): return "bad image geometry: \(m)"
        case let .bufferSize(e, a): return "RGBA buffer is \(a) bytes, expected \(e)"
        case let .unsupported(m): return "unsupported: \(m)"
        case let .badInput(m): return "bad input: \(m)"
        }
    }
}

/// Shared colour helpers for the encoders.
enum GfxColor {
    /// 8-bit channel -> 5 bits, rounded. Exact inverse of the decoders' 5->8
    /// expansion `(v << 3) | (v >> 2)`.
    @inline(__always) static func to5(_ v: UInt8) -> UInt16 { UInt16((Int(v) * 31 + 127) / 255) }

    /// 5-bit channel -> 8 bits exactly as `RLED.decode` / `PICT.decode` expand it.
    @inline(__always) static func from5(_ v: UInt16) -> UInt8 { UInt8((v << 3) | (v >> 2)) }

    @inline(__always) static func pack555(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt16 {
        (to5(r) << 10) | (to5(g) << 5) | to5(b)
    }
}

extension Array where Element == UInt8 {
    @inline(__always) mutating func appendBE16(_ v: Int) {
        append(UInt8(truncatingIfNeeded: v >> 8)); append(UInt8(truncatingIfNeeded: v))
    }
    @inline(__always) mutating func appendBE32(_ v: Int) {
        append(UInt8(truncatingIfNeeded: v >> 24)); append(UInt8(truncatingIfNeeded: v >> 16))
        append(UInt8(truncatingIfNeeded: v >> 8)); append(UInt8(truncatingIfNeeded: v))
    }
}
