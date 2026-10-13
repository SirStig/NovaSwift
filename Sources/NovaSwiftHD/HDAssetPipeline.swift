import Foundation
import NovaSwiftKit
import Crypto
#if canImport(Compression)
import Compression
#endif
#if canImport(SceneKit)
import SceneKit
import simd
import Metal
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The frame layout a model is rendered into: the classic sheet's own.
public struct BakeLayout: Hashable, Sendable {
    public var frameWidth: Int
    public var frameHeight: Int
    public var frameCount: Int
    /// Headings per set (shän FramesPer; 1 for a planet).
    public var framesPerSet: Int
    /// Pose per set; frames past the last listed set draw level.
    public var sets: [SetPose]

    public init(frameWidth: Int, frameHeight: Int, frameCount: Int, framesPerSet: Int, sets: [SetPose]) {
        self.frameWidth = frameWidth; self.frameHeight = frameHeight; self.frameCount = frameCount
        self.framesPerSet = max(1, framesPerSet); self.sets = sets
    }

    public var columns: Int { min(SpriteSheet.framesPerRow, frameCount) }
    public var rows: Int { (frameCount + columns - 1) / columns }

    public func pose(frame i: Int) -> (set: SetPose, heading: Double) {
        let set = i / framesPerSet
        return (set < sets.count ? sets[set] : .level, Double(i % framesPerSet) * 2 * .pi / Double(framesPerSet))
    }
}

/// Renders a model into an `HDAtlas` with SceneKit's offscreen renderer.
///
/// Every frame is drawn with the same fixed camera and lights; only the
/// model turns (and banks, for the banking sets), exactly how the classic
/// sheets were made. The model is sized automatically: a few headings are
/// rendered, measured and compared with the classic frames' opaque extents,
/// so the HD hull covers the same pixels as the classic one (and therefore
/// the same collision mask).
public final class ModelBaker {
    public struct Stats: Sendable {
        public var frames = 0
        public var seconds = 0.0
        public init() {}
    }

    private let renderer: SCNRenderer

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        renderer = SCNRenderer(device: device, options: nil)
        renderer.autoenablesDefaultLighting = false
    }

    /// The orthographic scale that makes the model cover the classic art's
    /// extent, averaged over a few headings of the level set. The extent is
    /// read from the model's vertices projected through the stage camera, so
    /// it needs no render: an overfilling model can't be clipped by the frame,
    /// and the result is the same every run.
    public func fit(stage: ModelStage, layout: BakeLayout, classic: SpriteSheet?, scale s: Double) {
        let fit = stage.settings.fit ?? 1
        let n = layout.framesPerSet
        let samples = Array(Set([0, n / 4, n / 2, 3 * n / 4])).filter { $0 < layout.frameCount }.sorted()
        let classicExtents = classic.map { ClassicFootprint.extents(of: $0, frames: samples) } ?? [:]
        let fallback = Double(min(layout.frameWidth, layout.frameHeight)) * 0.9
        let target = classicExtents.isEmpty ? fallback : classicExtents.values.reduce(0, +) / Double(classicExtents.count)
        // Visible height is 2·orthographicScale world units across frameHeight
        // pixels, so a silhouette of `units` covers units·H / (2·ortho) pixels.
        // Solve for the scale that makes it cover the classic extent.
        let height = Double(layout.frameHeight)
        var scales: [Double] = []
        for f in samples {
            let pose = layout.pose(frame: f)
            stage.pose(pose.set, heading: pose.heading)
            guard let units = ModelBaker.projectedExtent(of: stage.scene.rootNode, camera: stage.camera), units > 0 else { continue }
            let wanted = (classicExtents[f] ?? target) * fit
            guard wanted > 0 else { continue }
            // A planet's atmosphere shell is additive (so not counted above) but
            // its rim is visible: fit the shell, not the sphere, or the rim runs
            // past the frame and is cut flat where the classic art fills it.
            let silhouette = stage.settings.atmosphere?.count == 3 ? units * ModelStage.atmosphereScale : units
            scales.append(silhouette * height / (2 * wanted))
        }
        guard !scales.isEmpty else {
            stage.orthographicScale = height / (target * fit)
            return
        }
        stage.orthographicScale = scales.reduce(0, +) / Double(scales.count)
    }

    /// The width or height, in camera units, of the silhouette `root` makes in
    /// an orthographic `camera`: the bounding box of its visible vertices in
    /// the camera's view. Nil when there are no visible vertices.
    static func projectedExtent(of root: SCNNode, camera: SCNNode) -> Double? {
        let view = simd_inverse(camera.simdWorldTransform)
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        var any = false
        func visit(_ node: SCNNode) {
            guard !node.isHidden else { return }   // hidden emitters and layers aren't in the hull's silhouette
            if let g = node.geometry, g.materials.first?.blendMode != .add,   // additive glow shells aren't solid
               let src = g.sources(for: .vertex).first, src.componentsPerVector >= 3,
               src.bytesPerComponent == 4 || src.bytesPerComponent == 8 {
                let model = node.simdWorldTransform
                let m = view * model
                let wide = src.bytesPerComponent == 8
                src.data.withUnsafeBytes { raw in
                    for i in 0..<src.vectorCount {
                        let base = src.dataOffset + i * src.dataStride
                        let x, y, z: Float
                        if wide {
                            x = Float(raw.loadUnaligned(fromByteOffset: base, as: Double.self))
                            y = Float(raw.loadUnaligned(fromByteOffset: base + 8, as: Double.self))
                            z = Float(raw.loadUnaligned(fromByteOffset: base + 16, as: Double.self))
                        } else {
                            x = raw.loadUnaligned(fromByteOffset: base, as: Float.self)
                            y = raw.loadUnaligned(fromByteOffset: base + 4, as: Float.self)
                            z = raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self)
                        }
                        let c = m * SIMD4<Float>(x, y, z, 1)
                        lo = simd_min(lo, SIMD2(c.x, c.y)); hi = simd_max(hi, SIMD2(c.x, c.y))
                        any = true
                    }
                }
            }
            for child in node.childNodes { visit(child) }
        }
        visit(root)
        guard any else { return nil }
        return Double(max(hi.x - lo.x, hi.y - lo.y))
    }

    /// Scale the lighting so the model's mid and upper-mid tones match the
    /// classic frames at the same headings: remastered textures come out
    /// darker or lighter than the original renders, and a ship should read
    /// as bright as the one it replaces.
    @discardableResult
    private func matchBrightness(stage: ModelStage, layout: BakeLayout, classic: SpriteSheet, scale s: Double) -> Double {
        let n = layout.framesPerSet
        let samples = Array(Set((0..<8).map { $0 * n / 8 })).filter { $0 < layout.frameCount && $0 < classic.frameCount }.sorted()
        guard let target = ClassicFootprint.tones(of: classic, frames: samples), target.mid > 0.02 else { return 1 }
        let size = CGSize(width: Double(layout.frameWidth) * s, height: Double(layout.frameHeight) * s)
        var total = 1.0
        for _ in 0..<2 {   // lighting isn't linear through the tone curve; a second pass settles it
            let frames = samples.compactMap { f -> CGImage? in
                let pose = layout.pose(frame: f)
                stage.pose(pose.set, heading: pose.heading)
                return snapshot(size)
            }
            guard let got = ClassicFootprint.tones(of: frames), got.mid > 0.01 else { return total }
            let ratio = (target.mid / got.mid + target.high / max(got.high, 0.01)) / 2
            let k = min(3.0, max(0.6, total * ratio)) / total
            if abs(k - 1) < 0.04 { return total }
            stage.scaleLights(by: k)
            total *= k
        }
        return total
    }

    /// An effect layer to render: the hull's classic overlay it replaces.
    public struct LayerTarget {
        public let layer: GraphicsEnhancement.EffectLayer
        public let frameWidth: Int
        public let frameHeight: Int
        public let frameCount: Int
        /// The classic overlay itself: when the model has nothing for this
        /// layer, its glows are derived from where this one glows.
        public let classic: SpriteSheet?
        public init(layer: GraphicsEnhancement.EffectLayer, frameWidth: Int, frameHeight: Int, frameCount: Int,
                    classic: SpriteSheet? = nil) {
            self.layer = layer; self.frameWidth = frameWidth; self.frameHeight = frameHeight; self.frameCount = frameCount
            self.classic = classic
        }
    }

    public struct Result {
        public let base: HDAtlas
        public let layers: [GraphicsEnhancement.EffectLayer: HDAtlas]
    }

    /// Render the hull and its effect layers. A layer the model has content
    /// for goes into its classic overlay when the hull has one (`overlays`),
    /// otherwise it's drawn into the hull, always lit.
    public func bake(model: SCNNode, descriptor: GraphicsEnhancement, layout: BakeLayout, classic: SpriteSheet?,
                     overlays: [LayerTarget], scale: Double, stats: inout Stats) -> Result? {
        let start = Date()
        let stage = ModelStage(model: model, settings: descriptor.bake ?? .init())
        stage.prepareEffects(for: descriptor)
        stage.setPass(.hull(baked: []))
        let s = HDAtlas.clampScale(scale, logicalWidth: layout.columns * layout.frameWidth,
                                   logicalHeight: layout.rows * layout.frameHeight)
        fit(stage: stage, layout: layout, classic: classic, scale: s)
        // As bright as the art it replaces, unless the pack sets its own exposure
        // (planets keep their single-sun look).
        if let classic, descriptor.bake?.exposure == nil, descriptor.bake?.atmosphere == nil {
            matchBrightness(stage: stage, layout: layout, classic: classic, scale: s)
        }
        // Layers the model says nothing about glow where the classic overlay
        // glows (now that the fit fixes how big a classic pixel is).
        for t in overlays where !stage.layersPresent.contains(t.layer) {
            if let sheet = t.classic {
                stage.addEmitters(derivedEffects(stage: stage, layer: t.layer, overlay: sheet, layout: layout, scale: s))
            }
        }
        let separate = Set(overlays.map(\.layer)).intersection(stage.layersPresent)
        stage.setPass(.hull(baked: stage.layersPresent.subtracting(separate)))
        defer { renderer.scene = nil }
        guard let base = render(stage, layout: layout, scale: s, stats: &stats) else { return nil }

        var layers: [GraphicsEnhancement.EffectLayer: HDAtlas] = [:]
        let baseOrtho = stage.orthographicScale
        for t in overlays where separate.contains(t.layer) {
            stage.setPass(.layer(t.layer))
            // Same pixels-per-world-unit as the hull, in the overlay's own frame.
            stage.orthographicScale = baseOrtho * Double(t.frameHeight) / Double(layout.frameHeight)
            let l = BakeLayout(frameWidth: t.frameWidth, frameHeight: t.frameHeight, frameCount: t.frameCount,
                               framesPerSet: layout.framesPerSet, sets: layout.sets)
            // Glows are soft: half the hull's detail looks the same and costs a quarter of the memory.
            if let atlas = render(stage, layout: l, scale: max(1, (s / 2).rounded(.down)), stats: &stats) { layers[t.layer] = atlas }
        }
        stats.seconds += Date().timeIntervalSince(start)
        return Result(base: base, layers: layers)
    }

    /// Emitters where the classic overlay glows: each glow blob of its frame
    /// 0 is ray-cast onto the model as rendered at heading 0, so the glow sits
    /// on the model's own surface at that spot (the nearest part of the hull
    /// when the blob falls just off it). Lamp-sized blobs keep their size;
    /// big ones (lit panels, flame sprites) are capped and dimmed so they
    /// don't wash over the hull.
    private func derivedEffects(stage: ModelStage, layer: GraphicsEnhancement.EffectLayer, overlay: SpriteSheet,
                                layout: BakeLayout, scale s: Double) -> [GraphicsEnhancement.Effect] {
        let blobs = ModelStage.glowBlobs(in: overlay, hullFrameWidth: layout.frameWidth, hullFrameHeight: layout.frameHeight)
        guard !blobs.isEmpty else { return [] }
        stage.pose(.level, heading: 0)
        let unit = 2 * stage.orthographicScale / Double(layout.frameHeight)   // world units per classic pixel
        // Orthographic camera: every pixel's ray runs along the camera's front
        // direction from its point on the image plane. World space throughout,
        // so there's no screen-coordinate convention to get wrong.
        let cam = stage.camera
        let right = cam.simdWorldRight, up = cam.simdWorldUp, front = cam.simdWorldFront, eye = cam.simdWorldPosition
        func ray(_ px: Double, _ py: Double) -> SCNVector3? {
            let sx = Float((px - Double(layout.frameWidth) / 2) * unit)
            let sy = Float((Double(layout.frameHeight) / 2 - py) * unit)
            let from = eye + right * sx + up * sy, to = from + front * 400
            let hits = stage.scene.rootNode.hitTestWithSegment(from: SCNVector3(from), to: SCNVector3(to),
                                                               options: [SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue])
            return hits.filter { !($0.node.geometry is SCNPlane) }
                .min { simd_distance(SIMD3<Float>($0.worldCoordinates), from) < simd_distance(SIMD3<Float>($1.worldCoordinates), from) }?
                .worldCoordinates
        }
        /// The tail surface at sideways position `x` (roll space): rays cast
        /// forward (+Z, toward the nose) from behind the ship at a few heights;
        /// the rearmost hit is the nozzle face. Nil if nothing is there.
        func tail(atX x: Float) -> SIMD3<Float>? {
            var best: SIMD3<Float>?
            for y in stride(from: Float(-0.35), through: 0.35, by: 0.05) {
                let from = stage.roll.simdConvertPosition(SIMD3(x, y, -3), to: nil)
                let to = stage.roll.simdConvertPosition(SIMD3(x, y, 3), to: nil)
                let hits = stage.scene.rootNode.hitTestWithSegment(from: SCNVector3(from), to: SCNVector3(to),
                                                                   options: [SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue])
                for h in hits where !(h.node.geometry is SCNPlane) {
                    let local = stage.roll.simdConvertPosition(SIMD3<Float>(h.worldCoordinates), from: nil)
                    if best == nil || local.z < best!.z { best = local }
                }
            }
            return best
        }
        var out: [GraphicsEnhancement.Effect] = []
        for b in blobs {
            if layer == .engine {
                // Engines sit on the tail: the classic glow gives the sideways
                // position (frame 0 faces up, so screen right = the ship's
                // right = −x); the model's own tail gives the depth.
                let x = -Float((b.x - Double(layout.frameWidth) / 2) * unit)
                if let t = tail(atX: x) ?? tail(atX: x * 0.7) ?? tail(atX: 0) {
                    let radius = min(0.12, max(0.07, b.radius * unit * 1.2))
                    out.append(.init(layer: layer, at: [Double(t.x), Double(t.y), Double(t.z) - 0.02],
                                     radius: radius, color: b.color))
                }
                continue
            }
            // Search outward from the blob centre for the hull, up to a few pixels.
            var hit: SCNVector3?
            search: for r in [0.0, 1, 2, 3, 4, 6] {
                for (ox, oy) in r == 0 ? [(0.0, 0.0)] : [(r, 0), (-r, 0), (0, r), (0, -r), (r, r), (-r, r), (r, -r), (-r, -r)] {
                    if let h = ray(b.x + ox, b.y + oy) { hit = h; break search }
                }
            }
            guard let world = hit else { continue }
            let local = stage.roll.convertPosition(world, from: nil)
            let big = b.coverage > 0.02
            let floor = layer == .engine ? 0.07 : 0.03     // an engine glow has to read as thrust
            let radius = min(big ? 0.10 : 0.14, max(floor, b.radius * unit * 1.2))
            let k = big ? 0.6 : 1.0
            out.append(.init(layer: layer, at: [Double(local.x), Double(local.y), Double(local.z)],
                             radius: radius, color: b.color.map { $0 * k }))
        }
        return out
    }

    /// A UI portrait of the model: front three-quarter (nose toward the
    /// viewer and to the left), seen from slightly above, same lighting rig,
    /// transparent background, the ship filling ~85% of a `size`² image.
    /// For the shipyard, hail and target-display pictures.
    public func portrait(model: SCNNode, descriptor: GraphicsEnhancement, size: Int) -> CGImage? {
        var settings = descriptor.bake ?? .init()
        settings.pitch = 35   // the shipyard pictures look down a little more steeply than flight
        let stage = ModelStage(model: model, settings: settings, studio: true)
        stage.prepareEffects(for: descriptor)
        stage.setPass(.hull(baked: stage.layersPresent.subtracting([.engine])))
        renderer.scene = stage.scene
        renderer.pointOfView = stage.camera
        defer { renderer.scene = nil }
        stage.pose(heading: 225 * .pi / 180, bank: 0)
        return framed(stage, size: size)
    }

    /// Centre the model and scale it to span 85% of a `size`² image, then
    /// render. Starts zoomed out so the first measurement isn't clipped.
    private func framed(_ stage: ModelStage, size: Int) -> CGImage? {
        let px = CGSize(width: size, height: size)
        stage.orthographicScale = 3
        for _ in 0..<2 {
            guard let img = snapshot(px), let b = ClassicFootprint.bounds(of: img) else { break }
            let unit = 2 * stage.orthographicScale / Double(size)   // world units per pixel
            let dx = Float((b.midX - Double(size) / 2) * unit), dy = Float((Double(size) / 2 - b.midY) * unit)
            stage.camera.simdWorldPosition += stage.camera.simdWorldRight * dx + stage.camera.simdWorldUp * dy
            stage.orthographicScale *= Double(max(b.width, b.height)) / (Double(size) * 0.85)
        }
        return snapshot(px)
    }

    /// The model alone from any heading and elevation, scaled to fill 85% of
    /// a square image (tools: matching a model's pose to a reference picture).
    public func view(model: SCNNode, settings base: GraphicsEnhancement.BakeSettings,
                     heading: Double, pitch: Double, size: Int) -> CGImage? {
        var settings = base
        settings.pitch = pitch
        let stage = ModelStage(model: model, settings: settings)
        stage.setPass(.hull(baked: []))
        renderer.scene = stage.scene
        renderer.pointOfView = stage.camera
        defer { renderer.scene = nil }
        stage.pose(heading: heading * .pi / 180, bank: 0)
        return framed(stage, size: size)
    }

    /// What a live hull needs to match its baked frames: the same fit to the
    /// classic footprint and the same light level the bake would use.
    public func calibrateLive(model: SCNNode, descriptor: GraphicsEnhancement, layout: BakeLayout,
                              classic: SpriteSheet?) -> LiveHullCalibration {
        let stage = ModelStage(model: model, settings: descriptor.bake ?? .init())
        stage.prepareEffects(for: descriptor)
        stage.setPass(.hull(baked: []))
        defer { renderer.scene = nil }
        let s = 2.0   // the fit compares ratios, so any scale measures the same; 2 rounds less
        fit(stage: stage, layout: layout, classic: classic, scale: s)
        var light = 1.0
        if let classic, descriptor.bake?.exposure == nil, descriptor.bake?.atmosphere == nil {
            light = matchBrightness(stage: stage, layout: layout, classic: classic, scale: s)
        }
        return LiveHullCalibration(orthographicScale: stage.orthographicScale, lightScale: light)
    }

    /// Hull only, no effect layers (tools and simple models).
    public func bake(model: SCNNode, settings: GraphicsEnhancement.BakeSettings, layout: BakeLayout,
                     classic: SpriteSheet?, scale: Double, stats: inout Stats) -> HDAtlas? {
        bake(model: model, descriptor: GraphicsEnhancement(kind: .model, bake: settings), layout: layout,
             classic: classic, overlays: [], scale: scale, stats: &stats)?.base
    }

    private func render(_ stage: ModelStage, layout: BakeLayout, scale s: Double, stats: inout Stats) -> HDAtlas? {
        renderer.scene = stage.scene
        renderer.pointOfView = stage.camera
        let fw = Int((Double(layout.frameWidth) * s).rounded()), fh = Int((Double(layout.frameHeight) * s).rounded())
        let size = CGSize(width: fw, height: fh)
        guard let ctx = HDAtlas.makeContext(width: layout.columns * fw, height: layout.rows * fh) else { return nil }
        for i in 0..<layout.frameCount {
            let pose = layout.pose(frame: i)
            stage.pose(pose.set, heading: pose.heading)
            guard let img = snapshot(size) else { continue }
            let col = i % layout.columns, row = i / layout.columns
            ctx.draw(img, in: CGRect(x: col * fw, y: (layout.rows - 1 - row) * fh, width: fw, height: fh))
            stats.frames += 1
        }
        guard let image = ctx.makeImage() else { return nil }
        return HDAtlas(image: image, frameWidth: layout.frameWidth, frameHeight: layout.frameHeight,
                       frameCount: layout.frameCount, columns: layout.columns, pixelScale: s)
    }

    func snapshot(_ size: CGSize) -> CGImage? {
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        #if canImport(AppKit)
        var rect = CGRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return image.cgImage
        #endif
    }
}

/// Bakes persisted across launches, keyed by the model's bytes, its bake
/// settings, the target layout and scale — so each model is baked once per
/// device, whichever plug-ins are on.
public final class HDBakeCache: @unchecked Sendable {
    public let directory: URL
    /// Bump to invalidate every bake when the renderer's output changes.
    public static let version = 13   // 13: planets fit to their atmosphere shell

    public convenience init?(subdirectory: String = "NovaSwift/HDBakes") {
        guard let caches = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true) else { return nil }
        self.init(directory: caches.appendingPathComponent(subdirectory, isDirectory: true))
    }

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func key(contentKey: String, settings: GraphicsEnhancement.BakeSettings, layout: BakeLayout,
                           scale: Double) -> String {
        key(contentKey: contentKey, descriptor: GraphicsEnhancement(kind: .model, bake: settings),
            layout: layout, scale: scale, part: "hull")
    }

    /// Everything that shapes a render: the model's bytes, the descriptor
    /// (bake settings, effect layers, emitters — not where the file lives),
    /// the frame layout, the scale, and which output (`hull` or a layer).
    public static func key(contentKey: String, descriptor: GraphicsEnhancement, layout: BakeLayout,
                           scale: Double, part: String) -> String {
        var d = descriptor
        d.file = nil; d.blob = nil; d.sprite = nil
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let s = ((try? enc.encode(d)).map { String(decoding: $0, as: UTF8.self) } ?? "") + "|" + part
        let l = (try? enc.encode(layout.sets)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let text = "v\(version)|\(contentKey)|\(s)|\(layout.frameWidth)x\(layout.frameHeight)x\(layout.frameCount)/\(layout.framesPerSet)|\(l)|\(scale)"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func load(_ key: String, layout: BakeLayout, scale: Double) -> HDAtlas? {
        guard let image = loadImage(key) else { return nil }
        return HDAtlas(image: image, frameWidth: layout.frameWidth, frameHeight: layout.frameHeight,
                       frameCount: layout.frameCount, columns: layout.columns, pixelScale: scale)
    }

    /// A stored image: the fast raw form, or a PNG from an older cache
    /// (rewritten in the raw form, so it's only ever decoded slowly once).
    public func loadImage(_ key: String) -> CGImage? {
        #if canImport(Compression)
        if let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".nsa"), options: .mappedIfSafe),
           let image = HDAtlas.decodeRaw(data) {
            return image
        }
        #endif
        let png = directory.appendingPathComponent(key + ".png")
        guard let data = try? Data(contentsOf: png), let image = HDAtlas.decodePNG(data) else { return nil }
        #if canImport(Compression)
        if let raw = HDAtlas.encodeRaw(image),
           (try? raw.write(to: directory.appendingPathComponent(key + ".nsa"), options: .atomic)) != nil {
            try? FileManager.default.removeItem(at: png)
        }
        #endif
        return image
    }

    public func store(_ key: String, _ atlas: HDAtlas) {
        store(key, image: atlas.image)
    }

    public func store(_ key: String, image: CGImage) {
        #if canImport(Compression)
        if let data = HDAtlas.encodeRaw(image) {
            try? data.write(to: directory.appendingPathComponent(key + ".nsa"), options: .atomic)
            return
        }
        #endif
        guard let data = HDAtlas.encodePNG(image) else { return }
        try? data.write(to: directory.appendingPathComponent(key + ".png"), options: .atomic)
    }

    /// A small list stored beside a bake (which effect layers it produced).
    public func loadList(_ key: String) -> [String]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".layers.json")) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    public func storeList(_ key: String, _ list: [String]) {
        guard let data = try? JSONEncoder().encode(list.sorted()) else { return }
        try? data.write(to: directory.appendingPathComponent(key + ".layers.json"), options: .atomic)
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

/// The one entry point: an enhancement + the classic sheet it replaces → the
/// HD atlas to draw. Sprite atlases are decoded and checked; models are
/// baked (or read back from the bake cache).
public enum HDAssetPipeline {
    public enum PipelineError: Error, CustomStringConvertible {
        case unreadable
        case noRenderer
        case bakeFailed
        public var description: String {
            switch self {
            case .unreadable: return "asset could not be read"
            case .noRenderer: return "no Metal device for model rendering"
            case .bakeFailed: return "model rendering failed"
            }
        }
    }

    /// Serialises bakes: one offscreen renderer, reused.
    private static let bakeLock = NSLock()
    nonisolated(unsafe) private static var sharedBaker: ModelBaker?

    /// The scale a model will be baked at for this layout and detail cap.
    public static func bakeScale(_ e: ResolvedGraphicsEnhancement, layout: BakeLayout, maxScale: Double) -> Double {
        let wanted = min(maxScale, e.descriptor.bake?.scale ?? maxScale)
        return HDAtlas.clampScale(wanted, logicalWidth: layout.columns * layout.frameWidth,
                                  logicalHeight: layout.rows * layout.frameHeight)
    }

    /// The classic overlay a hull's effect layer replaces.
    public struct OverlayTarget {
        public let spriteID: Int
        public let target: ModelBaker.LayerTarget
        public init(spriteID: Int, target: ModelBaker.LayerTarget) { self.spriteID = spriteID; self.target = target }
    }

    /// A model's UI portrait (see `ModelBaker.portrait`), cached like bakes.
    /// nil for sprite (non-model) enhancements.
    public static func portrait(for e: ResolvedGraphicsEnhancement, size: Int = 512,
                                cache: HDBakeCache?) throws -> CGImage? {
        guard e.descriptor.kind == .model else { return nil }
        guard let content = e.source.contentKey() else { throw PipelineError.unreadable }
        let layout = BakeLayout(frameWidth: size, frameHeight: size, frameCount: 1, framesPerSet: 1, sets: [.level])
        let key = HDBakeCache.key(contentKey: content, descriptor: e.descriptor, layout: layout, scale: 1, part: "portrait-v2")   // v2: studio light, centred, 225°/35°
        if let hit = cache?.load(key, layout: layout, scale: 1) { return hit.image }
        let model = try ModelLoader.load(e.source)
        bakeLock.lock(); defer { bakeLock.unlock() }
        if sharedBaker == nil { sharedBaker = ModelBaker() }
        guard let baker = sharedBaker, let image = baker.portrait(model: model, descriptor: e.descriptor, size: size)
        else { throw PipelineError.bakeFailed }
        cache?.store(key, HDAtlas(image: image, frameWidth: size, frameHeight: size, frameCount: 1, columns: 1, pixelScale: 1))
        return image
    }

    /// A model's live-drawing calibration (`ModelBaker.calibrateLive`),
    /// cached with the bakes so a warm start renders nothing.
    /// `model`: the already loaded model, if the caller has one (it's cloned,
    /// never placed); otherwise it's loaded here on a cache miss.
    public static func liveCalibration(for e: ResolvedGraphicsEnhancement, classic: SpriteSheet, layout: BakeLayout,
                                       model loaded: SCNNode? = nil, cache: HDBakeCache?) throws -> LiveHullCalibration {
        guard e.descriptor.kind == .model, let key = liveCacheKey(for: e, layout: layout) else { throw PipelineError.unreadable }
        if let list = cache?.loadList(key), list.count == 2, let o = Double(list[0]), let l = Double(list[1]) {
            return LiveHullCalibration(orthographicScale: o, lightScale: l)
        }
        let model = try loaded.map(ModelLoader.instance(of:)) ?? ModelLoader.load(e.source)
        bakeLock.lock(); defer { bakeLock.unlock() }
        if sharedBaker == nil { sharedBaker = ModelBaker() }
        guard let baker = sharedBaker else { throw PipelineError.noRenderer }
        let c = baker.calibrateLive(model: model, descriptor: e.descriptor, layout: layout, classic: classic)
        cache?.storeList(key, [String(c.orthographicScale), String(c.lightScale)])
        return c
    }

    /// Where a model's live fit is cached.
    public static func liveCacheKey(for e: ResolvedGraphicsEnhancement, layout: BakeLayout) -> String? {
        guard let content = e.source.contentKey() else { return nil }
        return HDBakeCache.key(contentKey: content, descriptor: e.descriptor, layout: layout, scale: 1, part: "live-v4")
    }

    /// Just the hull/sprite atlas (no effect layers).
    public static func atlas(for e: ResolvedGraphicsEnhancement, classic: SpriteSheet, layout: BakeLayout,
                             maxScale: Double, cache: HDBakeCache?) throws -> HDAtlas {
        let all = try atlases(for: e, classic: classic, layout: layout, overlays: [], maxScale: maxScale, cache: cache)
        guard let base = all[e.spriteID] else { throw PipelineError.bakeFailed }
        return base
    }

    /// The enhancement's atlas plus, for a model with effect layers, an atlas
    /// for each classic overlay it replaces — keyed by sprite id.
    /// The shield bubble for a hull's prepared atlas (see `HDShield.make`),
    /// cached with the bakes: it's a per-pixel pass over every frame, too slow
    /// to repeat on every launch.
    public static func shield(for e: ResolvedGraphicsEnhancement, hull: HDAtlas, frames: Int,
                              color: [Double], cache: HDBakeCache?) -> HDAtlas? {
        let n = min(frames, hull.frameCount)
        guard n > 0, color.count == 3 else { return nil }
        let fw = Int((Double(hull.frameWidth) * HDShield.frameGrowth).rounded())
        let fh = Int((Double(hull.frameHeight) * HDShield.frameGrowth).rounded())
        let layout = BakeLayout(frameWidth: fw, frameHeight: fh, frameCount: n, framesPerSet: n, sets: [.level])
        let content = e.source.contentKey()
        let key = content.map {
            HDBakeCache.key(contentKey: $0, descriptor: e.descriptor, layout: layout, scale: hull.pixelScale,
                            part: "shield-v1-" + color.map { String(format: "%.3f", $0) }.joined(separator: ","))
        }
        if let cache, let key, let hit = cache.load(key, layout: layout, scale: hull.pixelScale) { return hit }
        guard let made = HDShield.make(from: hull, frames: n, color: color) else { return nil }
        if let cache, let key { cache.store(key, made) }
        return made
    }

    public static func atlases(for e: ResolvedGraphicsEnhancement, classic: SpriteSheet, layout: BakeLayout,
                               overlays: [OverlayTarget], maxScale: Double,
                               cache: HDBakeCache?) throws -> [Int: HDAtlas] {
        switch e.descriptor.kind {
        case .sprite:
            // Checked, capped and stored in the fast form once; a PNG decode
            // (and any downscale) isn't repeated every launch.
            let key = e.source.contentKey().map {
                HDBakeCache.key(contentKey: $0, descriptor: e.descriptor, layout: layout, scale: maxScale, part: "sprite-v1")
            }
            if let cache, let key, let image = cache.loadImage(key) {
                // The scale `HDAtlas.load` settled on: the pack's, capped.
                let columns = min(e.descriptor.effectiveColumns, classic.frameCount)
                let rows = (classic.frameCount + columns - 1) / columns
                let cap = HDAtlas.clampScale(maxScale, logicalWidth: columns * classic.frameWidth,
                                             logicalHeight: rows * classic.frameHeight)
                let atlas = HDAtlas(image: image, frameWidth: classic.frameWidth, frameHeight: classic.frameHeight,
                                    frameCount: classic.frameCount, columns: columns,
                                    pixelScale: min(e.descriptor.effectiveScale, cap))
                return [e.spriteID: atlas]
            }
            guard let data = e.source.loadData() else { throw PipelineError.unreadable }
            let atlas = try HDAtlas.load(data, descriptor: e.descriptor, classic: classic, maxScale: maxScale)
            if let cache, let key { cache.store(key, atlas) }
            return [e.spriteID: atlas]
        case .model:
            let scale = bakeScale(e, layout: layout, maxScale: maxScale)
            guard let content = e.source.contentKey() else { throw PipelineError.unreadable }
            func layerLayout(_ t: ModelBaker.LayerTarget) -> BakeLayout {
                BakeLayout(frameWidth: t.frameWidth, frameHeight: t.frameHeight, frameCount: t.frameCount,
                           framesPerSet: layout.framesPerSet, sets: layout.sets)
            }
            // Which overlays were produced last time is part of what's cached:
            // a manifest per hull lists them, so a warm load never re-renders.
            let hullKey = HDBakeCache.key(contentKey: content, descriptor: e.descriptor, layout: layout,
                                          scale: scale, part: "hull+" + overlays.map { "\($0.target.layer.rawValue)\($0.target.frameWidth)x\($0.target.frameHeight)x\($0.target.frameCount)" }.joined(separator: ","))
            if let cache, let hull = cache.load(hullKey, layout: layout, scale: scale), let made = cache.loadList(hullKey) {
                var out = [e.spriteID: hull]
                for o in overlays where made.contains(o.target.layer.rawValue) {
                    let k = HDBakeCache.key(contentKey: content, descriptor: e.descriptor, layout: layerLayout(o.target),
                                            scale: scale, part: o.target.layer.rawValue)
                    if let a = cache.load(k, layout: layerLayout(o.target), scale: scale) { out[o.spriteID] = a }
                }
                return out
            }
            let model = try ModelLoader.load(e.source)
            bakeLock.lock(); defer { bakeLock.unlock() }
            if sharedBaker == nil { sharedBaker = ModelBaker() }
            guard let baker = sharedBaker else { throw PipelineError.noRenderer }
            var stats = ModelBaker.Stats()
            guard let result = baker.bake(model: model, descriptor: e.descriptor, layout: layout, classic: classic,
                                          overlays: overlays.map(\.target), scale: scale, stats: &stats)
            else { throw PipelineError.bakeFailed }
            var out = [e.spriteID: result.base]
            cache?.store(hullKey, result.base)
            for o in overlays {
                guard let a = result.layers[o.target.layer] else { continue }
                out[o.spriteID] = a
                cache?.store(HDBakeCache.key(contentKey: content, descriptor: e.descriptor, layout: layerLayout(o.target),
                                             scale: scale, part: o.target.layer.rawValue), a)
            }
            cache?.storeList(hullKey, result.layers.keys.map(\.rawValue))
            Log.graphics.info("HD: baked sprite \(e.spriteID, privacy: .public) + \(result.layers.count, privacy: .public) effect layer(s) — \(stats.frames, privacy: .public) frames at \(scale, privacy: .public)x in \(Int(stats.seconds * 1000), privacy: .public) ms")
            return out
        }
    }
}
#endif
