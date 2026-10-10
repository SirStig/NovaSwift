import Foundation
import NovaSwiftKit

/// Rotation-frame selection shared by the simulation and the renderer, so a
/// collision mask is always the frame on screen (WP-17).
public enum SpriteFrames {
    /// The heading frame of a `frames`-per-turn sheet for a compass angle in
    /// radians (0 = up, clockwise): `trunc(heading° × frames / 360)`, as
    /// `Ship_UpdateVisualState` (0x00428340) and `Shot_HandleShot`
    /// (0x00435830) pick it.
    public static func headingFrame(angle: Double, frames: Int) -> Int {
        headingFrame(degrees: angle * 180 / .pi, frames: frames)
    }

    /// The same for a heading in degrees.
    public static func headingFrame(degrees: Double, frames: Int) -> Int {
        guard frames > 1 else { return 0 }
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        // The epsilon keeps a whole-degree heading that went through radians
        // (e.g. 90° → 89.99999…) on its own frame.
        let f = Int((d * Double(frames) / 360 + 1e-9).rounded(.down))
        return min(max(0, f), frames - 1)
    }
}

/// One sprite frame placed for a contact test: integer screen pixels, y down.
public struct ContactSprite {
    /// nil: a single opaque pixel (a shot with no graphic).
    public let mask: SpriteMaskSet?
    public let frame: Int
    public let left: Int
    public let top: Int
    public var width: Int { mask?.width ?? 1 }
    public var height: Int { mask?.height ?? 1 }

    public init(mask: SpriteMaskSet?, frame: Int, left: Int, top: Int) {
        self.mask = mask; self.frame = frame; self.left = left; self.top = top
    }

    @inline(__always) static func pixel(_ v: Double) -> Int { Int(v.rounded(.down)) }

    /// A hull or asteroid frame: its top-left sits half its width and half its
    /// height up-left of the ship's position (0x00428340).
    public static func hull(_ mask: SpriteMaskSet, frame: Int, at p: Vec2) -> ContactSprite {
        ContactSprite(mask: mask, frame: frame,
                      left: pixel(p.x) - mask.width / 2, top: pixel(-p.y) - mask.height / 2)
    }

    /// A shot frame: `Shot_HandleShot` (0x00435830) backs off half the frame
    /// *width* on both axes.
    public static func shot(_ mask: SpriteMaskSet?, frame: Int, at p: Vec2) -> ContactSprite {
        let half = (mask?.width ?? 0) / 2
        return ContactSprite(mask: mask, frame: frame, left: pixel(p.x) - half, top: pixel(-p.y) - half)
    }
}

/// The original's direct shot → ship contact (WP-17).
public enum SpriteContact {
    /// `Sprite_TestBoundingCircleOverlap` (0x00475be0): each sprite is a
    /// circle of half its frame *width*, centred half a width in from its
    /// top-left on both axes; they touch when the centres are strictly closer
    /// than the summed radii.
    public static func circlesOverlap(_ a: ContactSprite, _ b: ContactSprite) -> Bool {
        let ha = a.width / 2, hb = b.width / 2
        let dx = (a.left + ha) - (b.left + hb)
        let dy = (a.top + ha) - (b.top + hb)
        let r = ha + hb
        return dx * dx + dy * dy < r * r
    }

    /// `Sprite_TestPixelMaskOverlap` (0x00475c80): some pixel is opaque in both.
    public static func masksOverlap(_ a: ContactSprite, _ b: ContactSprite) -> Bool {
        switch (a.mask, b.mask) {
        case let (ma?, mb?):
            return ma.overlaps(frame: a.frame, left: a.left, top: a.top,
                               mb, otherFrame: b.frame, otherLeft: b.left, otherTop: b.top)
        case let (ma?, nil):
            return ma.isOpaque(frame: a.frame, x: b.left - a.left, y: b.top - a.top)
        case let (nil, mb?):
            return mb.isOpaque(frame: b.frame, x: a.left - b.left, y: a.top - b.top)
        case (nil, nil):
            return a.left == b.left && a.top == b.top
        }
    }

    /// `Ship_HandleSpritePairCollision` (0x004374f0): a hull frame 32 px wide
    /// or less is tested with the circle, anything wider by its pixels. (The
    /// original also falls back to the circle when its averaged frame scale
    /// reaches 2.0, a 66 ms frame; NovaSwift's fixed step never does.)
    public static func shotTouchesShip(ship: ContactSprite, shot: ContactSprite) -> Bool {
        if ship.width <= 0x20 { return circlesOverlap(ship, shot) }
        return masksOverlap(ship, shot)
    }

    /// Whether the two frame rectangles can overlap at all (the broad phase).
    @inline(__always)
    public static func boundsOverlap(_ a: ContactSprite, _ b: ContactSprite) -> Bool {
        a.left < b.left + b.width && b.left < a.left + a.width
            && a.top < b.top + max(b.height, b.width) && b.top < a.top + max(a.height, a.width)
    }
}
