import Foundation

/// Decoder for QuickDraw `PICT` version-2 images — EV Nova's landing screens,
/// interface backgrounds, menu art and mission pictures. EV Nova is a 16-bit
/// game, so the common case is a `DirectBitsRect` opcode carrying a 1-5-5-5
/// PackBits-word PixMap; 24/32-bit direct images are also handled. Indexed
/// (`PackBitsRect`) images return nil for now.
///
/// Layout reference: Graphite `quickdraw/pict.cpp` + Inside Macintosh (Imaging).
public enum PICT {
    private static let v1Magic: UInt16 = 0x1101
    private static let v2Magic: UInt32 = 0x0011_02FF

    public static func decode(_ data: Data) throws -> SpriteSheet {
        let r = BinaryReader(data, bigEndian: true)

        // Size word (v1), then the picture frame rect (top,left,bottom,right).
        try r.advance(2)
        let top = Int(try r.readI16()), left = Int(try r.readI16())
        let bottom = Int(try r.readI16()), right = Int(try r.readI16())
        var frameW = right - left, frameH = bottom - top

        // Version. v2 begins with 0x001102FF then an extended-header opcode.
        if try r.readU16() != v1Magic { // consume; not v1
            try r.seek(r.position - 2)
            guard try r.readU32() == v2Magic else {
                throw ResourceFileError.corrupt("not a PICT v2 image")
            }
            _ = try r.readU16()            // ext header opcode (0x0C00)
            let hdr = try r.readU32()
            if (hdr >> 16) == 0xFFFE {
                try r.advance(8)           // extended header: skip 2 longs
                let t = Int(try r.readI16()), l = Int(try r.readI16())
                let b = Int(try r.readI16()), rt = Int(try r.readI16())
                frameW = rt - l; frameH = b - t
            } else {
                try r.advance(12)          // standard header: skip fixed rect remainder
            }
            try r.advance(4)               // reserved
        }

        guard frameW > 0, frameH > 0, frameW < 8192, frameH < 8192 else {
            throw ResourceFileError.corrupt("PICT implausible frame \(frameW)x\(frameH)")
        }
        var rgba = [UInt8](repeating: 0, count: frameW * frameH * 4)

        // Opcode loop — EV Nova pictures are a clip region then one bits op.
        while r.remaining >= 2 {
            let op = try r.readU16()
            switch op {
            case 0x0000: continue                        // nop
            case 0x0001: try skipRegion(r)               // clip region
            case 0x0011: try r.advance(1)                // version
            case 0x001C, 0x001E: continue                // hiliteMode / defHilite (no data)
            case 0x001A, 0x001B, 0x001D, 0x001F:         // rgb fg/bg/hilite/op colors (6 bytes)
                try r.advance(6)
            case 0x0003, 0x0004, 0x0005, 0x0008, 0x000D, 0x0015, 0x0016:
                try r.advance(2)                         // txFont/txFace/txMode/pnMode/txSize/… (2-byte)
            case 0x0007, 0x0009, 0x000B: try r.advance(4) // pnSize / ovSize / origin etc.
            case 0x00A0: try r.advance(2)                // short comment: kind
            case 0x00A1:                                 // long comment: kind + size + data
                try r.advance(2)
                let size = Int(try r.readU16())
                try r.advance(size)
            case 0x009A, 0x009B:                          // DirectBitsRect / region
                try decodeDirectBits(r, into: &rgba, frameW: frameW, frameH: frameH,
                                     hasRegion: op == 0x009B)
                return sheet(frameW, frameH, rgba)
            case 0x00FF: return sheet(frameW, frameH, rgba) // eof
            default:
                // Unknown opcode before the image — we can't skip it safely.
                throw ResourceFileError.corrupt("unsupported PICT opcode 0x\(String(op, radix: 16))")
            }
        }
        return sheet(frameW, frameH, rgba)
    }

    // MARK: DirectBitsRect (PixMap with baseAddr)

    private static func decodeDirectBits(_ r: BinaryReader, into rgba: inout [UInt8],
                                         frameW: Int, frameH: Int, hasRegion: Bool) throws {
        try r.advance(4) // baseAddr (present for DirectBits)
        var rowBytes = Int(try r.readU16() & 0x7FFF)
        let bTop = Int(try r.readI16()), bLeft = Int(try r.readI16())
        let bBottom = Int(try r.readI16()), bRight = Int(try r.readI16())
        try r.advance(2)                       // pmVersion
        var packType = Int(try r.readI16())
        try r.advance(4 + 4 + 4)               // packSize, hRes, vRes
        try r.advance(2)                       // pixelType
        let pixelSize = Int(try r.readI16())
        let cmpCount = Int(try r.readI16())
        try r.advance(2)                       // cmpSize
        try r.advance(4 + 4 + 4)               // planeBytes, pmTable, pmExtension

        // Source & destination rects, transfer mode.
        try r.advance(8 + 8 + 2)
        if hasRegion { try skipRegion(r) }

        let width = bRight - bLeft
        let height = bBottom - bTop
        guard width > 0, height > 0, width <= frameW + 8, height <= frameH + 8 else {
            throw ResourceFileError.corrupt("PICT pixmap bounds \(width)x\(height)")
        }

        let packed = rowBytes >= 8 && packType >= 3
        if !packed {
            // Unpacked pixels: the on-disk format follows the pixel depth, not the
            // pack type. Small images (rowBytes < 8, e.g. a 2px button-middle slice)
            // are never packed — treating a 16-bit one as 32-bit argb turns it
            // magenta, which is what made every three-slice button purple.
            switch pixelSize {
            case 16: packType = 3; rowBytes = width * 2   // 1-5-5-5 words
            case 24: packType = 2; rowBytes = width * 3   // rgb
            case 32: packType = 1                         // argb (rowBytes already width*4)
            default: break
            }
        }

        for y in 0..<height {
            let row: [UInt8]
            if packed {
                let n = rowBytes > 250 ? Int(try r.readU16()) : Int(try r.readU8())
                let packedData = try r.readBytes(n)
                row = packbits(packedData, valueSize: packType == 3 ? 2 : 1)
            } else {
                row = try r.readBytes(rowBytes)
            }
            guard y < frameH else { continue }
            writeRow(row, y: y, width: min(width, frameW), packType: packType,
                     cmpCount: cmpCount, pixelSize: pixelSize, frameW: frameW, into: &rgba)
        }
    }

    private static func writeRow(_ row: [UInt8], y: Int, width: Int, packType: Int,
                                 cmpCount: Int, pixelSize: Int, frameW: Int, into rgba: inout [UInt8]) {
        for x in 0..<width {
            var rc = 0, gc = 0, bc = 0
            switch packType {
            case 0, 2: // rgb
                guard 3*x + 2 < row.count else { continue }
                rc = Int(row[3*x]); gc = Int(row[3*x+1]); bc = Int(row[3*x+2])
            case 1: // argb (skip alpha)
                guard 4*x + 3 < row.count else { continue }
                rc = Int(row[4*x+1]); gc = Int(row[4*x+2]); bc = Int(row[4*x+3])
            case 3: // 16-bit 1-5-5-5 words
                guard 2*x + 1 < row.count else { continue }
                let p = (UInt16(row[2*x]) << 8) | UInt16(row[2*x+1])
                let r5 = Int((p >> 10) & 0x1F), g5 = Int((p >> 5) & 0x1F), b5 = Int(p & 0x1F)
                rc = (r5 << 3) | (r5 >> 2); gc = (g5 << 3) | (g5 >> 2); bc = (b5 << 3) | (b5 >> 2)
            case 4: // planar components
                if cmpCount >= 3, 2*width + x < row.count {
                    rc = Int(row[x]); gc = Int(row[width + x]); bc = Int(row[2*width + x])
                } else { continue }
            default: continue
            }
            let idx = (y * frameW + x) * 4
            guard idx + 3 < rgba.count else { continue }
            rgba[idx] = UInt8(rc); rgba[idx+1] = UInt8(gc); rgba[idx+2] = UInt8(bc); rgba[idx+3] = 255
        }
    }

    // MARK: Helpers

    private static func skipRegion(_ r: BinaryReader) throws {
        let size = Int(try r.readU16())
        if size >= 2 { try r.advance(size - 2) }
    }

    /// PackBits (RLE) decode. `valueSize` is 1 (bytes) or 2 (16-bit words).
    private static func packbits(_ input: [UInt8], valueSize: Int) -> [UInt8] {
        var out: [UInt8] = []; out.reserveCapacity(input.count * 2)
        var pos = 0
        while pos < input.count {
            let count = input[pos]; pos += 1
            if count < 128 {
                let run = (Int(count) + 1) * valueSize
                for _ in 0..<run where pos < input.count { out.append(input[pos]); pos += 1 }
            } else if count > 128 {
                let run = 256 - Int(count) + 1
                guard pos + valueSize <= input.count else { break }
                let value = Array(input[pos..<pos+valueSize]); pos += valueSize
                for _ in 0..<run { out.append(contentsOf: value) }
            } // count == 128: no-op
        }
        return out
    }

    private static func sheet(_ w: Int, _ h: Int, _ rgba: [UInt8]) -> SpriteSheet {
        SpriteSheet(frameWidth: w, frameHeight: h, frameCount: 1, columns: 1, rows: 1,
                    surfaceWidth: w, surfaceHeight: h, rgba: rgba)
    }
}
