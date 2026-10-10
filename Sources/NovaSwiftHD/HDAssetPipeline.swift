import Foundation
import NovaSwiftKit
import Crypto
#if canImport(SceneKit)
import SceneKit
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
    /// extent, measured over a few headings of the level set.
    public func fit(stage: ModelStage, layout: BakeLayout, classic: SpriteSheet?, scale s: Double) {
        renderer.scene = stage.scene
        renderer.pointOfView = stage.camera
        let size = CGSize(width: Double(layout.frameWidth) * s, height: Double(layout.frameHeight) * s)
        let fit = stage.settings.fit ?? 1
        let n = layout.framesPerSet
        let samples = Array(Set([0, n / 4, n / 2, 3 * n / 4])).filter { $0 < layout.frameCount }.sorted()
        let classicExtents = classic.map { ClassicFootprint.extents(of: $0, frames: samples) } ?? [:]
        let fallback = Double(min(layout.frameWidth, layout.frameHeight)) * 0.9
        let target = classicExtents.isEmpty ? fallback : classicExtents.values.reduce(0, +) / Double(classicExtents.count)
        // orthographicScale = half the visible height in world units; the
        // model's radius is 1, so start from "diameter fills the target".
        stage.orthographicScale = Double(layout.frameHeight) / (target * fit)
        for _ in 0..<2 {   // a second pass absorbs the measurement's own rounding
            var ratios: [Double] = []
            for f in samples {
                let pose = layout.pose(frame: f)
                stage.pose(pose.set, heading: pose.heading)
                if let img = snapshot(size), let e = ClassicFootprint.extent(of: img) {
                    ratios.append((e / s) / ((classicExtents[f] ?? target) * fit))
                }
            }
            guard !ratios.isEmpty else { return }
            stage.orthographicScale *= ratios.reduce(0, +) / Double(ratios.count)
        }
    }

    /// An effect layer to render: the hull's classic overlay it replaces.
    public struct LayerTarget: Hashable, Sendable {
        public let layer: GraphicsEnhancement.EffectLayer
        public let frameWidth: Int
        public let frameHeight: Int
        public let frameCount: Int
        public init(layer: GraphicsEnhancement.EffectLayer, frameWidth: Int, frameHeight: Int, frameCount: Int) {
            self.layer = layer; self.frameWidth = frameWidth; self.frameHeight = frameHeight; self.frameCount = frameCount
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
        let separate = Set(overlays.map(\.layer)).intersection(stage.layersPresent)
        stage.setPass(.hull(baked: stage.layersPresent.subtracting(separate)))
        let s = HDAtlas.clampScale(scale, logicalWidth: layout.columns * layout.frameWidth,
                                   logicalHeight: layout.rows * layout.frameHeight)
        fit(stage: stage, layout: layout, classic: classic, scale: s)
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
    public static let version = 2

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
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".png")),
              let image = HDAtlas.decodePNG(data) else { return nil }
        return HDAtlas(image: image, frameWidth: layout.frameWidth, frameHeight: layout.frameHeight,
                       frameCount: layout.frameCount, columns: layout.columns, pixelScale: scale)
    }

    public func store(_ key: String, _ atlas: HDAtlas) {
        guard let data = atlas.pngData() else { return }
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
    public struct OverlayTarget: Sendable {
        public let spriteID: Int
        public let target: ModelBaker.LayerTarget
        public init(spriteID: Int, target: ModelBaker.LayerTarget) { self.spriteID = spriteID; self.target = target }
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
    public static func atlases(for e: ResolvedGraphicsEnhancement, classic: SpriteSheet, layout: BakeLayout,
                               overlays: [OverlayTarget], maxScale: Double,
                               cache: HDBakeCache?) throws -> [Int: HDAtlas] {
        switch e.descriptor.kind {
        case .sprite:
            guard let data = e.source.loadData() else { throw PipelineError.unreadable }
            return [e.spriteID: try HDAtlas.load(data, descriptor: e.descriptor, classic: classic, maxScale: maxScale)]
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
