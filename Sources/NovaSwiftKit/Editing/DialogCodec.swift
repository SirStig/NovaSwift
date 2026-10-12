import Foundation

/// Byte-level editing and encoding for `DITL` / `DLOG`, the inverse of
/// `DITLRes` / `DLOGRes` (DialogModels.swift). The walk below mirrors the
/// decoder exactly — same item sizes, same even-offset padding, same "unknown
/// kinds build no item" rule — so item indices mean the same thing in both.
///
/// Editing a rectangle patches the 8 rect bytes in place (`setRect`), which
/// leaves everything else in the resource (payload padding, stray length bytes
/// on user items, trailing data) byte-identical. `encode` builds a list from
/// scratch for the cases where items are added or removed.
public enum DialogCodec {

    /// The DITL type byte (without the disabled bit) for a kind; nil for unknown kinds.
    public static func rawType(of kind: DITLItemKind) -> Int? {
        switch kind {
        case .userItem: return 0
        case .button: return 4
        case .checkbox: return 5
        case .resControl: return 7
        case .statText: return 8
        case .editText: return 16
        case .icon: return 32
        case .picture: return 64
        case .unknown: return nil
        }
    }

    /// Start offset (the 4-byte handle placeholder) of every item the game builds,
    /// in item-index order.
    public static func itemOffsets(in d: Data) -> [Int] {
        guard d.count >= 2 else { return [] }
        let base = d.startIndex
        func u8(_ off: Int) -> Int { Int(d[base + off]) }
        let raw = (u8(0) << 8) | u8(1)
        let count = (raw >= 0x8000 ? raw - 0x10000 : raw) + 1
        guard count > 0 else { return [] }
        var out: [Int] = []
        var off = 2
        for _ in 0..<count {
            guard off + 14 <= d.count else { break }
            let rawType = u8(off + 12), length = u8(off + 13)
            var next: Int
            switch rawType & 0x7F {
            case 4, 5, 6, 8, 16:
                guard off + 14 + length <= d.count else { return out }
                next = off + 14 + length
            case 7, 32, 64:
                guard off + 16 <= d.count else { return out }
                next = off + 16
            default:
                next = off + 14
            }
            if next % 2 == 1 { next += 1 }
            if case .unknown = DITLItemKind(rawType: rawType) {} else { out.append(off) }
            off = next
        }
        return out
    }

    /// `data` with item `index`'s rectangle replaced; nil if the index doesn't exist.
    public static func setRect(_ rect: NovaRect, ofItem index: Int, in data: Data) -> Data? {
        let offsets = itemOffsets(in: data)
        guard offsets.indices.contains(index) else { return nil }
        var d = data
        write(rect, at: offsets[index] + 4, into: &d)
        return d
    }

    /// `data` (a `DLOG`) with its window bounds replaced; nil if it's too short.
    public static func setBounds(_ rect: NovaRect, inDLOG data: Data) -> Data? {
        guard data.count >= 8 else { return nil }
        var d = data
        write(rect, at: 0, into: &d)
        return d
    }

    /// A full `DITL` for `items` (unknown kinds are dropped). Decoding the result
    /// yields the same rects, kinds, enabled flags, text and resource ids.
    public static func encode(items: [DITLItem]) -> Data {
        let kept = items.filter { rawType(of: $0.kind) != nil }
        var d = Data()
        let n = UInt64(truncatingIfNeeded: kept.count - 1)   // "count minus one"
        d.append(UInt8(truncatingIfNeeded: n >> 8)); d.append(UInt8(truncatingIfNeeded: n))
        for item in kept {
            guard let raw = rawType(of: item.kind) else { continue }
            d.append(contentsOf: [0, 0, 0, 0])
            let at = d.count
            d.append(Data(count: 8))
            write(item.rect, at: at, into: &d)
            d.append(UInt8(raw | (item.isEnabled ? 0 : 0x80)))
            switch item.kind {
            case .button, .checkbox, .statText, .editText:
                let bytes = Array(FieldCodec.macRoman(item.text).prefix(255))
                d.append(UInt8(bytes.count)); d.append(contentsOf: bytes)
            case .resControl, .icon, .picture:
                d.append(2)
                let id = UInt64(truncatingIfNeeded: item.resourceID ?? 0)
                d.append(UInt8(truncatingIfNeeded: id >> 8)); d.append(UInt8(truncatingIfNeeded: id))
            default:
                d.append(0)   // user items: the game reads a fixed 14 bytes
            }
            if d.count % 2 == 1 { d.append(0) }
        }
        return d
    }

    private static func write(_ r: NovaRect, at off: Int, into d: inout Data) {
        for (i, v) in [r.top, r.left, r.bottom, r.right].enumerated() {
            FieldCodec.writeUInt(&d, off + i * 2, 2, UInt64(truncatingIfNeeded: v))
        }
    }
}
