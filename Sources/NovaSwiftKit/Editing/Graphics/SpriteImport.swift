import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif

/// A plain top-left-origin straight-alpha RGBA8 image (portable; no CoreGraphics).
public struct RGBAImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// `width * height * 4` bytes.
    public var rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) throws {
        guard width > 0, height > 0 else { throw GraphicsEncodeError.badGeometry("image \(width)x\(height)") }
        guard rgba.count == width * height * 4 else {
            throw GraphicsEncodeError.bufferSize(expected: width * height * 4, actual: rgba.count)
        }
        self.width = width; self.height = height; self.rgba = rgba
    }
}

/// Builds `SpriteSheet`s (the editor's in-memory sprite model, directly
/// encodable with `RLEDEncoder` / `PICTEncoder`) from imported artwork.
///
/// Every builder normalises the result to what the game can store in an
/// `rlëD`: alpha becomes 0 or 255 (`alphaThreshold`), colour is snapped to
/// 5 bits per channel and transparent pixels are cleared. The preview a user
/// sees is therefore exactly what encoding and decoding will produce.
///
/// Frame order for rotation sheets follows EV Nova: frame 0 faces up (north)
/// and frame `n` is heading `n * 360 / N` degrees **clockwise**
/// (`SpriteFrames.headingFrame`: `trunc(heading° × frames / 360)`). Source art
/// is assumed to face up.
public enum SpriteImport {

    public struct Options: Sendable {
        /// Pixels with alpha at or above this are opaque.
        public var alphaThreshold: UInt8 = 128
        /// Snap colour to 5 bits per channel (what `rlëD` stores).
        public var quantizeTo555 = true
        public init(alphaThreshold: UInt8 = 128, quantizeTo555: Bool = true) {
            self.alphaThreshold = alphaThreshold; self.quantizeTo555 = quantizeTo555
        }
    }

    // MARK: Portable API

    /// Cut one grid image into frames, row-major from the top-left. `frameCount`
    /// nil = every complete cell. Frames are repacked into the usual 6-wide grid.
    public static func fromGrid(_ image: RGBAImage, frameWidth fw: Int, frameHeight fh: Int,
                                frameCount: Int? = nil, options: Options = Options()) throws -> SpriteSheet {
        guard fw > 0, fh > 0, fw <= image.width, fh <= image.height else {
            throw GraphicsEncodeError.badGeometry("frame \(fw)x\(fh) in a \(image.width)x\(image.height) image")
        }
        let across = image.width / fw, down = image.height / fh
        let count = min(frameCount ?? across * down, across * down)
        guard count > 0 else { throw GraphicsEncodeError.badGeometry("no complete frames") }
        var frames: [RGBAImage] = []
        frames.reserveCapacity(count)
        for f in 0..<count {
            let x0 = (f % across) * fw, y0 = (f / across) * fh
            var px = [UInt8](repeating: 0, count: fw * fh * 4)
            for y in 0..<fh {
                let s = ((y0 + y) * image.width + x0) * 4
                px.replaceSubrange((y * fw * 4)..<((y + 1) * fw * 4), with: image.rgba[s..<(s + fw * 4)])
            }
            frames.append(try RGBAImage(width: fw, height: fh, rgba: px))
        }
        return try fromFrames(frames, options: options)
    }

    /// One image per frame, all the same size.
    public static func fromFrames(_ frames: [RGBAImage], options: Options = Options()) throws -> SpriteSheet {
        guard let first = frames.first else { throw GraphicsEncodeError.badGeometry("no frames") }
        let fw = first.width, fh = first.height
        guard frames.allSatisfy({ $0.width == fw && $0.height == fh }) else {
            throw GraphicsEncodeError.badGeometry("frames differ in size")
        }
        guard frames.count <= Int(Int16.max) else { throw GraphicsEncodeError.badGeometry("too many frames") }
        let count = frames.count
        let columns = min(SpriteSheet.framesPerRow, count)
        let rows = (count + SpriteSheet.framesPerRow - 1) / SpriteSheet.framesPerRow
        let sw = columns * fw, sh = rows * fh
        var rgba = [UInt8](repeating: 0, count: sw * sh * 4)
        for (f, img) in frames.enumerated() {
            let ox = (f % SpriteSheet.framesPerRow) * fw, oy = (f / SpriteSheet.framesPerRow) * fh
            for y in 0..<fh {
                let d = ((oy + y) * sw + ox) * 4
                rgba.replaceSubrange(d..<(d + fw * 4), with: img.rgba[(y * fw * 4)..<((y + 1) * fw * 4)])
            }
        }
        normalize(&rgba, options)
        return SpriteSheet(frameWidth: fw, frameHeight: fh, frameCount: count, columns: columns, rows: rows,
                           surfaceWidth: sw, surfaceHeight: sh, rgba: rgba)
    }

    /// A single picture that already is a one-frame sprite.
    public static func singleFrame(_ image: RGBAImage, options: Options = Options()) throws -> SpriteSheet {
        try fromFrames([image], options: options)
    }

    /// Rotate one up-facing picture into `frames` headings (36 = EV Nova's
    /// standard ship/shot rotation, 10° apart). `frameSize` defaults to a square
    /// that holds the picture at any heading (its diagonal, rounded up to even).
    /// Resampling is bilinear on premultiplied colour, then thresholded.
    public static func rotated(_ image: RGBAImage, frames: Int = 36, frameSize: Int? = nil,
                               options: Options = Options()) throws -> SpriteSheet {
        guard frames > 0, frames <= Int(Int16.max) else { throw GraphicsEncodeError.badGeometry("frames \(frames)") }
        let diag = Int((Double(image.width * image.width + image.height * image.height)).squareRoot().rounded(.up))
        let size = frameSize ?? (diag + (diag & 1))
        guard size > 0, size < 4096 else { throw GraphicsEncodeError.badGeometry("frame size \(size)") }

        let w = image.width, h = image.height
        // Premultiplied float copy for filtering.
        var pm = [Float](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let a = Float(image.rgba[i * 4 + 3]) / 255
            pm[i * 4] = Float(image.rgba[i * 4]) * a
            pm[i * 4 + 1] = Float(image.rgba[i * 4 + 1]) * a
            pm[i * 4 + 2] = Float(image.rgba[i * 4 + 2]) * a
            pm[i * 4 + 3] = a
        }
        let columns = min(SpriteSheet.framesPerRow, frames)
        let rows = (frames + SpriteSheet.framesPerRow - 1) / SpriteSheet.framesPerRow
        let sw = columns * size, sh = rows * size
        var rgba = [UInt8](repeating: 0, count: sw * sh * 4)
        let cx = Float(size) / 2, cy = Float(size) / 2          // output centre
        let sx0 = Float(w) / 2, sy0 = Float(h) / 2              // source centre
        let thr = Float(options.alphaThreshold) / 255

        pm.withUnsafeBufferPointer { src in
            for f in 0..<frames {
                let theta = Float(f) * 2 * .pi / Float(frames)  // clockwise on a y-down screen
                let c = cos(theta), s = sin(theta)
                let ox = (f % SpriteSheet.framesPerRow) * size, oy = (f / SpriteSheet.framesPerRow) * size
                for y in 0..<size {
                    for x in 0..<size {
                        let dx = Float(x) + 0.5 - cx, dy = Float(y) + 0.5 - cy
                        // inverse of the clockwise rotation
                        let u = dx * c + dy * s + sx0 - 0.5
                        let v = -dx * s + dy * c + sy0 - 0.5
                        let x0 = Int(floor(u)), y0 = Int(floor(v))
                        let fx = u - Float(x0), fy = v - Float(y0)
                        var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
                        @inline(__always) func acc(_ ix: Int, _ iy: Int, _ wt: Float) {
                            guard ix >= 0, ix < w, iy >= 0, iy < h else { return }
                            let k = (iy * w + ix) * 4
                            r += src[k] * wt; g += src[k + 1] * wt; b += src[k + 2] * wt; a += src[k + 3] * wt
                        }
                        acc(x0, y0, (1 - fx) * (1 - fy)); acc(x0 + 1, y0, fx * (1 - fy))
                        acc(x0, y0 + 1, (1 - fx) * fy); acc(x0 + 1, y0 + 1, fx * fy)
                        guard a >= thr, a > 0 else { continue }
                        let d = ((oy + y) * sw + ox + x) * 4
                        rgba[d] = UInt8(max(0, min(255, (r / a).rounded())))
                        rgba[d + 1] = UInt8(max(0, min(255, (g / a).rounded())))
                        rgba[d + 2] = UInt8(max(0, min(255, (b / a).rounded())))
                        rgba[d + 3] = 255
                    }
                }
            }
        }
        normalize(&rgba, options)
        return SpriteSheet(frameWidth: size, frameHeight: size, frameCount: frames, columns: columns, rows: rows,
                           surfaceWidth: sw, surfaceHeight: sh, rgba: rgba)
    }

    /// Snap alpha to 0/255, colour to 5 bits, and clear transparent pixels.
    static func normalize(_ rgba: inout [UInt8], _ o: Options) {
        rgba.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i < p.count {
                if p[i + 3] >= o.alphaThreshold {
                    if o.quantizeTo555 {
                        p[i] = GfxColor.from5(GfxColor.to5(p[i]))
                        p[i + 1] = GfxColor.from5(GfxColor.to5(p[i + 1]))
                        p[i + 2] = GfxColor.from5(GfxColor.to5(p[i + 2]))
                    }
                    p[i + 3] = 255
                } else {
                    p[i] = 0; p[i + 1] = 0; p[i + 2] = 0; p[i + 3] = 0
                }
                i += 4
            }
        }
    }
}

#if canImport(CoreGraphics)
public extension RGBAImage {
    /// Straight-alpha RGBA8 from any CGImage (drawn into an sRGB canvas).
    init(cgImage: CGImage) throws {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { throw GraphicsEncodeError.badGeometry("empty CGImage") }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)
                                        ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw GraphicsEncodeError.badInput("could not create a bitmap context") }
        // un-premultiply
        var i = 0
        while i < px.count {
            let a = Int(px[i + 3])
            if a > 0 && a < 255 {
                px[i] = UInt8(min(255, (Int(px[i]) * 255 + a / 2) / a))
                px[i + 1] = UInt8(min(255, (Int(px[i + 1]) * 255 + a / 2) / a))
                px[i + 2] = UInt8(min(255, (Int(px[i + 2]) * 255 + a / 2) / a))
            }
            i += 4
        }
        try self.init(width: w, height: h, rgba: px)
    }

    /// Decode PNG/JPEG/etc. bytes with ImageIO.
    init(imageData: Data) throws {
        guard let src = CGImageSourceCreateWithData(imageData as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw GraphicsEncodeError.badInput("not a readable image")
        }
        try self.init(cgImage: img)
    }

    func makeCGImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

public extension SpriteImport {
    static func fromGrid(_ image: CGImage, frameWidth: Int, frameHeight: Int, frameCount: Int? = nil,
                         options: Options = Options()) throws -> SpriteSheet {
        try fromGrid(RGBAImage(cgImage: image), frameWidth: frameWidth, frameHeight: frameHeight,
                     frameCount: frameCount, options: options)
    }
    static func fromFrames(_ images: [CGImage], options: Options = Options()) throws -> SpriteSheet {
        try fromFrames(images.map { try RGBAImage(cgImage: $0) }, options: options)
    }
    static func rotated(_ image: CGImage, frames: Int = 36, frameSize: Int? = nil,
                        options: Options = Options()) throws -> SpriteSheet {
        try rotated(RGBAImage(cgImage: image), frames: frames, frameSize: frameSize, options: options)
    }
}
#endif
