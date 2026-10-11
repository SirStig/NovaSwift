import Foundation
import NovaSwiftKit
#if canImport(SceneKit)
import SceneKit
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// SceneKit's vector component type: `CGFloat` on macOS, `Float` elsewhere.
#if os(macOS)
public typealias SCNScalar = CGFloat
#else
public typealias SCNScalar = Float
#endif

/// Which pose a frame set shows: EV Nova hull sheets pack a level set and,
/// for banking hulls, a bank-left and a bank-right set (shän ExtraFrames 1).
public enum SetPose: String, Sendable, Hashable, Codable {
    case level, bankLeft, bankRight

    /// The poses for a hull's sets, the way `HullAnim.baseSet` picks them:
    /// set 1 = turning left, set 2 = turning right; any other mode draws
    /// every set level.
    public static func poses(setCount: Int, banking: Bool) -> [SetPose] {
        (0..<max(1, setCount)).map { i in
            guard banking else { return .level }
            return i == 1 ? .bankLeft : i == 2 ? .bankRight : .level
        }
    }
}

/// Loads a model asset (USDZ, or anything SceneKit opens) as a node,
/// centred on its bounds and scaled so its widest horizontal extent is 2
/// units (radius 1) — the stage fits it to the classic sprite afterwards.
public enum ModelLoader {
    public enum LoadError: Error, CustomStringConvertible {
        case unreadable(String)
        case empty
        public var description: String {
            switch self {
            case .unreadable(let s): return "model could not be opened (\(s))"
            case .empty: return "model has no geometry"
            }
        }
    }

    /// Where blob-embedded models are written so SceneKit can open them
    /// (it loads USDZ from a URL). Keyed by content, so each is written once.
    static var blobDirectory: URL {
        let caches = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("NovaSwift/HDModels", isDirectory: true)
    }

    public static func load(_ source: GraphicsAssetSource) throws -> SCNNode {
        let url: URL
        switch source {
        case .file(let u): url = u
        case .blob(let data):
            let key = source.contentKey() ?? UUID().uuidString
            let dir = blobDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("\(key).\(source.fileExtension ?? "usdz")")
            if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        }
        let scene: SCNScene
        do { scene = try SCNScene(url: url, options: [.checkConsistency: false]) } catch {
            throw LoadError.unreadable(String(describing: error))
        }
        return try normalized(scene.rootNode)
    }

    /// Wrap `root`'s children in a container centred on their bounds and
    /// scaled to radius 1 in the horizontal (XZ) plane.
    public static func normalized(_ root: SCNNode) throws -> SCNNode {
        let content = SCNNode()
        for child in root.childNodes { content.addChildNode(child.clone()) }
        if let g = root.geometry { content.geometry = g }
        let (lo, hi) = content.boundingBox
        let ex = Double(hi.x - lo.x), ez = Double(hi.z - lo.z)
        let half = max(ex, ez) / 2
        guard half > 0 else { throw LoadError.empty }
        content.position = SCNVector3(-(lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, -(lo.z + hi.z) / 2)
        let holder = SCNNode()
        holder.addChildNode(content)
        let s = Float(1 / half)
        holder.scale = SCNVector3(s, s, s)
        return holder
    }
}

/// A model posed the way EV Nova's pre-rendered sprites were shot: a fixed
/// camera looking down at the ship at `pitch` degrees, a key light fixed to
/// the screen (upper left, in front), a cool fill, a rim light and a dark
/// environment for metal reflections. The ship turns under the camera; the
/// lights never move — which is why every classic frame is lit the same way.
///
/// Used both to bake sprite frames and, live, inside the game scene.
public final class ModelStage {
    public let scene = SCNScene()
    public let camera = SCNNode()
    /// Heading (yaw) node; `roll` (bank) sits inside it, the model inside that.
    public let pivot = SCNNode()
    public let roll = SCNNode()
    public let settings: GraphicsEnhancement.BakeSettings

    public var pitchDegrees: Double { settings.pitch ?? 38 }
    public var bankDegrees: Double { settings.bankRoll ?? 30 }

    public init(model: SCNNode, settings: GraphicsEnhancement.BakeSettings) {
        self.settings = settings
        scene.background.contents = ModelStage.color(0, 0, 0, alpha: 0)
        scene.rootNode.addChildNode(pivot)
        pivot.addChildNode(roll)
        roll.addChildNode(model)
        model.eulerAngles.y = SCNScalar((settings.yaw ?? 0) * .pi / 180)

        let cam = SCNCamera()
        cam.usesOrthographicProjection = true
        cam.orthographicScale = 1.2
        cam.zNear = 0.1
        cam.zFar = 400
        camera.camera = cam
        let p = pitchDegrees * .pi / 180
        camera.position = SCNVector3(0, Float(sin(p) * 50), Float(cos(p) * 50))
        camera.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(camera)
        addLights()
        if let a = settings.atmosphere, a.count == 3 { addAtmosphere(around: model, color: a) }
    }

    /// A slightly larger shell around a (spherical) model that glows at the
    /// limb — strongest on the sunlit side — and is clear face-on.
    private func addAtmosphere(around model: SCNNode, color a: [Double]) {
        let (lo, hi) = model.boundingBox
        let s = Double(model.scale.x)
        let r = Double(max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)) * s / 2 * 1.035
        let shell = SCNSphere(radius: CGFloat(r))
        shell.segmentCount = 96
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = ModelStage.color(0, 0, 0)
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.isDoubleSided = false
        let key = simd_normalize(SIMD3<Double>(-0.75, 0.85, 0.65))
        let l = world(key)
        // Fresnel rim × sun side, in the fragment stage (view space).
        m.shaderModifiers = [.fragment: """
        #pragma body
        float3 n = normalize(_surface.normal);
        float rim = pow(1.0 - saturate(n.z), 3.0);
        float3 sunV = normalize((scn_frame.viewTransform * float4(\(l.x), \(l.y), \(l.z), 0.0)).xyz);
        float lit = saturate(dot(n, sunV) * 0.9 + 0.35);
        _output.color = float4(float3(\(a[0]), \(a[1]), \(a[2])) * rim * lit * 1.6, 1.0);
        """]
        shell.materials = [m]
        let node = SCNNode(geometry: shell)
        node.position = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
        roll.addChildNode(node)
    }

    /// Screen-space direction (x right, y up, z toward the viewer) → world.
    private func world(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let p = pitchDegrees * .pi / 180
        let right = SIMD3<Double>(1, 0, 0)
        let toward = SIMD3<Double>(0, sin(p), cos(p))
        let up = SIMD3<Double>(0, cos(p), -sin(p))
        return simd_normalize(v.x * right + v.y * up + v.z * toward)
    }

    private func addLights() {
        let exposure = settings.exposure ?? 1
        let keyDir = settings.light.flatMap { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : nil }
            ?? SIMD3(-0.75, 0.85, 0.65)
        func directional(_ toward: SIMD3<Double>, intensity: Double, _ r: Double, _ g: Double, _ b: Double) {
            let l = SCNLight()
            l.type = .directional
            l.intensity = CGFloat(intensity * exposure)
            l.color = ModelStage.color(r, g, b)
            let n = SCNNode()
            n.light = l
            let d = world(toward) * 100
            n.position = SCNVector3(Float(d.x), Float(d.y), Float(d.z))
            n.look(at: SCNVector3Zero)
            scene.rootNode.addChildNode(n)
        }
        if settings.atmosphere != nil {
            // A planet: one sun, a hard terminator, the night side near black —
            // the classic stellar look. No fill, rim or reflections.
            directional(keyDir, intensity: 2600, 1.0, 0.98, 0.94)
            let ambient = SCNLight()
            ambient.type = .ambient
            ambient.intensity = CGFloat(6 * exposure)
            let an = SCNNode(); an.light = ambient
            scene.rootNode.addChildNode(an)
            return
        }
        directional(keyDir, intensity: 2100, 1.0, 0.97, 0.92)              // key: warm white, upper left
        directional(SIMD3(0.8, -0.4, 0.4), intensity: 160, 0.55, 0.65, 0.85) // fill: cool, lower right
        directional(SIMD3(0.2, 0.6, -1.0), intensity: 650, 0.85, 0.9, 1.0)   // rim: from behind
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = CGFloat(25 * exposure)
        ambient.color = ModelStage.color(0.6, 0.65, 0.8)
        let an = SCNNode(); an.light = ambient
        scene.rootNode.addChildNode(an)
        scene.lightingEnvironment.contents = ModelStage.environmentImage
        environmentIntensity = CGFloat(0.5 * exposure)
        scene.lightingEnvironment.intensity = environmentIntensity
    }

    /// The hull pass's reflection strength (0 for planets).
    private var environmentIntensity: CGFloat = 0

    static func color(_ r: Double, _ g: Double, _ b: Double, alpha: Double = 1) -> Any {
        #if canImport(AppKit)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
        #else
        return UIColor(red: r, green: g, blue: b, alpha: alpha)
        #endif
    }

    /// A small equirectangular "space" environment: near-black with a soft
    /// warm glow toward the key light and a faint cool band — enough for
    /// metals to read as metal.
    static let environmentImage: CGImage = {
        let w = 256, h = 128
        let ctx = HDAtlas.makeContext(width: w, height: h)!
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        let sun = simd_normalize(SIMD3<Double>(-0.6, 0.7, 0.4))
        for y in 0..<h {
            for x in 0..<w {
                let u = Double(x) / Double(w), v = Double(y) / Double(h)
                let lat = (0.5 - v) * .pi, lon = (u - 0.5) * 2 * .pi
                let dir = SIMD3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
                let glow = pow(max(0, simd_dot(dir, sun)), 6) * 1.6
                let band = exp(-pow(lat / 0.25, 2)) * 0.08
                let r = 0.02 + glow + band * 0.6, g = 0.025 + glow * 0.9 + band * 0.7, b = 0.04 + glow * 0.8 + band
                let i = y * ctx.bytesPerRow + x * 4
                p[i] = UInt8(min(255, r * 255)); p[i + 1] = UInt8(min(255, g * 255))
                p[i + 2] = UInt8(min(255, b * 255)); p[i + 3] = 255
            }
        }
        return ctx.makeImage()!
    }()

    /// Pose the ship: `heading` in radians, clockwise from screen-up (frame
    /// k of N is `k * 2π / N`, as in the classic sheets); `bank` in −1…1
    /// (+1 = fully banked into a left turn).
    public func pose(heading: Double, bank: Double) {
        pivot.eulerAngles.y = SCNScalar(.pi - heading)
        roll.eulerAngles.z = SCNScalar(-bank * bankDegrees * .pi / 180)
    }

    public func pose(_ set: SetPose, heading: Double) {
        switch set {
        case .level: pose(heading: heading, bank: 0)
        case .bankLeft: pose(heading: heading, bank: 1)
        case .bankRight: pose(heading: heading, bank: -1)
        }
    }

    // MARK: Effect layers

    /// What to draw: the hull (its glowing parts switched off, except the
    /// layers in `baked`, which have no classic overlay to live in), or one
    /// effect layer alone — glowing parts and emitters, with the rest of the
    /// hull drawn black so the glow is hidden wherever the hull is in front.
    public enum Pass: Equatable {
        case hull(baked: Set<GraphicsEnhancement.EffectLayer>)
        case layer(GraphicsEnhancement.EffectLayer)
    }

    private struct Part {
        let node: SCNNode
        let original: [SCNMaterial]
        let layer: GraphicsEnhancement.EffectLayer?
    }
    private var parts: [Part] = []
    private var emitters: [(node: SCNNode, layer: GraphicsEnhancement.EffectLayer)] = []

    /// The layers this model actually has content for (tagged parts or emitters).
    public private(set) var layersPresent: Set<GraphicsEnhancement.EffectLayer> = []

    /// Sort the model's parts into effect layers by node/material name and
    /// add the descriptor's emitters. Call once, before rendering passes.
    public func prepareEffects(for descriptor: GraphicsEnhancement) {
        func classify(_ node: SCNNode) -> GraphicsEnhancement.EffectLayer? {
            var names: [String] = node.geometry?.materials.compactMap(\.name) ?? []
            var n: SCNNode? = node
            while let cur = n, cur !== roll { if let nm = cur.name { names.append(nm) }; n = cur.parent }
            let lower = names.map { $0.lowercased() }
            for layer in GraphicsEnhancement.EffectLayer.allCases {
                let keys = descriptor.nameMatches(layer)
                if lower.contains(where: { name in keys.contains { name.contains($0) } }) { return layer }
            }
            return nil
        }
        roll.enumerateHierarchy { node, _ in
            guard let g = node.geometry else { return }
            let layer = classify(node)
            parts.append(Part(node: node, original: g.materials, layer: layer))
            if let layer { layersPresent.insert(layer) }
        }
        addEmitters(descriptor.effects ?? [])
    }

    /// Add glowing emitters (descriptor ones, or ones derived from a classic overlay).
    public func addEmitters(_ effects: [GraphicsEnhancement.Effect]) {
        for e in effects where e.at.count == 3 {
            let r = e.radius ?? 0.06
            let c = e.color.flatMap { $0.count == 3 ? $0 : nil } ?? [0.55, 0.78, 1.0]
            let plane = SCNPlane(width: CGFloat(r * 3.6), height: CGFloat(r * 3.6))
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = ModelStage.glowImage
            m.multiply.contents = ModelStage.color(c[0], c[1], c[2])
            m.blendMode = .add
            m.writesToDepthBuffer = false
            m.isDoubleSided = true
            plane.materials = [m]
            let node = SCNNode(geometry: plane)
            node.position = SCNVector3(Float(e.at[0]), Float(e.at[1]), Float(e.at[2]))
            node.constraints = [SCNBillboardConstraint()]
            roll.addChildNode(node)
            emitters.append((node, e.layer))
            layersPresent.insert(e.layer)
        }
    }

    /// A bright blob of a classic overlay's frame 0, in hull-frame pixels
    /// (origin top-left of the hull's frame; overlays are centred on it).
    public struct GlowBlob {
        public let x: Double, y: Double
        public let radius: Double
        /// Share of the overlay frame it covers (big blobs = lit panels, not lamps).
        public let coverage: Double
        public let color: [Double]
    }

    /// The bright regions of a classic overlay's frame 0 (heading up, level —
    /// the hull seen from behind, so engines and tail lights are in view).
    public static func glowBlobs(in overlay: SpriteSheet, hullFrameWidth: Int, hullFrameHeight: Int) -> [GlowBlob] {
        let w = overlay.frameWidth, h = overlay.frameHeight
        guard w > 0, h > 0 else { return [] }
        var lum = [Double](repeating: 0, count: w * h)
        var rgb = [SIMD3<Double>](repeating: .zero, count: w * h)
        var peak = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * overlay.surfaceWidth + x) * 4
                guard overlay.rgba[o + 3] > 0 else { continue }
                let c = SIMD3(Double(overlay.rgba[o]), Double(overlay.rgba[o + 1]), Double(overlay.rgba[o + 2])) / 255
                let l = max(c.x, c.y, c.z)
                lum[y * w + x] = l; rgb[y * w + x] = c; peak = max(peak, l)
            }
        }
        guard peak > 0.05 else { return [] }
        let dx = Double(w - hullFrameWidth) / 2, dy = Double(h - hullFrameHeight) / 2
        var seen = [Bool](repeating: false, count: w * h)
        var out: [GlowBlob] = []
        for start in 0..<(w * h) where !seen[start] && lum[start] > peak * 0.3 {
            var stack = [start], sum = 0.0, cx = 0.0, cy = 0.0, area = 0, colour = SIMD3<Double>.zero
            seen[start] = true
            while let i = stack.popLast() {
                let x = i % w, y = i / w, l = lum[i]
                sum += l; cx += Double(x) * l; cy += Double(y) * l; area += 1; colour += rgb[i] * l
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                    let j = ny * w + nx
                    if !seen[j] && lum[j] > peak * 0.3 { seen[j] = true; stack.append(j) }
                }
            }
            guard area >= 2, sum > 0 else { continue }
            let c = colour / sum
            let m = max(c.x, c.y, c.z, 0.01)
            out.append(GlowBlob(x: cx / sum + 0.5 - dx, y: cy / sum + 0.5 - dy,
                                radius: sqrt(Double(area) / .pi),
                                coverage: Double(area) / Double(w * h),
                                color: [c.x / m, c.y / m, c.z / m]))
        }
        return out
    }

    public func setPass(_ pass: Pass) {
        for part in parts {
            guard let g = part.node.geometry else { continue }
            switch pass {
            case .hull(let baked):
                if let l = part.layer, !baked.contains(l) {
                    g.materials = part.original.map(ModelStage.unlit)
                } else {
                    g.materials = part.original
                }
            case .layer(let layer):
                g.materials = part.layer == layer ? part.original.map(ModelStage.glowOnly)
                                                  : part.original.map { _ in ModelStage.occluder }
            }
        }
        for e in emitters {
            switch pass {
            case .hull(let baked): e.node.isHidden = !baked.contains(e.layer)
            case .layer(let layer): e.node.isHidden = e.layer != layer
            }
        }
        // Layer passes are unlit glow on black; reflections only on the hull.
        if case .hull = pass { scene.lightingEnvironment.intensity = environmentIntensity }
        else { scene.lightingEnvironment.intensity = 0 }
    }

    /// A copy with its emission switched off (an engine at rest).
    static func unlit(_ m: SCNMaterial) -> SCNMaterial {
        let c = m.copy() as! SCNMaterial
        c.emission.contents = color(0, 0, 0)
        return c
    }

    /// Just the glow: the part's emission (or, failing that, its colour) unlit.
    static func glowOnly(_ m: SCNMaterial) -> SCNMaterial {
        let c = SCNMaterial()
        c.lightingModel = .constant
        let e = m.emission.contents
        let hasEmission: Bool = {
            guard let e else { return false }
            #if canImport(AppKit)
            if let col = e as? NSColor, let rgb = col.usingColorSpace(.sRGB) {
                return rgb.redComponent + rgb.greenComponent + rgb.blueComponent > 0.01
            }
            #else
            if let col = e as? UIColor {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                col.getRed(&r, green: &g, blue: &b, alpha: &a)
                return r + g + b > 0.01
            }
            #endif
            return true
        }()
        c.diffuse.contents = hasEmission ? e : m.diffuse.contents
        return c
    }

    /// Hull geometry in an effect pass: black, but still hiding what's behind it.
    static let occluder: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color(0, 0, 0)
        return m
    }()

    /// A soft round glow (white, multiplied by the emitter colour).
    static let glowImage: CGImage = {
        let size = 64
        let ctx = HDAtlas.makeContext(width: size, height: size)!
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * size)
        for y in 0..<size {
            for x in 0..<size {
                let dx = (Double(x) + 0.5) / Double(size) * 2 - 1, dy = (Double(y) + 0.5) / Double(size) * 2 - 1
                let d = sqrt(dx * dx + dy * dy)
                let core = max(0, 1 - d / 0.22)
                let halo = pow(max(0, 1 - d), 2.2)
                let v = min(1, core + halo * 0.85)
                let i = y * ctx.bytesPerRow + x * 4
                let b = UInt8(v * 255)
                p[i] = b; p[i + 1] = b; p[i + 2] = b; p[i + 3] = b
            }
        }
        return ctx.makeImage()!
    }()

    public var orthographicScale: Double {
        get { camera.camera?.orthographicScale ?? 1 }
        set { camera.camera?.orthographicScale = newValue }
    }
}
#endif
