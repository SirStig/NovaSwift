import Foundation
import NovaSwiftKit
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#if canImport(Compression)
import Compression
#endif

/// A high-resolution sprite sheet: the classic sheet's exact frame layout
/// (same frame count, same order, `columns` frames per row) drawn at
/// `pixelScale` pixels per classic pixel. Whether it came from a plug-in's
/// PNG or a baked 3D model, the renderer treats it the same way: one atlas
/// texture whose frames report the classic (logical) size, so every
/// position, radius and hit-box stays exactly the original's.
public struct HDAtlas: @unchecked Sendable {
    public let image: CGImage
    /// Classic (logical) frame size, in classic pixels.
    public let frameWidth: Int
    public let frameHeight: Int
    public let frameCount: Int
    public let columns: Int
    public let pixelScale: Double

    public var rows: Int { (frameCount + columns - 1) / columns }
    /// The atlas size in classic pixels.
    public var logicalWidth: Int { columns * frameWidth }
    public var logicalHeight: Int { rows * frameHeight }
    /// Approximate GPU memory for the texture (RGBA8).
    public var byteCount: Int { image.width * image.height * 4 }

    /// The frame's rect in normalized texture space (origin bottom-left, as
    /// SpriteKit's `SKTexture(rect:in:)` expects).
    public func normalizedRect(frame index: Int) -> CGRect {
        let col = index % columns, row = index / columns
        let w = 1.0 / Double(columns), h = 1.0 / Double(rows)
        return CGRect(x: Double(col) * w, y: 1 - Double(row + 1) * h, width: w, height: h)
    }

    /// Largest texture dimension we will create. 8192 is the floor every
    /// supported Apple GPU handles (A9/A10 top out there; later ones at 16384).
    public static let maxTextureDimension = 8192

    /// Most pixels one atlas may hold: 4 megapixels, 16 MB — one 2048² texture.
    /// Every sheet is kept twice (CPU image + GPU texture, the same RAM on
    /// Apple silicon), and big hulls at 4× ran to 100–170 MB each, enough to
    /// get the game killed for memory. A ship that large still gets 2–3×,
    /// sharp on a Retina screen.
    public static let maxAtlasPixels = 4_194_304

    /// The highest whole scale ≤ `wanted` whose atlas fits both
    /// `maxTextureDimension` and `maxAtlasPixels`.
    public static func clampScale(_ wanted: Double, logicalWidth: Int, logicalHeight: Int) -> Double {
        let w = Double(max(1, logicalWidth)), h = Double(max(1, logicalHeight))
        let bySide = Double(maxTextureDimension) / max(w, h)
        let byArea = (Double(maxAtlasPixels) / (w * h)).squareRoot()
        return max(1, min(wanted, min(bySide, byArea).rounded(.down)))
    }

    public enum LoadError: Error, CustomStringConvertible {
        case undecodable
        case wrongFrameCount(expected: Int, declared: Int)
        case wrongSize(expected: String, actual: String)

        public var description: String {
            switch self {
            case .undecodable: return "image could not be decoded"
            case let .wrongFrameCount(e, d): return "declares \(d) frames; the classic sheet has \(e)"
            case let .wrongSize(e, a): return "atlas is \(a) px; expected \(e) px for this sheet and scale"
            }
        }
    }

    public init(image: CGImage, frameWidth: Int, frameHeight: Int, frameCount: Int, columns: Int, pixelScale: Double) {
        self.image = image; self.frameWidth = frameWidth; self.frameHeight = frameHeight
        self.frameCount = frameCount; self.columns = columns; self.pixelScale = pixelScale
    }

    /// Decode a plug-in's HD sprite atlas and check it against the classic
    /// sheet it replaces, then cap its resolution at `maxScale`.
    public static func load(_ data: Data, descriptor: GraphicsEnhancement, classic: SpriteSheet,
                            maxScale: Double) throws -> HDAtlas {
        if let declared = descriptor.frameCount, declared != classic.frameCount {
            throw LoadError.wrongFrameCount(expected: classic.frameCount, declared: declared)
        }
        guard let image = decodePNG(data) else { throw LoadError.undecodable }
        let columns = min(descriptor.effectiveColumns, classic.frameCount)
        let scale = descriptor.effectiveScale
        let rows = (classic.frameCount + columns - 1) / columns
        let ew = Int((Double(columns * classic.frameWidth) * scale).rounded())
        let eh = Int((Double(rows * classic.frameHeight) * scale).rounded())
        guard abs(image.width - ew) <= 1, abs(image.height - eh) <= 1 else {
            throw LoadError.wrongSize(expected: "\(ew)×\(eh)", actual: "\(image.width)×\(image.height)")
        }
        let atlas = HDAtlas(image: image, frameWidth: classic.frameWidth, frameHeight: classic.frameHeight,
                            frameCount: classic.frameCount, columns: columns, pixelScale: scale)
        let cap = clampScale(maxScale, logicalWidth: atlas.logicalWidth, logicalHeight: atlas.logicalHeight)
        return scale > cap ? atlas.resampled(to: cap) : atlas
    }

    /// The same atlas at a lower scale (high-quality filtering).
    public func resampled(to scale: Double) -> HDAtlas {
        let w = Int((Double(logicalWidth) * scale).rounded()), h = Int((Double(logicalHeight) * scale).rounded())
        guard let ctx = HDAtlas.makeContext(width: w, height: h) else { return self }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return self }
        return HDAtlas(image: out, frameWidth: frameWidth, frameHeight: frameHeight, frameCount: frameCount,
                       columns: columns, pixelScale: scale)
    }

    /// One frame as its own image (for previews and tools).
    public func frameImage(_ index: Int) -> CGImage? {
        let r = normalizedRect(frame: index)
        let px = CGRect(x: r.minX * Double(image.width), y: (1 - r.maxY) * Double(image.height),
                        width: r.width * Double(image.width), height: r.height * Double(image.height)).integral
        return image.cropping(to: px)
    }

    public func pngData() -> Data? { HDAtlas.encodePNG(image) }

    public static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    public static func encodePNG(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    public static func decodePNG(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    #if canImport(Compression)
    /// The cache's own format: "NSA1", width and height (little-endian
    /// UInt32), then the premultiplied RGBA rows, LZ4-compressed. About the
    /// size of a PNG but ~20× quicker to read (4 ms against 87 ms for a
    /// 1152×3456 hull), and already in the layout textures are made from.
    public static func encodeRaw(_ image: CGImage) -> Data? {
        let w = image.width, h = image.height
        guard let ctx = makeContext(width: w, height: h) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let src = ctx.data else { return nil }
        let rowBytes = w * 4, count = rowBytes * h
        // Tight rows (the context may pad them).
        var pixels = [UInt8](repeating: 0, count: count)
        pixels.withUnsafeMutableBytes { dst in
            for y in 0..<h {
                (dst.baseAddress! + y * rowBytes).copyMemory(from: src + y * ctx.bytesPerRow, byteCount: rowBytes)
            }
        }
        var out = [UInt8](repeating: 0, count: count + count / 16 + 64)
        let n = compression_encode_buffer(&out, out.count, pixels, count, nil, COMPRESSION_LZ4)
        guard n > 0 else { return nil }
        var data = Data(rawMagic)
        withUnsafeBytes(of: UInt32(w).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(h).littleEndian) { data.append(contentsOf: $0) }
        data.append(out, count: n)
        return data
    }

    public static func decodeRaw(_ data: Data) -> CGImage? {
        guard data.count > 12, data.prefix(4).elementsEqual(rawMagic) else { return nil }
        let w = Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) })
        let h = Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) })
        guard w > 0, h > 0, w <= maxTextureDimension * 2, h <= maxTextureDimension * 2 else { return nil }
        let count = w * h * 4
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        let n = data.withUnsafeBytes { raw -> Int in
            let body = raw.bindMemory(to: UInt8.self)
            return compression_decode_buffer(pixels, count, body.baseAddress! + 12, body.count - 12, nil, COMPRESSION_LZ4)
        }
        guard n == count else { pixels.deallocate(); return nil }
        // The image owns the buffer from here; it's freed with the image.
        guard let provider = CGDataProvider(dataInfo: nil, data: pixels, size: count, releaseData: { _, p, _ in
            UnsafeMutableRawPointer(mutating: p).deallocate()
        }) else { pixels.deallocate(); return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static let rawMagic: [UInt8] = Array("NSA1".utf8)
    #endif
}

/// How big the classic art is on screen, per frame: the larger side of each
/// frame's opaque bounding box, in classic pixels. A model is fitted so its
/// rendered frames cover the same extent — the HD hull lines up with the
/// classic collision mask.
public enum ClassicFootprint {
    /// The middle and upper-middle brightness (luminance 0…1 at the 50th and
    /// 75th percentile) of a classic sheet's opaque pixels in `frames` — what
    /// an HD model's lighting is matched to.
    public static func tones(of sheet: SpriteSheet, frames: [Int]) -> (mid: Double, high: Double)? {
        var hist = [Int](repeating: 0, count: 256)
        let stride = sheet.surfaceWidth * 4
        for f in frames where f >= 0 && f < sheet.frameCount {
            let ox = (f % SpriteSheet.framesPerRow) * sheet.frameWidth
            let oy = (f / SpriteSheet.framesPerRow) * sheet.frameHeight
            for y in 0..<sheet.frameHeight {
                let row = (oy + y) * stride
                for x in 0..<sheet.frameWidth {
                    let i = row + (ox + x) * 4
                    guard sheet.rgba[i + 3] > 200 else { continue }
                    hist[luma(sheet.rgba[i], sheet.rgba[i + 1], sheet.rgba[i + 2])] += 1
                }
            }
        }
        return percentiles(hist)
    }

    /// The same measure over rendered (premultiplied) images.
    public static func tones(of images: [CGImage]) -> (mid: Double, high: Double)? {
        var hist = [Int](repeating: 0, count: 256)
        for image in images {
            let w = image.width, h = image.height
            guard let ctx = HDAtlas.makeContext(width: w, height: h), let data = ctx.data else { continue }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let p = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * ctx.bytesPerRow + x * 4
                    let a = Int(p[i + 3])
                    guard a > 200 else { continue }
                    func un(_ v: UInt8) -> UInt8 { UInt8(min(255, Int(v) * 255 / a)) }
                    hist[luma(un(p[i]), un(p[i + 1]), un(p[i + 2]))] += 1
                }
            }
        }
        return percentiles(hist)
    }

    @inline(__always) private static func luma(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int {
        (Int(r) * 54 + Int(g) * 183 + Int(b) * 19) >> 8
    }

    private static func percentiles(_ hist: [Int]) -> (mid: Double, high: Double)? {
        let total = hist.reduce(0, +)
        guard total > 0 else { return nil }
        func at(_ q: Double) -> Double {
            var seen = 0
            for (v, c) in hist.enumerated() { seen += c; if Double(seen) >= q * Double(total) { return Double(v) / 255 } }
            return 1
        }
        return (at(0.5), at(0.75))
    }

    public static func extents(of sheet: SpriteSheet, frames: [Int]) -> [Int: Double] {
        var out: [Int: Double] = [:]
        let stride = sheet.surfaceWidth * 4
        for f in frames where f >= 0 && f < sheet.frameCount {
            let ox = (f % SpriteSheet.framesPerRow) * sheet.frameWidth
            let oy = (f / SpriteSheet.framesPerRow) * sheet.frameHeight
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in 0..<sheet.frameHeight {
                let row = (oy + y) * stride
                for x in 0..<sheet.frameWidth where sheet.rgba[row + (ox + x) * 4 + 3] > 0 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            if maxX >= 0 { out[f] = Double(max(maxX - minX + 1, maxY - minY + 1)) }
        }
        return out
    }

    /// The same measurement on a rendered image (alpha > ~4%), in that
    /// image's pixels.
    public static func extent(of image: CGImage) -> Double? {
        bounds(of: image).map { Double(max($0.width, $0.height)) }
    }

    /// The visible part's bounding box, in the image's pixels (y down from the top).
    public static func bounds(of image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        guard let ctx = HDAtlas.makeContext(width: w, height: h), let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        let stride = ctx.bytesPerRow
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where p[y * stride + x * 4 + 3] > 10 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX >= 0 ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) : nil
    }
}
#endif
