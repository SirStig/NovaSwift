#if os(macOS)
import SwiftUI
import AppKit
import ImageIO
import NovaSwiftKit
import NovaSwiftHD

/// Small decoded thumbnails for the Changes view (classic art, HD atlas frames, dialog pictures).
/// All work is synchronous and meant to be called off the main actor; results sit in a small LRU.
final class ChangeThumbCache: @unchecked Sendable {
    static let shared = ChangeThumbCache()

    private struct Key: Hashable { let tag: UInt32; let id: Int; let size: Int; let hash: Int }
    private var store: [Key: CGImage?] = [:]
    private var order: [Key] = []
    private let lock = NSLock()
    private let capacity = 600

    private func cached(_ k: Key, _ make: () -> CGImage?) -> CGImage? {
        lock.lock()
        if let hit = store[k] { lock.unlock(); return hit }
        lock.unlock()
        let img = make()
        lock.lock()
        store[k] = .some(img); order.append(k)
        while order.count > capacity { store[order.removeFirst()] = nil }
        lock.unlock()
        return img
    }

    /// Frame 0 of a classic graphic (rlëD / PICT / cicn / ppat), shrunk to fit `maxPixel`.
    func classic(type: NovaSwiftKit.FourCharCode, id: Int, data: Data, maxPixel: Int = 72) -> CGImage? {
        cached(Key(tag: type.rawValue, id: id, size: maxPixel, hash: data.hashValue)) {
            Self.decodeSheet(type: type, data: data)
                .flatMap { EditorDecodedSprite($0)?.frame(0) }
                .flatMap { Self.shrink($0, to: maxPixel) }
        }
    }

    /// Frame 0 of an HD PNG atlas. `classic` (the sheet being replaced) lets the atlas be cropped
    /// the way the game does; without it the whole atlas is shown.
    func hdSprite(spriteID: Int, png: Data, descriptor: GraphicsEnhancement,
                  classic: (type: NovaSwiftKit.FourCharCode, data: Data)?, maxPixel: Int = 72) -> CGImage? {
        cached(Key(tag: 0x4E534758, id: spriteID, size: maxPixel, hash: png.hashValue)) {
            if let c = classic, let sheet = Self.decodeSheet(type: c.type, data: c.data),
               let atlas = try? HDAtlas.load(png, descriptor: descriptor, classic: sheet, maxScale: 2),
               let f = atlas.frameImage(0) {
                return Self.shrink(f, to: maxPixel)
            }
            guard let src = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ] as CFDictionary)
        }
    }

    nonisolated static func decodeSheet(type: NovaSwiftKit.FourCharCode, data: Data) -> SpriteSheet? {
        switch type {
        case NovaType.rleD: return try? RLED.decode(data)
        case NovaType.rle8: return try? RLE8.decode(data)
        case NovaType.pict: return try? PICT.decode(data)
        case NovaType.cicn: return try? CICN.decode(data)
        case NovaType.ppat, NovaType.ppatAlt: return try? PixPat.decode(data)
        default: return nil
        }
    }

    nonisolated static func shrink(_ img: CGImage, to maxPixel: Int) -> CGImage {
        let w = img.width, h = img.height
        let longest = max(w, h)
        guard longest > maxPixel, longest > 0 else { return img }
        let s = Double(maxPixel) / Double(longest)
        let nw = max(1, Int(Double(w) * s)), nh = max(1, Int(Double(h) * s))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? img
    }
}

/// A thumbnail that decodes off-main when it scrolls into view and cancels when it leaves.
struct AsyncThumb: View {
    /// Identity of what's drawn (changes → reload).
    let id: AnyHashable
    var size: CGFloat = 40
    let load: @Sendable () -> CGImage?

    @State private var image: CGImage?
    @State private var done = false

    var body: some View {
        ZStack {
            CheckerboardBackground()
            if let image {
                Image(decorative: image, scale: 1).interpolation(.medium).resizable().scaledToFit().padding(2)
            } else if done {
                Image(systemName: "questionmark").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.1)))
        .task(id: id) {
            let l = load
            let box = await Task.detached(priority: .utility) { SpecBox(value: l()) }.value
            if Task.isCancelled { return }
            image = box.value; done = true
        }
    }
}

/// Cube placeholder for 3D model attachments.
struct ModelThumb: View {
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.cyan.opacity(0.12))
            Image(systemName: "cube.fill").font(.system(size: size * 0.5)).foregroundStyle(Color.cyan)
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.cyan.opacity(0.35)))
        .help("3D model (USDZ)")
    }
}
#endif
