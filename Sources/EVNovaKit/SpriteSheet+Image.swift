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
