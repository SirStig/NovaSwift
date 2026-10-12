import Foundation
import NovaSwiftKit
#if canImport(SpriteKit) && canImport(SceneKit)
import SpriteKit
import SceneKit

/// How a model is fitted for live drawing so it matches its baked frames
/// (see `ModelBaker.calibrateLive`).
public struct LiveHullCalibration: Sendable, Hashable {
    /// The stage camera's fitted scale: the model covers the classic footprint.
    public var orthographicScale: Double
    /// The bake's light multiplier: the model is as bright as the classic art.
    public var lightScale: Double
    public init(orthographicScale: Double, lightScale: Double) {
        self.orthographicScale = orthographicScale; self.lightScale = lightScale
    }
}

/// A hull drawn live in 3D: its model turns with the ship's real heading and
/// banks with its turns, inside a SceneKit scene that SpriteKit places in the
/// world (`SK3DNode`). The "Full live 3D" presentation (docs/HD_PIPELINE.md).
///
/// Set up exactly as its baked frames are: the same stage (camera, pitch,
/// lights, orientation), fit and light level, and the same effect pass, so
/// glow layers that have a classic overlay stay dark on the hull and keep
/// drawing as their own baked sheets on top, like they do over the sprite.
public final class LiveHull {
    public let node: SK3DNode
    public let stage: ModelStage
    private var bank: Double = 0

    /// - Parameters:
    ///   - template: the loaded (and possibly simplified) model, not placed in
    ///     a stage. Cloned; each hull gets its own geometry objects (sharing
    ///     the vertex data) so its effect pass can't touch other hulls.
    ///   - overlayLayers: effect layers the hull has a classic overlay for.
    ///   - size: the hull's frame size in points, the classic sprite's size.
    ///   - simpleLighting: cheaper shading for low-end devices (diffuse only,
    ///     no reflections).
    public init(template: SCNNode, descriptor: GraphicsEnhancement, calibration: LiveHullCalibration,
                overlayLayers: Set<GraphicsEnhancement.EffectLayer>, size: CGSize, simpleLighting: Bool) {
        let model = ModelLoader.instance(of: template)
        stage = ModelStage(model: model, settings: descriptor.bake ?? .init())
        stage.prepareEffects(for: descriptor)
        stage.orthographicScale = calibration.orthographicScale
        if calibration.lightScale != 1 { stage.scaleLights(by: calibration.lightScale) }
        stage.setPass(.hull(baked: stage.layersPresent.subtracting(overlayLayers)))
        if simpleLighting {
            stage.scene.lightingEnvironment.intensity = 0
            model.enumerateHierarchy { n, _ in
                guard let g = n.geometry else { return }
                g.materials = g.materials.map {
                    let m = $0.copy() as! SCNMaterial
                    m.lightingModel = .lambert
                    return m
                }
            }
        }
        node = SK3DNode(viewportSize: size)
        node.scnScene = stage.scene
        node.pointOfView = stage.camera
        node.name = "live3D"
        node.autoenablesDefaultLighting = false
    }

    /// Turn the model to `heading` (radians, the baked frames' convention:
    /// frame k of N sits at k·2π/N) and ease its bank toward `bank` in −1…1
    /// (+1 = fully banked into a left turn) over about a tenth of a second.
    public func update(heading: Double, bank target: Double, dt: Double) {
        bank += (target - bank) * min(1, max(0, dt) * 12)
        stage.pose(heading: heading, bank: bank)
    }
}
#endif
