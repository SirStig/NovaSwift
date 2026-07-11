import Foundation

/// Sequential reader over an in-memory byte buffer, with per-call endianness
/// control and a small position stack. EV Nova containers mix endianness
/// (the Rez container is little-endian but its resource map is big-endian),
/// so every integer read can override the reader's default byte order.
public final class BinaryReader {
    public enum Error: Swift.Error, CustomStringConvertible {
        case outOfBounds(position: Int, need: Int, count: Int)
        public var description: String {
            switch self {
            case let .outOfBounds(position, need, count):
                return "BinaryReader out of bounds: at \(position) need \(need) of \(count)"
            }
        }
    }

    public let bytes: [UInt8]
    public private(set) var position: Int = 0
    /// Default byte order used when a read does not specify one.
    public var bigEndian: Bool
    private var stack: [Int] = []

    public init(_ data: Data, bigEndian: Bool = true) {
        self.bytes = [UInt8](data)
        self.bigEndian = bigEndian
    }

    public var count: Int { bytes.count }
    public var remaining: Int { bytes.count - position }

    // MARK: Positioning

    public func seek(_ newPosition: Int) throws {
        guard newPosition >= 0, newPosition <= bytes.count else {
            throw Error.outOfBounds(position: newPosition, need: 0, count: bytes.count)
        }
        position = newPosition
    }

    public func advance(_ n: Int) throws { try seek(position + n) }

    /// Save the current position, then jump to `newPosition`. Restore with `popPosition()`.
    public func pushPosition(_ newPosition: Int) throws {
        stack.append(position)
        try seek(newPosition)
    }

    public func popPosition() {
        position = stack.removeLast()
    }

    // MARK: Primitive reads

    private func requireBytes(_ n: Int) throws {
        guard position + n <= bytes.count else {
            throw Error.outOfBounds(position: position, need: n, count: bytes.count)
        }
    }

    public func readU8() throws -> UInt8 {
        try requireBytes(1)
        defer { position += 1 }
        return bytes[position]
    }

    public func readU16(bigEndian override: Bool? = nil) throws -> UInt16 {
        try requireBytes(2)
        let be = override ?? bigEndian
        let b0 = UInt16(bytes[position]), b1 = UInt16(bytes[position + 1])
        position += 2
        return be ? (b0 << 8 | b1) : (b1 << 8 | b0)
    }

    public func readU32(bigEndian override: Bool? = nil) throws -> UInt32 {
        try requireBytes(4)
        let be = override ?? bigEndian
        let b0 = UInt32(bytes[position]), b1 = UInt32(bytes[position + 1])
        let b2 = UInt32(bytes[position + 2]), b3 = UInt32(bytes[position + 3])
        position += 4
        return be ? (b0 << 24 | b1 << 16 | b2 << 8 | b3)
                  : (b3 << 24 | b2 << 16 | b1 << 8 | b0)
    }

    public func readI16(bigEndian override: Bool? = nil) throws -> Int16 {
        Int16(bitPattern: try readU16(bigEndian: override))
    }

    public func readI32(bigEndian override: Bool? = nil) throws -> Int32 {
        Int32(bitPattern: try readU32(bigEndian: override))
    }

    public func readBytes(_ n: Int) throws -> [UInt8] {
        try requireBytes(n)
        defer { position += n }
        return Array(bytes[position..<position + n])
    }

    public func readData(_ n: Int) throws -> Data {
        Data(try readBytes(n))
    }

    /// A four-byte tag (resource type / OSType), preserving the raw bytes.
    public func readFourCharCode() throws -> FourCharCode {
        FourCharCode(bytes: try readBytes(4))
    }

    /// Classic Pascal string: one length byte followed by that many Mac Roman bytes.
    public func readPString() throws -> String {
        let length = Int(try readU8())
        let raw = try readData(length)
        return String(data: raw, encoding: .macOSRoman) ?? ""
    }

    /// NUL-terminated Mac Roman C string read from a fixed-size field. Stops at the
    /// first NUL or after `limit` bytes; does not itself advance past the field.
    public func readCString(limit: Int) throws -> String {
        try requireBytes(0)
        var out: [UInt8] = []
        var i = 0
        while i < limit, position < bytes.count {
            let b = bytes[position]
            position += 1
            i += 1
            if b == 0 { break }
            out.append(b)
        }
        return String(data: Data(out), encoding: .macOSRoman) ?? ""
    }
}
