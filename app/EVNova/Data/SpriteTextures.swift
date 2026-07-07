import Foundation
import SpriteKit
import EVNovaKit

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
        var textures: [SKTexture] = []
        textures.reserveCapacity(count)
        for i in 0..<count {
            if let cg = sheet.frameCGImage(i) {
                let tex = SKTexture(cgImage: cg)
                tex.filteringMode = .nearest
                textures.append(tex)
            }
        }
        return textures
    }
}
