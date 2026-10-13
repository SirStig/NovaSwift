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
/// banks with its turns. The "Full live 3D" presentation (docs/HD_PIPELINE.md).
///
/// Set up exactly as its baked frames are: the same stage (camera, pitch,
/// lights, orientation), fit and light level, and the same effect pass, so
/// glow layers that have a classic overlay stay dark on the hull and keep
/// drawing as their own baked sheets on top, like they do over the sprite.
///
/// Drawn one of two ways. **Shared** (`isShared`): the model joins a
/// `LiveHullLayer`, one SceneKit scene and render for every hull in a draw
/// band, so ten ships cost one 3D pass, not ten. **Standalone**: its own
/// stage in its own `SK3DNode` (`node`), for a hull whose pack changes the
/// camera or lights (pitch, key light, exposure), which a shared rig can't.
public final class LiveHull {
    public let stage: ModelStage
    /// The hull's frame size in points (the classic sprite's size).
    public let size: CGSize
    public let calibration: LiveHullCalibration
    /// Drawn in a `LiveHullLayer` rather than in `node`.
    public let isShared: Bool
    private var bank: Double = 0

    /// The standalone presentation (not used for a shared hull).
    public private(set) lazy var node: SK3DNode = {
        let n = SK3DNode(viewportSize: size)
        n.scnScene = stage.scene
        n.pointOfView = stage.camera
        n.name = "live3D"
        n.autoenablesDefaultLighting = false
        return n
    }()

    /// The layer a shared hull is in, and its holder there (set by the layer).
    public internal(set) weak var layer: LiveHullLayer?
    let holder = SCNNode()
    /// Placed in its layer this frame (see `LiveHullLayer.endFrame`).
    var placed = false

    /// Leave the layer a shared hull is in.
    public func detach() { layer?.remove(self) }

    /// - Parameters:
    ///   - template: the loaded (and possibly simplified) model, not placed in
    ///     a stage. Cloned; each hull gets its own geometry objects (sharing
    ///     the vertex data) so its effect pass can't touch other hulls.
    ///   - overlayLayers: effect layers the hull has a classic overlay for.
    ///   - size: the hull's frame size in points, the classic sprite's size.
    ///   - simpleLighting: cheaper shading for low-end devices (diffuse only,
    ///     no reflections).
    ///   - shareable: draw it in a `LiveHullLayer` when its stage allows.
    public init(template: SCNNode, descriptor: GraphicsEnhancement, calibration: LiveHullCalibration,
                overlayLayers: Set<GraphicsEnhancement.EffectLayer>, size: CGSize, simpleLighting: Bool,
                shareable: Bool = true) {
        let model = ModelLoader.instance(of: template)
        stage = ModelStage(model: model, settings: descriptor.bake ?? .init())
        self.size = size
        self.calibration = calibration
        stage.prepareEffects(for: descriptor)
        stage.orthographicScale = calibration.orthographicScale
        stage.setPass(.hull(baked: stage.layersPresent.subtracting(overlayLayers)))
        var shared = shareable && LiveHullLayer.canShare(descriptor.bake)
        // A material with a fragment shader of its own can't take the shared
        // light parameter; such a hull keeps its own stage.
        stage.roll.enumerateHierarchy { n, _ in
            if n.geometry?.materials.contains(where: { $0.shaderModifiers?[.fragment] != nil }) == true { shared = false }
        }
        isShared = shared
        if !shared, calibration.lightScale != 1 { stage.scaleLights(by: calibration.lightScale) }
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
        // SK3DNode shows SceneKit's output as if it were already sRGB, but
        // SceneKit writes linear values, so unencoded the hull draws darker than
        // its baked sprite (a grey of v comes out as v^2.2). Encoding every
        // fragment here puts the live hull on the same footing as the bake.
        // Shared: the light level is applied here too (lit materials only, as
        // scaling the rig would), with emission divided back out.
        let k = calibration.lightScale
        stage.roll.enumerateHierarchy { n, _ in
            guard let g = n.geometry else { return }
            g.materials = g.materials.map { m in
                let c = m.copy() as! SCNMaterial
                if shared {
                    let lit = c.lightingModel != .constant
                    c.shaderModifiers = [.fragment: Self.sharedFragment]
                    c.setValue(NSNumber(value: lit ? k : 1), forKey: "novaLight")
                    if lit, k > 0 { c.emission.intensity /= CGFloat(k) }
                } else {
                    c.shaderModifiers = Self.srgbEncoded(c.shaderModifiers)
                }
                return c
            }
        }
        if shared {
            stage.pivot.removeFromParentNode()
            holder.addChildNode(stage.pivot)
        }
    }

    /// The material's fragment shader with the sRGB encode appended (keeping
    /// any modifier it already has, such as an atmosphere's glow).
    private static func srgbEncoded(_ modifiers: [SCNShaderModifierEntryPoint: String]?) -> [SCNShaderModifierEntryPoint: String] {
        var out = modifiers ?? [:]
        let encode = "_output.color.rgb = pow(_output.color.rgb, float3(1.0 / 2.2));"
        if let body = out[.fragment] { out[.fragment] = body + "\n" + encode }
        else { out[.fragment] = "#pragma body\n" + encode }
        return out
    }

    /// A shared hull's light level and sRGB encode.
    private static let sharedFragment = """
    #pragma arguments
    float novaLight;
    #pragma body
    _output.color.rgb = pow(max(_output.color.rgb * novaLight, float3(0.0)), float3(1.0 / 2.2));
    """

    /// Turn the model to `heading` (radians, the baked frames' convention:
    /// frame k of N sits at k·2π/N) and ease its bank toward `bank` in −1…1
    /// (+1 = fully banked into a left turn) over about a tenth of a second.
    public func update(heading: Double, bank target: Double, dt: Double) {
        bank += (target - bank) * min(1, max(0, dt) * 12)
        stage.pose(heading: heading, bank: bank)
    }
}

/// Many live hulls in one SceneKit scene, drawn by one `SK3DNode`.
///
/// Each stage's camera is orthographic and its lights are directional (plus
/// ambient and a reflection map), all fixed to the screen — so one camera
/// and one rig light every hull exactly as its own stage would, wherever it
/// sits. A hull is placed at its ship's offset from the layer's centre and
/// scaled so its model covers the same points its own viewport gave it; its
/// light level rides on its materials (`LiveHull.sharedFragment`). Hulls are
/// spaced in depth so overlapping ships stack instead of interpenetrating.
///
/// The scene is in points: one world unit is one point of the viewport.
public final class LiveHullLayer {
    public let node: SK3DNode
    private let stage: ModelStage
    private var hulls: [ObjectIdentifier: LiveHull] = [:]

    /// Room in depth for each hull (points); hulls are at most a few hundred across.
    static let depthSpacing: Double = 600
    public static let maxDepthSlots = 64

    /// Whether a hull with these bake settings lights and frames like the
    /// shared rig: the default camera pitch, key light and exposure.
    public static func canShare(_ s: GraphicsEnhancement.BakeSettings?) -> Bool {
        guard let s else { return true }
        return (s.pitch == nil || s.pitch == 38) && s.light == nil && s.exposure == nil && s.atmosphere == nil
    }

    public init(simpleLighting: Bool) {
        stage = ModelStage(model: SCNNode(), settings: .init())
        viewPitch = stage.pitchDegrees
        stage.camera.camera?.zNear = 1
        stage.camera.camera?.zFar = Self.cameraDistance * 2
        if simpleLighting { stage.scene.lightingEnvironment.intensity = 0 }
        node = SK3DNode(viewportSize: CGSize(width: 2, height: 2))
        node.scnScene = stage.scene
        node.pointOfView = stage.camera
        node.name = "live3DLayer"
        node.autoenablesDefaultLighting = false
        aimCamera()
    }

    public var isEmpty: Bool { hulls.isEmpty }
    public var count: Int { hulls.count }

    /// Far enough back that the nearest hull is in front of the camera.
    static let cameraDistance = depthSpacing * Double(maxDepthSlots + 2)

    /// The camera's elevation, degrees: the stage's own (38, as the classic
    /// frames were shot) unless a lower camera view asks for a flatter look.
    /// The lights stay where the stage put them.
    public var viewPitch: Double {
        didSet { if viewPitch != oldValue { aimCamera() } }
    }

    private func aimCamera() {
        let p = viewPitch * .pi / 180, back = Self.cameraDistance
        stage.camera.position = SCNVector3(0, Float(sin(p) * back), Float(cos(p) * back))
        stage.camera.look(at: SCNVector3Zero)
    }

    public func add(_ hull: LiveHull) {
        guard hull.isShared, hull.layer !== self else { return }
        hull.layer?.remove(hull)
        hull.layer = self
        hulls[ObjectIdentifier(hull)] = hull
        stage.scene.rootNode.addChildNode(hull.holder)
    }

    public func remove(_ hull: LiveHull) {
        guard hull.layer === self else { return }
        hull.holder.removeFromParentNode()
        hull.layer = nil
        hulls[ObjectIdentifier(hull)] = nil
    }

    public func removeAll() {
        for hull in hulls.values { hull.holder.removeFromParentNode(); hull.layer = nil }
        hulls = [:]
    }

    /// Start a frame: hulls not `place`d before `endFrame` leave the layer
    /// (their ship left the screen, or the scene, without saying so).
    public func beginFrame() { for h in hulls.values { h.placed = false } }

    public func endFrame() {
        for h in hulls.values where !h.placed { remove(h) }
    }

    /// The area drawn, in points (the visible part of the scene).
    public func setViewport(_ size: CGSize) {
        let s = CGSize(width: max(2, size.width.rounded(.up)), height: max(2, size.height.rounded(.up)))
        if node.viewportSize != s { node.viewportSize = s }
        stage.orthographicScale = Double(s.height) / 2
    }

    /// Put `hull` at `offset` points from the layer's centre, `opacity` in
    /// 0…1, in depth slot `depth` (higher draws in front).
    public func place(_ hull: LiveHull, at offset: CGPoint, opacity: CGFloat, depth: Int) {
        let cam = stage.camera
        let toward = -cam.simdWorldFront   // toward the camera
        let slot = Double(min(max(depth, 0), Self.maxDepthSlots))
        let p = cam.simdWorldRight * Float(offset.x) + cam.simdWorldUp * Float(offset.y)
            + toward * Float(slot * Self.depthSpacing)
        hull.placed = true
        hull.holder.simdPosition = p
        // Own stage: frame height h points shows 2·o world units → h/(2o) points per unit.
        let k = Float(Double(hull.size.height) / (2 * hull.calibration.orthographicScale))
        hull.holder.simdScale = SIMD3(repeating: k)
        hull.holder.opacity = opacity
        hull.holder.isHidden = opacity <= 0.001
    }

    /// Offscreen render (tools and tests): the layer's scene as `node` would draw it.
    public var scene: SCNScene { stage.scene }
    public var camera: SCNNode { stage.camera }
}
#endif
