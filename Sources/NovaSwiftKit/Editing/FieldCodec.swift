import Foundation

/// Big-endian read/write of schema fields at their byte offsets. Reads are
/// bounds-safe (missing bytes read as zero, matching the loader's zero-padding);
/// writes grow the record with zeros when needed. Writing the value just read
/// never changes a byte: strings only touch the bytes they own and colours
/// keep their high byte, so round-trips of real data are exact.
public enum FieldCodec {

    // MARK: Raw integers

    public static func readUInt(_ d: Data, _ off: Int, _ width: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<width {
            let p = off + i
            v = (v << 8) | (p >= 0 && p < d.count ? UInt64(d[d.startIndex + p]) : 0)
        }
        return v
    }

    public static func readInt(_ d: Data, _ off: Int, _ width: Int, signed: Bool) -> Int {
        let u = readUInt(d, off, width)
        guard signed else { return Int(u) }
        let bits = UInt64(width * 8)
        let sign = UInt64(1) << (bits - 1)
        return u & sign != 0 ? Int(Int64(bitPattern: u) - Int64(1 << bits)) : Int(u)
    }

    public static func writeUInt(_ d: inout Data, _ off: Int, _ width: Int, _ value: UInt64) {
        ensure(&d, off + width)
        for i in 0..<width {
            d[d.startIndex + off + i] = UInt8(truncatingIfNeeded: value >> UInt64(8 * (width - 1 - i)))
        }
    }

    static func ensure(_ d: inout Data, _ size: Int) {
        if d.count < size { d.append(Data(count: size - d.count)) }
    }

    // MARK: Strings

    public static func readCString(_ d: Data, _ off: Int, _ maxLen: Int) -> String {
        var bytes: [UInt8] = []
        var i = off
        while i < off + maxLen, i >= 0, i < d.count {
            let b = d[d.startIndex + i]
            if b == 0 { break }
            bytes.append(b); i += 1
        }
        return String(macRoman: bytes)
    }

    /// Encode as Mac Roman, replacing unmappable characters with `?`.
    public static func macRoman(_ s: String) -> [UInt8] {
        if let d = MacRoman.encode(s) { return d }
        return s.flatMap { ch -> [UInt8] in MacRoman.encode(String(ch)) ?? [0x3F] }
    }

    static func writeCString(_ d: inout Data, _ off: Int, _ size: Int, _ s: String) {
        ensure(&d, off + size)
        let bytes = Array(macRoman(s).prefix(max(0, size - 1)))
        // Clear only what the old string occupied (plus its NUL), so unrelated
        // trailing bytes in the field are never disturbed.
        var oldLen = 0
        while oldLen < size, d[d.startIndex + off + oldLen] != 0 { oldLen += 1 }
        for (i, b) in bytes.enumerated() { d[d.startIndex + off + i] = b }
        var i = bytes.count
        d[d.startIndex + off + i] = 0   // always terminate (bytes.count < size by construction)
        i += 1
        while i <= oldLen, i < size { d[d.startIndex + off + i] = 0; i += 1 }
    }

    static func readPString(_ d: Data, _ off: Int, _ size: Int) -> String {
        guard off >= 0, off < d.count else { return "" }
        let n = min(Int(d[d.startIndex + off]), size - 1, max(0, d.count - off - 1))
        let slice = d[(d.startIndex + off + 1)..<(d.startIndex + off + 1 + n)]
        return String(macRoman: slice)
    }

    static func writePString(_ d: inout Data, _ off: Int, _ size: Int, _ s: String) {
        ensure(&d, off + size)
        let bytes = Array(macRoman(s).prefix(max(0, min(255, size - 1))))
        let oldLen = min(Int(d[d.startIndex + off]), size - 1)
        d[d.startIndex + off] = UInt8(bytes.count)
        for (i, b) in bytes.enumerated() { d[d.startIndex + off + 1 + i] = b }
        var i = bytes.count
        while i < oldLen { d[d.startIndex + off + 1 + i] = 0; i += 1 }
    }

    // MARK: Fields

    public static func read(_ f: SchemaField, from d: Data) -> FieldValue {
        if f.isArray {
            return .array((0..<f.count).map { readElement(f.kind, from: d, at: f.offset + $0 * f.stride) })
        }
        return readElement(f.kind, from: d, at: f.offset)
    }

    public static func write(_ value: FieldValue, field f: SchemaField, into d: inout Data) {
        if f.isArray {
            guard case let .array(items) = value else { return }
            for i in 0..<f.count {
                writeElement(i < items.count ? items[i] : zero(f.kind), kind: f.kind, into: &d, at: f.offset + i * f.stride)
            }
        } else {
            writeElement(value, kind: f.kind, into: &d, at: f.offset)
        }
    }

    static func zero(_ kind: FieldKind) -> FieldValue {
        switch kind {
        case .cString, .pString, .ncb: return .string("")
        case .color: return .color(r: 0, g: 0, b: 0)
        case .blob(let n): return .bytes(Data(count: n))
        case .point: return .point(0, 0)
        case .rect: return .rect(0, 0, 0, 0)
        case .mask64: return .uint64(0)
        default: return .int(0)
        }
    }

    static func readElement(_ kind: FieldKind, from d: Data, at off: Int) -> FieldValue {
        switch kind {
        case let .int(w, signed), let .enumeration(w, signed):
            return .int(readInt(d, off, w.rawValue, signed: signed))
        case let .flags(w):
            return .int(Int(readUInt(d, off, w.rawValue)))
        case .ref:
            return .int(readInt(d, off, 2, signed: true))
        case let .bits(w, shift, width):
            return .int(Int((readUInt(d, off, w.rawValue) >> UInt64(shift)) & ((1 << UInt64(width)) - 1)))
        case let .cString(n), let .ncb(_, n):
            return .string(readCString(d, off, n))
        case let .pString(n):
            return .string(readPString(d, off, n))
        case .color:
            return .color(r: UInt8(readUInt(d, off + 1, 1)), g: UInt8(readUInt(d, off + 2, 1)), b: UInt8(readUInt(d, off + 3, 1)))
        case let .blob(n):
            let lo = max(0, min(off, d.count)), hi = max(lo, min(off + n, d.count))
            var out = Data(d[(d.startIndex + lo)..<(d.startIndex + hi)])
            if out.count < n { out.append(Data(count: n - out.count)) }
            return .bytes(out)
        case .point:
            return .point(readInt(d, off, 2, signed: true), readInt(d, off + 2, 2, signed: true))
        case .rect:
            return .rect(readInt(d, off, 2, signed: true), readInt(d, off + 2, 2, signed: true),
                         readInt(d, off + 4, 2, signed: true), readInt(d, off + 6, 2, signed: true))
        case .mask64:
            return .uint64(readUInt(d, off, 8))
        }
    }

    static func writeElement(_ value: FieldValue, kind: FieldKind, into d: inout Data, at off: Int) {
        switch (kind, value) {
        case let (.int(w, _), .int(v)), let (.enumeration(w, _), .int(v)), let (.flags(w), .int(v)):
            writeUInt(&d, off, w.rawValue, UInt64(truncatingIfNeeded: v))
        case let (.ref, .int(v)):
            writeUInt(&d, off, 2, UInt64(truncatingIfNeeded: v))
        case let (.bits(w, shift, width), .int(v)):
            let mask = ((UInt64(1) << UInt64(width)) - 1) << UInt64(shift)
            let old = readUInt(d, off, w.rawValue)
            writeUInt(&d, off, w.rawValue, (old & ~mask) | ((UInt64(truncatingIfNeeded: v) << UInt64(shift)) & mask))
        case let (.cString(n), .string(s)), let (.ncb(_, n), .string(s)):
            writeCString(&d, off, n, s)
        case let (.pString(n), .string(s)):
            writePString(&d, off, n, s)
        case let (.color, .color(r, g, b)):
            writeUInt(&d, off + 1, 1, UInt64(r)); writeUInt(&d, off + 2, 1, UInt64(g)); writeUInt(&d, off + 3, 1, UInt64(b))
        case let (.blob(n), .bytes(b)):
            ensure(&d, off + n)
            for i in 0..<n { d[d.startIndex + off + i] = i < b.count ? b[b.startIndex + i] : 0 }
        case let (.point, .point(x, y)):
            writeUInt(&d, off, 2, UInt64(truncatingIfNeeded: x)); writeUInt(&d, off + 2, 2, UInt64(truncatingIfNeeded: y))
        case let (.rect, .rect(a, b, c, e)):
            for (i, v) in [a, b, c, e].enumerated() { writeUInt(&d, off + i * 2, 2, UInt64(truncatingIfNeeded: v)) }
        case let (.mask64, .uint64(v)):
            writeUInt(&d, off, 8, v)
        default:
            break // value shape doesn't match the field; ignore rather than corrupt
        }
    }
}

extension FieldValue {
    /// `#RRGGBB` for colours, handy for UI and tests.
    public var hexColor: String? {
        if case let .color(r, g, b) = self { return String(format: "#%02X%02X%02X", r, g, b) }
        return nil
    }
}
