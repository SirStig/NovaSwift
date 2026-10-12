import Foundation

// Prose spec (no decompiled code is reproduced here).
//
// `rlë8` is the 8-bit, palette-indexed twin of `rlëD`. Ground truth from the original
// executable (Ghidra addresses, ~/Projects/evnova-re):
//  - 0x00474e90 Sprite_CreateFromMultiFrameResource asks the main display device for its
//    depth (0x0047b7c0) and loads resource type 0x726c9138 ('rl' 0x91 '8', i.e. rlë8) ONLY when
//    the depth is exactly 8; every other depth loads 0x726c9144 (rlëD). So the original never
//    touches an rlë8 on a 16/32-bit display, and NovaSwift (always direct colour) therefore
//    correctly ignores rlë8 in-game. This decoder exists for the editor preview / tools.
//  - The header is shared with rlëD: width, height, bit depth, palette id, frame count (u16 each,
//    big-endian; offsets 0/2/4/6/8), 6 reserved bytes = 16 bytes. The frame loop at 0x00474e90
//    reads the same fields for both depths.
//  - 0x00472190 SpriteRleCommandStream_SkipToRowCount shows the stream grammar shared by both
//    depths: 32-bit tokens, opcode = high byte, count = low 24 bits. 0 = end of frame,
//    1 = line start (count = byte length of that row's body, so a reader can skip the row),
//    2 = literal pixels (count bytes inline, then padded to a 4-byte boundary),
//    3 = transparent run (count bytes of skipped pixels). Opcode 4 (repeat of a 4-byte pattern)
//    is handled by the rlëD loader in the same family (evnova-decomp rle_sprite_sheet.cpp).
//  - For 8-bit, one byte is one pixel, so counts are pixel counts. Opcode 4 is read as a 4-byte
//    pattern cycled across `count` pixels (the 8-bit analogue of the 16-bit two-pixel pattern).
//    NOTE: opcode 4 for 8-bit and the exact palette are inferred, not observed: no rlë8 ships
//    in Nova.rez or any available plug-in.
//  - Palette: the original draws through the device colour table of the 8-bit screen (the
//    Mac system palette, 'clut' 8). Index 0 is white and 255 is black in that table. The header
//    palette id is carried but not interpreted. Callers can pass a custom 256-entry palette.

/// Decoder for EV Nova `rlë8` (8-bit palette-indexed RLE sprite sheets). Produces the same
/// `SpriteSheet` (6-wide frame grid, top-left RGBA8) as `RLED.decode`.
public enum RLE8 {

    /// Header fields without decoding the body.
    public struct Header: Equatable, Sendable {
        public var width: Int, height: Int, depth: Int, paletteID: Int, frameCount: Int
    }

    public static func header(_ data: Data) -> Header? {
        guard data.count >= 16 else { return nil }
        let b = [UInt8](data.prefix(10))
        func i16(_ o: Int) -> Int { Int(Int16(bitPattern: UInt16(b[o]) << 8 | UInt16(b[o + 1]))) }
        return Header(width: i16(0), height: i16(2), depth: i16(4), paletteID: i16(6), frameCount: i16(8))
    }

    /// The classic Mac OS 8-bit system colour table as 256 packed RGB triples (768 bytes):
    /// indices 0-214 are the 6x6x6 cube from white downwards (black omitted), 215-224 reds,
    /// 225-234 greens, 235-244 blues, 245-254 greys (each ramp EE DD BB AA 88 77 55 44 22 11)
    /// and 255 black.
    public static let macSystemPalette: [UInt8] = {
        var p = [UInt8](); p.reserveCapacity(768)
        let levels: [UInt8] = [0xFF, 0xCC, 0x99, 0x66, 0x33, 0x00]
        for r in levels { for g in levels { for b in levels {
            if r == 0, g == 0, b == 0 { continue }
            p.append(r); p.append(g); p.append(b)
        } } }
        let ramp: [UInt8] = [0xEE, 0xDD, 0xBB, 0xAA, 0x88, 0x77, 0x55, 0x44, 0x22, 0x11]
        for v in ramp { p.append(v); p.append(0); p.append(0) }
        for v in ramp { p.append(0); p.append(v); p.append(0) }
        for v in ramp { p.append(0); p.append(0); p.append(v) }
        for v in ramp { p.append(v); p.append(v); p.append(v) }
        p.append(0); p.append(0); p.append(0)
        return p
    }()

    /// Decode a whole `rlë8` resource. `palette` is 768 bytes of RGB (defaults to the Mac
    /// system palette).
    public static func decode(_ data: Data, palette: [UInt8]? = nil) throws -> SpriteSheet {
        let pal = palette ?? macSystemPalette
        guard pal.count >= 768 else { throw ResourceFileError.corrupt("rlë8 palette needs 256 RGB entries") }
        guard let h = header(data) else { throw ResourceFileError.corrupt("rlë8 header truncated") }
        guard h.depth == 8 else { throw ResourceFileError.corrupt("rlë8 colour depth \(h.depth) unsupported (only 8-bit)") }
        let width = h.width, height = h.height, frameCount = h.frameCount
        guard width > 0, height > 0, frameCount > 0, width < 4096, height < 4096 else {
            throw ResourceFileError.corrupt("rlë8 implausible geometry \(width)x\(height) × \(frameCount)")
        }
        let columns = min(SpriteSheet.framesPerRow, frameCount)
        let rows = (frameCount + SpriteSheet.framesPerRow - 1) / SpriteSheet.framesPerRow
        let surfaceWidth = columns * width, surfaceHeight = rows * height
        var rgba = [UInt8](repeating: 0, count: surfaceWidth * surfaceHeight * 4)

        let bytes = [UInt8](data)
        var pos = 16
        var frame = 0, line = -1, x = 0
        var base = 0                         // pixel index of the current row start in the surface

        @inline(__always) func put(_ index: UInt8) {
            guard x >= 0, x < width, line >= 0, line < height else { x += 1; return }
            let o = (base + x) * 4, p = Int(index) * 3
            if o + 3 < rgba.count {
                rgba[o] = pal[p]; rgba[o + 1] = pal[p + 1]; rgba[o + 2] = pal[p + 2]; rgba[o + 3] = 255
            }
            x += 1
        }

        loop: while pos + 4 <= bytes.count {
            let token = UInt32(bytes[pos]) << 24 | UInt32(bytes[pos + 1]) << 16 | UInt32(bytes[pos + 2]) << 8 | UInt32(bytes[pos + 3])
            pos += 4
            let count = Int(token & 0x00FF_FFFF)
            switch token >> 24 {
            case 0:
                frame += 1; line = -1
                if frame >= frameCount { break loop }
            case 1:
                line += 1; x = 0
                base = ((frame / SpriteSheet.framesPerRow) * height + line) * surfaceWidth
                    + (frame % SpriteSheet.framesPerRow) * width
            case 2:
                guard pos + count <= bytes.count else { throw ResourceFileError.corrupt("rlë8 literal run overruns data") }
                for k in 0..<count { put(bytes[pos + k]) }
                pos += (count + 3) & ~3
            case 3:
                x += count
            case 4:
                guard pos + 4 <= bytes.count else { throw ResourceFileError.corrupt("rlë8 pattern run overruns data") }
                for k in 0..<count { put(bytes[pos + (k & 3)]) }
                pos += 4
            default:
                throw ResourceFileError.corrupt("unknown rlë8 opcode 0x\(String(token >> 24, radix: 16))")
            }
        }
        return SpriteSheet(frameWidth: width, frameHeight: height, frameCount: frameCount,
                           columns: columns, rows: rows,
                           surfaceWidth: surfaceWidth, surfaceHeight: surfaceHeight, rgba: rgba)
    }
}
