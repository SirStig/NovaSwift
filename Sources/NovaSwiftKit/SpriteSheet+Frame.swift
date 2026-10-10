import Foundation

public extension SpriteSheet {
    /// One frame of the grid as its own single-frame sheet, or nil when the
    /// index is out of range or the surface is smaller than the grid claims.
    func singleFrame(_ index: Int) -> SpriteSheet? {
        guard index >= 0, index < frameCount, frameWidth > 0, frameHeight > 0 else { return nil }
        let x0 = (index % SpriteSheet.framesPerRow) * frameWidth
        let y0 = (index / SpriteSheet.framesPerRow) * frameHeight
        guard x0 + frameWidth <= surfaceWidth, y0 + frameHeight <= surfaceHeight,
              rgba.count == surfaceWidth * surfaceHeight * 4 else { return nil }
        var out = [UInt8](repeating: 0, count: frameWidth * frameHeight * 4)
        for row in 0..<frameHeight {
            let src = ((y0 + row) * surfaceWidth + x0) * 4
            let dst = row * frameWidth * 4
            out.replaceSubrange(dst..<(dst + frameWidth * 4), with: rgba[src..<(src + frameWidth * 4)])
        }
        return SpriteSheet(frameWidth: frameWidth, frameHeight: frameHeight, frameCount: 1,
                           columns: 1, rows: 1, surfaceWidth: frameWidth, surfaceHeight: frameHeight,
                           rgba: out)
    }
}
