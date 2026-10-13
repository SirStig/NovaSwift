import Foundation

/// Decoders for the classic Mac OS icon, cursor and pattern resources plug-ins carry
/// (Inside Macintosh: Toolbox Essentials / More Macintosh Toolbox, "Icon Utilities"):
///
///     ICON   32×32 1-bit, no mask (128 bytes)
///     ICN#   32×32 1-bit image + mask (256 bytes)        ics#  16×16 (64)    icm#  16×12 (48)
///     icl8 / ics8 / icm8   8-bit, Mac system 'clut' 8, masked by the same-id ICN#/ics#/icm#
///     icl4 / ics4 / icm4   4-bit, Mac system 'clut' 4, likewise
///     CURS   16×16 1-bit data + mask + hot spot (68 bytes)
///     crsr   colour cursor; its 1-bit data + mask (offsets 0x12/0x32) are shown
///     PAT    8×8 1-bit (8 bytes)                          PAT#  count + n × 8
///
/// Output is a one-frame `SpriteSheet` (PAT# is one frame per pattern). The game never
/// reads any of these; this exists so the editor can show them instead of hex.
public enum ClassicIcon {
    public enum Failure: Swift.Error { case unsupported, truncated }

    /// Resource types this decoder understands.
    public static let types: Set<FourCharCode> = Set(
        ["ICON", "ICN#", "ics#", "icm#", "icl8", "ics8", "icm8", "icl4", "ics4", "icm4", "CURS", "crsr", "PAT ", "PAT#"]
            .compactMap { FourCharCode($0) })

    /// The 1-bit mask resource that masks a colour icon of `type` (same id), if any.
    public static func maskType(for type: FourCharCode) -> FourCharCode? {
        switch type.stringValue {
        case "icl8", "icl4": return FourCharCode("ICN#")
        case "ics8", "ics4": return FourCharCode("ics#")
        case "icm8", "icm4": return FourCharCode("icm#")
        default: return nil
        }
    }

    /// The classic 16-colour system palette ('clut' 4), RGB triples.
    public static let mac16Palette: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFC, 0xF3, 0x05, 0xFF, 0x64, 0x02, 0xDD, 0x08, 0x06,
        0xF2, 0x08, 0x84, 0x46, 0x00, 0xA5, 0x00, 0x00, 0xD4, 0x02, 0xAB, 0xEA,
        0x1F, 0xB7, 0x14, 0x00, 0x64, 0x11, 0x56, 0x2C, 0x05, 0x90, 0x71, 0x3A,
        0xC0, 0xC0, 0xC0, 0x80, 0x80, 0x80, 0x40, 0x40, 0x40, 0x00, 0x00, 0x00,
    ]

    /// Decode `data` as `type`. `mask` is the companion 1-bit icon list (image + mask) for
    /// colour icons; without it they draw fully opaque.
    public static func decode(type: FourCharCode, data: Data, mask: Data? = nil) throws -> SpriteSheet {
        let b = [UInt8](data)
        switch type.stringValue {
        case "ICON": return try oneBit(b, w: 32, h: 32, maskAt: nil)
        case "ICN#": return try oneBit(b, w: 32, h: 32, maskAt: 128)
        case "ics#": return try oneBit(b, w: 16, h: 16, maskAt: 32)
        case "icm#": return try oneBit(b, w: 16, h: 12, maskAt: 24)
        case "CURS": return try oneBit(b, w: 16, h: 16, maskAt: 32)
        case "crsr":
            // CCrsr: crsrType, crsrMap, crsrData, crsrXData, crsrXValid, crsrXHandle (0x12 bytes),
            // then crsr1Data[16] and crsrMask[16].
            guard b.count >= 0x52 else { throw Failure.truncated }
            return try oneBit(Array(b[0x12...]), w: 16, h: 16, maskAt: 32)
        case "icl8": return try indexed(b, w: 32, h: 32, depth: 8, mask: mask)
        case "ics8": return try indexed(b, w: 16, h: 16, depth: 8, mask: mask)
        case "icm8": return try indexed(b, w: 16, h: 12, depth: 8, mask: mask)
        case "icl4": return try indexed(b, w: 32, h: 32, depth: 4, mask: mask)
        case "ics4": return try indexed(b, w: 16, h: 16, depth: 4, mask: mask)
        case "icm4": return try indexed(b, w: 16, h: 12, depth: 4, mask: mask)
        case "PAT ": return try patterns(b, count: 1, at: 0)
        case "PAT#":
            guard b.count >= 2 else { throw Failure.truncated }
            return try patterns(b, count: Int(b[0]) << 8 | Int(b[1]), at: 2)
        default: throw Failure.unsupported
        }
    }

    private static func bit(_ b: [UInt8], _ base: Int, rowBytes: Int, x: Int, y: Int) -> Bool {
        b[base + y * rowBytes + x / 8] & (0x80 >> (x % 8)) != 0
    }

    private static func sheet(w: Int, h: Int, frames: Int = 1, rgba: [UInt8]) -> SpriteSheet {
        let cols = min(SpriteSheet.framesPerRow, frames), rows = (frames + SpriteSheet.framesPerRow - 1) / SpriteSheet.framesPerRow
        return SpriteSheet(frameWidth: w, frameHeight: h, frameCount: frames, columns: cols, rows: rows,
                           surfaceWidth: w * cols, surfaceHeight: h * rows, rgba: rgba)
    }

    /// 1 = black, 0 = white; with a mask, mask 0 is transparent.
    private static func oneBit(_ b: [UInt8], w: Int, h: Int, maskAt: Int?) throws -> SpriteSheet {
        let rowBytes = w / 8, plane = rowBytes * h
        guard b.count >= (maskAt ?? 0) + plane else { throw Failure.truncated }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let v: UInt8 = bit(b, 0, rowBytes: rowBytes, x: x, y: y) ? 0 : 0xFF
            let o = (y * w + x) * 4
            out[o] = v; out[o + 1] = v; out[o + 2] = v
            out[o + 3] = maskAt.map { bit(b, $0, rowBytes: rowBytes, x: x, y: y) } ?? true ? 0xFF : 0
        } }
        return sheet(w: w, h: h, rgba: out)
    }

    private static func indexed(_ b: [UInt8], w: Int, h: Int, depth: Int, mask: Data?) throws -> SpriteSheet {
        let rowBytes = w * depth / 8
        guard b.count >= rowBytes * h else { throw Failure.truncated }
        let pal = depth == 8 ? RLE8.macSystemPalette : mac16Palette
        // The mask is the second plane of the companion icon list.
        let m = mask.map([UInt8].init), mRow = w / 8, mBase = mRow * h
        let useMask = (m?.count ?? 0) >= mBase * 2
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let idx: Int
            if depth == 8 { idx = Int(b[y * rowBytes + x]) }
            else { let byte = b[y * rowBytes + x / 2]; idx = Int(x % 2 == 0 ? byte >> 4 : byte & 0x0F) }
            let o = (y * w + x) * 4
            out[o] = pal[idx * 3]; out[o + 1] = pal[idx * 3 + 1]; out[o + 2] = pal[idx * 3 + 2]
            out[o + 3] = !useMask || bit(m!, mBase, rowBytes: mRow, x: x, y: y) ? 0xFF : 0
        } }
        return sheet(w: w, h: h, rgba: out)
    }

    /// Each pattern is one 8×8 frame.
    private static func patterns(_ b: [UInt8], count: Int, at start: Int) throws -> SpriteSheet {
        guard count > 0, count < 4096, b.count >= start + count * 8 else { throw Failure.truncated }
        let s = sheet(w: 8, h: 8, frames: count, rgba: [])
        var out = [UInt8](repeating: 0, count: s.surfaceWidth * s.surfaceHeight * 4)
        for i in 0..<count {
            let ox = (i % SpriteSheet.framesPerRow) * 8, oy = (i / SpriteSheet.framesPerRow) * 8
            for y in 0..<8 { for x in 0..<8 {
                let v: UInt8 = bit(b, start + i * 8, rowBytes: 1, x: x, y: y) ? 0 : 0xFF
                let o = ((oy + y) * s.surfaceWidth + ox + x) * 4
                out[o] = v; out[o + 1] = v; out[o + 2] = v; out[o + 3] = 0xFF
            } }
        }
        return SpriteSheet(frameWidth: 8, frameHeight: 8, frameCount: count, columns: s.columns, rows: s.rows,
                           surfaceWidth: s.surfaceWidth, surfaceHeight: s.surfaceHeight, rgba: out)
    }
}
