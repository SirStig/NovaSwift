import Foundation
import NovaSwiftKit
#if canImport(SceneKit)

/// How each sprite id's frames are organised, from the data that uses it:
/// a hull's `shän` (FramesPer × base sets, banking or not — shared by its
/// engine/light/weapon-glow layers); anything else is one rotation set of
/// all its frames (weapons, asteroids) or a single still frame (stellars).
public struct SpriteLayouts: Sendable {
    private struct Hull: Sendable { let framesPerSet: Int; let sets: Int; let banking: Bool }
    private var hulls: [Int: Hull] = [:]
    /// Base sprite id → its hull's overlay sprite ids, per effect layer.
    private var overlayIDs: [Int: [GraphicsEnhancement.EffectLayer: Int]] = [:]

    public init(game: NovaGame) {
        for r in game.resources.resources(of: NovaType.shan) {
            let shan = ShanRes(r)
            let hull = Hull(framesPerSet: max(1, shan.framesPerSet), sets: max(1, shan.baseSetCount),
                            banking: shan.extraFrames == .banking)
            for id in [shan.baseSpriteID, shan.engineSpriteID, shan.lightSpriteID, shan.weaponGlowSpriteID]
            where id > 0 && hulls[id] == nil {
                hulls[id] = hull
            }
            if shan.baseSpriteID > 0, overlayIDs[shan.baseSpriteID] == nil {
                var o: [GraphicsEnhancement.EffectLayer: Int] = [:]
                if shan.engineSpriteID > 0 { o[.engine] = shan.engineSpriteID }
                if shan.lightSpriteID > 0 { o[.lights] = shan.lightSpriteID }
                if shan.weaponGlowSpriteID > 0 { o[.weapons] = shan.weaponGlowSpriteID }
                overlayIDs[shan.baseSpriteID] = o
            }
        }
    }

    /// The classic overlay sprite ids of the hull drawn with `baseSpriteID`
    /// (empty for non-hull sprites and hulls without overlays).
    public func overlays(forBase baseSpriteID: Int) -> [GraphicsEnhancement.EffectLayer: Int] {
        overlayIDs[baseSpriteID] ?? [:]
    }

    public func layout(for sheet: SpriteSheet) -> BakeLayout {
        let id = sheet.sourceSpriteID ?? -1
        if let h = hulls[id], h.framesPerSet <= sheet.frameCount {
            return BakeLayout(frameWidth: sheet.frameWidth, frameHeight: sheet.frameHeight, frameCount: sheet.frameCount,
                              framesPerSet: h.framesPerSet, sets: SetPose.poses(setCount: h.sets, banking: h.banking))
        }
        return BakeLayout(frameWidth: sheet.frameWidth, frameHeight: sheet.frameHeight, frameCount: sheet.frameCount,
                          framesPerSet: sheet.frameCount, sets: [.level])
    }
}
#endif
