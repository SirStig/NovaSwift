import Foundation
import SpriteKit
import NovaSwiftKit

/// Bridges decoded EV Nova sprite sheets into SpriteKit textures.
enum SpriteTextures {
    /// The rotation frames of a sprite sheet's first animation set as SKTextures,
    /// ordered by heading (frame 0 = pointing up, clockwise).
    ///
    /// EV Nova hull sheets often pack several "sets" (normal, banking, lit) of
    /// `rotationFrames` each; the first `rotationFrames` frames are the plain
    /// rotation we use for flight.
    static func rotationFrames(from sheet: SpriteSheet, rotationCount: Int = 36) -> [SKTexture] {
        let count = min(rotationCount, sheet.frameCount)
        guard count > 0 else { return [] }
        // Build the backing grid CGImage once and crop every heading out of it.
        // (Calling `frameCGImage(_:)` per frame rebuilt the full surface + copied
        // the whole RGBA buffer 36× for a single hull — see `frameCGImages`.)
        return sheet.frameCGImages(0..<count).map { frame in
            let tex = SKTexture(cgImage: frame.image)
            tex.filteringMode = .nearest
            return tex
        }
    }
}
