import Foundation
import NovaSwiftKit
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO

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

    /// The highest scale ≤ `wanted` whose atlas fits `maxTextureDimension`.
    public static func clampScale(_ wanted: Double, logicalWidth: Int, logicalHeight: Int) -> Double {
        let limit = Double(maxTextureDimension) / Double(max(1, max(logicalWidth, logicalHeight)))
        return max(1, min(wanted, limit.rounded(.down)))
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
}

/// How big the classic art is on screen, per frame: the larger side of each
/// frame's opaque bounding box, in classic pixels. A model is fitted so its
/// rendered frames cover the same extent — the HD hull lines up with the
/// classic collision mask.
public enum ClassicFootprint {
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
        return maxX >= 0 ? Double(max(maxX - minX + 1, maxY - minY + 1)) : nil
    }
}
#endif
