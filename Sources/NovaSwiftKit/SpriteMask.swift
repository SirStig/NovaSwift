import Foundation

/// The 1-bit opaque masks of every frame in an `rlëD` sprite — what the
/// original's collision tests read (WP-17).
///
/// `Sprite_TestPixelMaskOverlap` (0x00475c80) walks the prepared RLE command
/// streams of two frames and reports a hit the moment both have an opaque run
/// at the same pixel. A pixel is opaque exactly when the `rlëD` stream draws it
/// (a pixel-data or pixel-run opcode); a transparent-run opcode or the unwritten
/// remainder of a line is clear. The mask is built straight from the RLE
/// stream, so collision never needs the decoded RGBA surface.
///
/// Bits are stored row-major per frame, `wordsPerRow` 64-bit words per row,
/// pixel `x` at bit `x & 63` of word `x >> 6`. Bits past the frame width are
/// always zero. A 100 px, 36-frame hull is about 57 KB.
public struct SpriteMaskSet: Sendable {
    public let width: Int
    public let height: Int
    public let frameCount: Int
    public let wordsPerRow: Int
    public let bits: [UInt64]

    public init(width: Int, height: Int, frameCount: Int, bits: [UInt64]) {
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.wordsPerRow = (width + 63) >> 6
        precondition(bits.count == wordsPerRow * height * frameCount)
        self.bits = bits
    }

    /// Whether `frame` is opaque at (`x`, `y`), top-left origin. Out of range is clear.
    public func isOpaque(frame: Int, x: Int, y: Int) -> Bool {
        guard frame >= 0, frame < frameCount, x >= 0, x < width, y >= 0, y < height else { return false }
        let w = bits[(frame * height + y) * wordsPerRow + (x >> 6)]
        return (w >> UInt64(x & 63)) & 1 != 0
    }

    /// Opaque pixels in `frame` (tests and diagnostics).
    public func opaqueCount(frame: Int) -> Int {
        guard frame >= 0, frame < frameCount else { return 0 }
        let start = frame * height * wordsPerRow
        return bits[start..<(start + height * wordsPerRow)].reduce(0) { $0 + $1.nonzeroBitCount }
    }

    /// The 64 mask bits of `frame`, row `y`, starting at column `x` (which may
    /// be negative or run past the width; those bits read clear).
    @inline(__always)
    func window(frame: Int, y: Int, x: Int) -> UInt64 {
        let base = (frame * height + y) * wordsPerRow
        if x >= 0 {
            let wi = x >> 6, sh = UInt64(x & 63)
            guard wi < wordsPerRow else { return 0 }
            var v = bits[base + wi] >> sh
            if sh != 0, wi + 1 < wordsPerRow { v |= bits[base + wi + 1] << (64 - sh) }
            return v
        }
        // x < 0: the first −x bits are off the left edge.
        let lead = -x
        guard lead < 64 else { return 0 }
        return bits[base] << UInt64(lead)
    }

    /// `Sprite_TestPixelMaskOverlap` (0x00475c80): place `frame` of this mask
    /// with its top-left at (`left`, `top`) and `otherFrame` of `other` at
    /// (`otherLeft`, `otherTop`) — integer screen pixels, y down — and report
    /// whether any pixel is opaque in both. The two frame rectangles must
    /// overlap with a strictly positive area.
    public func overlaps(frame: Int, left: Int, top: Int,
                         _ other: SpriteMaskSet, otherFrame: Int, otherLeft: Int, otherTop: Int) -> Bool {
        guard frame >= 0, frame < frameCount, otherFrame >= 0, otherFrame < other.frameCount else { return false }
        let x0 = max(left, otherLeft), x1 = min(left + width, otherLeft + other.width)
        let y0 = max(top, otherTop), y1 = min(top + height, otherTop + other.height)
        guard x0 < x1, y0 < y1 else { return false }
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                let n = x1 - x
                let keep: UInt64 = n >= 64 ? ~0 : (UInt64(1) << UInt64(n)) - 1
                let a = window(frame: frame, y: y - top, x: x - left)
                let b = other.window(frame: otherFrame, y: y - otherTop, x: x - otherLeft)
                if a & b & keep != 0 { return true }
                x += 64
            }
            y += 1
        }
        return abutsAsOriginal(frame: frame, left: left, top: top, other, otherFrame: otherFrame,
                               otherLeft: otherLeft, otherTop: otherTop, x0: x0, x1: x1, y0: y0, y1: y1)
    }

    /// The original's run-walk quirk (`SpriteRleCommandStream_SkipToRowCount`
    /// 0x00472190, confirmed with the oracle): where this sprite's opaque run
    /// ends exactly where the other's next opaque run starts on the same row,
    /// the walk reports a hit although the pixels only abut. The reverse
    /// order is not a hit.
    private func abutsAsOriginal(frame: Int, left: Int, top: Int,
                                 _ other: SpriteMaskSet, otherFrame: Int, otherLeft: Int, otherTop: Int,
                                 x0: Int, x1: Int, y0: Int, y1: Int) -> Bool {
        var y = y0
        while y < y1 {
            var xs = x0
            while xs < x1 {
                // Bit k of both windows is pixel xs - 1 + k.
                let wa = window(frame: frame, y: y - top, x: xs - 1 - left)
                let wb = other.window(frame: otherFrame, y: y - otherTop, x: xs - 1 - otherLeft)
                let n = min(x1 - xs, 63)
                let keep: UInt64 = n >= 64 ? ~0 : (UInt64(1) << UInt64(n)) - 1
                // A opaque at k and clear at k + 1; B clear at k and opaque at k + 1.
                if (wa & ~(wa >> 1)) & ~wb & (wb >> 1) & keep != 0 { return true }
                xs += 63
            }
            y += 1
        }
        return false
    }
}

extension RLED {
    /// Build the opaque mask of every frame in an `rlëD` resource, walking the
    /// same opcode stream `decode` does without producing colour.
    public static func decodeMasks(_ data: Data) throws -> SpriteMaskSet {
        let reader = BinaryReader(data, bigEndian: true)
        let width = Int(try reader.readI16())
        let height = Int(try reader.readI16())
        let bpp = Int(try reader.readI16())
        _ = try reader.readI16()
        let frameCount = Int(try reader.readI16())
        try reader.advance(6)
        guard bpp == 16 else {
            throw ResourceFileError.corrupt("rlëD colour depth \(bpp) unsupported (only 16-bit)")
        }
        guard width > 0, height > 0, frameCount > 0, width < 4096, height < 4096 else {
            throw ResourceFileError.corrupt("rlëD implausible geometry \(width)x\(height) × \(frameCount)")
        }
        let wordsPerRow = (width + 63) >> 6
        var bits = [UInt64](repeating: 0, count: wordsPerRow * height * frameCount)

        var frame = 0, line = -1, x = 0
        @inline(__always) func setOpaque(_ count: Int) {
            guard line >= 0, line < height, frame < frameCount else { x += count; return }
            let base = (frame * height + line) * wordsPerRow
            for _ in 0..<count {
                if x >= 0, x < width { bits[base + (x >> 6)] |= UInt64(1) << UInt64(x & 63) }
                x += 1
            }
        }

        var done = false
        while !done, reader.remaining >= 4 {
            let token = try reader.readU32()
            let count = Int(token & 0x00FF_FFFF)
            switch token >> 24 {
            case 0x00:
                frame += 1
                if frame >= frameCount { done = true }
                line = -1
            case 0x01:
                line += 1
                x = 0
            case 0x02:
                // `count` bytes of 16-bit pixels, padded to a 4-byte boundary.
                setOpaque((count + 1) / 2)
                let padded = (count + 3) & ~3
                try reader.advance(padded)
            case 0x03:
                x += count >> 1
            case 0x04:
                _ = try reader.readU32()
                setOpaque(count >> 1)
            default:
                throw ResourceFileError.corrupt("unknown rlëD opcode 0x\(String(token >> 24, radix: 16))")
            }
        }
        return SpriteMaskSet(width: width, height: height, frameCount: frameCount, bits: bits)
    }
}
