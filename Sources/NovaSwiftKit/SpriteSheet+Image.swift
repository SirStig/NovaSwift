import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO

public extension SpriteSheet {
    /// The full grid as a CGImage (top-left origin, straight alpha).
    func makeCGImage() -> CGImage? {
        makeCGImage(width: surfaceWidth, height: surfaceHeight, pixels: rgba)
    }

    /// A single frame cropped from the grid.
    func frameCGImage(_ index: Int) -> CGImage? {
        guard index >= 0, index < frameCount, let full = makeCGImage() else { return nil }
        return Self.crop(full, frame: index, frameWidth: frameWidth, frameHeight: frameHeight)
    }

    /// Several frames cropped from the grid, building the backing grid `CGImage`
    /// **once** and cropping each frame out of it. Callers that want more than one
    /// frame (rotation sheets — up to 36 headings — button normal/pressed pairs)
    /// must use this instead of calling `frameCGImage(_:)` in a loop: that rebuilt
    /// the entire surface `CGImage` *and copied the whole RGBA buffer* on every
    /// frame, turning an N-frame sheet into O(N) full-surface allocations. Skips
    /// out-of-range indices; result order follows `indices`.
    func frameCGImages<S: Sequence>(_ indices: S) -> [(index: Int, image: CGImage)]
        where S.Element == Int {
        guard let full = makeCGImage() else { return [] }
        var out: [(index: Int, image: CGImage)] = []
        for index in indices where index >= 0 && index < frameCount {
            if let cg = Self.crop(full, frame: index, frameWidth: frameWidth, frameHeight: frameHeight) {
                out.append((index, cg))
            }
        }
        return out
    }

    private static func crop(_ full: CGImage, frame index: Int, frameWidth: Int, frameHeight: Int) -> CGImage? {
        let x = (index % SpriteSheet.framesPerRow) * frameWidth
        let y = (index / SpriteSheet.framesPerRow) * frameHeight
        return full.cropping(to: CGRect(x: x, y: y, width: frameWidth, height: frameHeight))
    }

    /// Encode the full grid as PNG bytes.
    func pngData() -> Data? {
        guard let image = makeCGImage() else { return nil }
        return Self.encodePNG(image)
    }

    /// Write the full grid to a PNG file.
    @discardableResult
    func writePNG(to url: URL) -> Bool {
        guard let data = pngData() else { return false }
        return (try? data.write(to: url)) != nil
    }

    // MARK: - Helpers

    private func makeCGImage(width: Int, height: Int, pixels: [UInt8]) -> CGImage? {
        guard width > 0, height > 0, pixels.count == width * height * 4 else { return nil }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue) // straight (non-premultiplied) RGBA
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace, bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
#endif
