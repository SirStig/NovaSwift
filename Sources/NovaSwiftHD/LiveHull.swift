import Foundation
import NovaSwiftKit
#if canImport(SpriteKit) && canImport(SceneKit)
import SpriteKit
import SceneKit

/// A hull drawn live in 3D: its model turns with the ship's real heading and
/// banks with its turns, inside a SceneKit scene that SpriteKit places in the
/// world (`SK3DNode`). The "Full live 3D" presentation (docs/HD_PIPELINE.md).
///
/// The model is the same one the baker renders, with the same camera, pitch,
/// lights and fit, so a live hull covers the classic footprint the way its
/// baked frames do. Only the heading and bank change, every frame.
public final class LiveHull {
    public let node: SK3DNode
    public let stage: ModelStage
    private let onRelease: () -> Void

    /// - Parameters:
    ///   - template: the loaded model (not yet placed in a stage). Cloned, so
    ///     each live hull shares the template's geometry and materials.
    ///   - orthographicScale: the stage's fitted scale (see `ModelBaker.fit`).
    ///   - size: the hull's frame size in points, the classic sprite's size.
    ///   - onRelease: called once when this hull goes away, to free its budget slot.
    public init(template: SCNNode, settings: GraphicsEnhancement.BakeSettings,
                orthographicScale: Double, size: CGSize, onRelease: @escaping () -> Void) {
        stage = ModelStage(model: template.clone(), settings: settings)
        stage.orthographicScale = orthographicScale
        stage.setPass(.hull(baked: []))
        node = SK3DNode(viewportSize: size)
        node.scnScene = stage.scene
        node.pointOfView = stage.camera
        node.name = "live3D"
        node.autoenablesDefaultLighting = false
        self.onRelease = onRelease
    }

    /// Turn the model to `heading` (radians, the same convention as the baked
    /// frames: frame k of N sits at k·2π/N) and bank it by `bank` in −1…1
    /// (+1 = fully banked into a left turn).
    public func pose(heading: Double, bank: Double) {
        stage.pose(heading: heading, bank: bank)
    }

    deinit { onRelease() }
}
#endif
