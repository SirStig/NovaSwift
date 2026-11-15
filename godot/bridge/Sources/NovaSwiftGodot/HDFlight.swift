import Foundation
import NovaSwiftKit

#if canImport(NovaSwiftHD) && os(macOS)
import NovaSwiftHD
import SceneKit
import simd
import ImageIO
import UniformTypeIdentifiers
#endif

/// Godot-side HD sprites and live hulls. The catalog is the same one the Apple
/// app builds (`GameLibrary.graphicsCatalog`): `NSgx` resources in the merged
/// plug-in data, plus `.nsx` sidecar packs.
///
/// Live hulls come two ways:
/// - **SceneKit formats (USDZ and the rest), macOS.** The bridge links
///   NovaSwiftHD there and prepares the model exactly as the Apple app does
///   (`HDGraphics.loadLiveModelNow`): `ModelLoader.load`, the fit and light
///   level from `HDAssetPipeline.liveCalibration`, `MeshSimplifier` and
///   `LiveModelCache.capTextures` for the model-detail setting, then hands
///   Godot the posed geometry with its materials, textures, effect-layer tags
///   and emitters (`LiveModelStore`).
/// - **glTF**, every platform. Godot loads it itself; the bridge only
///   describes it.
///
/// NovaSwiftHD needs SceneKit, so the Linux bridge does not link it: a USDZ
/// hull there stays on its sprite.
enum HDFlight {
    /// PNG atlas bytes, or nil when this enhancement is not a PNG sprite sheet.
    static func pngBytes(_ source: GraphicsAssetSource) -> [UInt8]? {
        guard let data = source.loadData(), isPNG(data) else { return nil }
        return [UInt8](data)
    }

    static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }

    static let gltfExtensions: Set<String> = ["glb", "gltf"]
    static let sceneKitExtensions: Set<String> = ["usdz", "usd", "usda", "usdc", "scn", "dae", "obj"]

    /// A glTF file Godot can open (blobs are written to the cache first).
    static func gltfFile(_ source: GraphicsAssetSource, spriteID: Int) -> (ext: String, url: URL)? {
        guard let ext = source.fileExtension, gltfExtensions.contains(ext) else { return nil }
        switch source {
        case .file(let url):
            return (ext, url)
        case .blob(let data):
            guard let url = writeBlob(data, key: source.contentKey(), spriteID: spriteID, ext: ext) else { return nil }
            return (ext, url)
        }
    }

    static func isSceneKitModel(_ source: GraphicsAssetSource) -> Bool {
        guard let ext = source.fileExtension else { return false }
        return sceneKitExtensions.contains(ext)
    }

    /// Settings every live description shares. `banks`: the hull's shän sets
    /// bank with turns (Apple `liveBank`). `framesPerSet`: the classic sheet's
    /// headings per set. `overlayLayers`: effect layers the hull has a classic
    /// overlay sprite for (`SpriteLayouts.overlays(forBase:)`).
    static func baseDescription(_ e: ResolvedGraphicsEnhancement, banks: Bool, framesPerSet: Int,
                                overlayLayers: [String]) -> [String: Any] {
        let d = e.descriptor
        let bake = d.bake
        var obj: [String: Any] = [
            "hides": d.hidesClassicOverlays,
            "yaw": bake?.yaw ?? 0,
            "tilt": bake?.tilt ?? 0,
            "fit": bake?.fit ?? 1,
            "rotate": bake?.rotate ?? [],
            "orientation": bake?.orientation ?? [],
            "pitch": bake?.pitch ?? 38,
            "bankRoll": bake?.bankRoll ?? 30,
            "exposure": bake?.exposure ?? 1,
            "atmosphere": bake?.atmosphere != nil,
            "banks": banks,
            "framesPerSet": framesPerSet,
            "overlayLayers": overlayLayers,
        ]
        if let l = bake?.light, l.count == 3 { obj["light"] = l }
        var names: [String: [String]] = [:]
        for layer in GraphicsEnhancement.EffectLayer.allCases { names[layer.rawValue] = d.nameMatches(layer) }
        obj["layerNames"] = names
        obj["effects"] = (d.effects ?? []).filter { $0.at.count == 3 }.map { fx -> [String: Any] in
            var o: [String: Any] = ["layer": fx.layer.rawValue, "at": fx.at, "radius": fx.radius ?? 0.06]
            o["color"] = fx.color.flatMap { $0.count == 3 ? $0 : nil } ?? [0.55, 0.78, 1.0]
            return o
        }
        return obj
    }

    static func json(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// Named by the blob's content key (`GraphicsAssetSource.contentKey`, as `ModelLoader` names its
    /// own blob files), kept to filename-safe characters; `ext` is already one of `gltfExtensions`.
    private static func writeBlob(_ data: Data, key: String?, spriteID: Int, ext: String) -> URL? {
        let dir = cacheDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fallback = "sprite-\(spriteID)-\(data.count)-" + data.prefix(8).map { String(format: "%02x", $0) }.joined()
        let safe = String((key ?? fallback).unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }.map(Character.init).prefix(120))
        let url = dir.appendingPathComponent("\(safe.isEmpty ? fallback : safe).\(ext)")
        if !FileManager.default.fileExists(atPath: url.path) {
            do { try data.write(to: url, options: .atomic) } catch { return nil }
        }
        return url
    }

    private static func cacheDirectory() -> URL {
        let caches = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("NovaSwift/GodotHD", isDirectory: true)
    }
}

/// Apple's `GameSettings.ModelDetail`: grid cubes for `MeshSimplifier` (nil =
/// untouched) and the longest side textures are kept at. Godot menu index
/// 0 Full, 1 High, 2 Medium, 3 Low.
struct LiveModelDetail: Hashable {
    let cells: Int?
    let texturePixels: Int
    init(index: Int) {
        switch index {
        case 1: cells = 96; texturePixels = 1024
        case 2: cells = 56; texturePixels = 512
        case 3: cells = 32; texturePixels = 512
        default: cells = nil; texturePixels = 1024
        }
    }
}

#if canImport(NovaSwiftHD) && os(macOS)
/// SceneKit-format live hulls, prepared off the main thread as the Apple app
/// does and cached (in memory here, on disk by NovaSwiftHD's own caches).
final class LiveModelStore: @unchecked Sendable {
    struct Ready {
        let json: [String: Any]
        let mesh: [UInt8]
    }
    enum State { case ready(Ready), pending, unavailable }

    private let lock = NSLock()
    private var ready: [String: Ready] = [:]
    private var loading: Set<String> = []
    private var failed: Set<String> = []
    private var generation = 0
    private let bakeCache = HDBakeCache()
    private let modelCache = LiveModelCache()

    /// Forget everything (new data set, or a catalog rebuild).
    func reset() {
        lock.lock(); generation += 1; ready = [:]; loading = []; failed = []; lock.unlock()
    }

    func state(_ e: ResolvedGraphicsEnhancement, classic: SpriteSheet, layout: BakeLayout,
               detail: LiveModelDetail, simple: Bool, base: [String: Any]) -> State {
        let key = "\(e.spriteID)|\(detail.cells ?? 0)|\(detail.texturePixels)|\(simple)"
        lock.lock()
        if let r = ready[key] { lock.unlock(); return .ready(r) }
        if failed.contains(key) { lock.unlock(); return .unavailable }
        if !loading.contains(key) {
            loading.insert(key)
            let gen = generation
            lock.unlock()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let made = Self.prepare(e, classic: classic, layout: layout, detail: detail, simple: simple,
                                        base: base, bakeCache: bakeCache, modelCache: modelCache)
                lock.lock(); defer { lock.unlock() }
                loading.remove(key)
                guard gen == generation else { return }
                if let made { ready[key] = made } else { failed.insert(key) }
            }
            return .pending
        }
        lock.unlock()
        return .pending
    }

    /// `HDGraphics.loadLiveModelNow`, then the export.
    private static func prepare(_ e: ResolvedGraphicsEnhancement, classic: SpriteSheet, layout: BakeLayout,
                                detail: LiveModelDetail, simple: Bool, base: [String: Any],
                                bakeCache: HDBakeCache?, modelCache: LiveModelCache?) -> Ready? {
        do {
            let calibration: LiveHullCalibration
            let node: SCNNode
            let key = modelKey(e, detail: detail)
            if let key, let cached = modelCache?.load(key) {
                calibration = try HDAssetPipeline.liveCalibration(for: e, classic: classic, layout: layout, cache: bakeCache)
                node = cached
            } else {
                let loaded = try ModelLoader.load(e.source)
                // Measured on the full model, before any simplifying.
                calibration = try HDAssetPipeline.liveCalibration(for: e, classic: classic, layout: layout,
                                                                  model: loaded, cache: bakeCache)
                if let cells = detail.cells { MeshSimplifier.simplify(loaded, cells: cells) }
                LiveModelCache.capTextures(loaded, maxPixels: detail.texturePixels)
                if let key { modelCache?.store(loaded, key: key) }
                node = loaded
            }
            guard let dump = LiveModelExport.dump(node, descriptor: e.descriptor, simple: simple) else { return nil }
            var json = base
            json["ext"] = "nvm"
            json["space"] = "roll"
            json["ortho"] = calibration.orthographicScale
            json["lightScale"] = calibration.lightScale
            json["layersPresent"] = dump.layers
            json["simple"] = simple
            NovaSwiftKit.Log.graphics.info("Godot HD: live model \(e.spriteID, privacy: .public) ready")
            return Ready(json: json, mesh: dump.bytes)
        } catch {
            NovaSwiftKit.Log.graphics.error("Godot HD: live model \(e.spriteID, privacy: .public) unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// `HDGraphics.liveModelKey`: the same disk cache entry the Apple app uses.
    private static func modelKey(_ e: ResolvedGraphicsEnhancement, detail: LiveModelDetail) -> String? {
        guard let content = e.source.contentKey() else { return nil }
        let layout = BakeLayout(frameWidth: 1, frameHeight: 1, frameCount: 1, framesPerSet: 1, sets: [.level])
        return HDBakeCache.key(contentKey: content, descriptor: e.descriptor, layout: layout, scale: 1,
                               part: "live-model-v\(LiveModelCache.version)-\(detail.cells ?? 0)-\(detail.texturePixels)")
    }
}

/// A prepared model, posed in a `ModelStage` (normalised, `upright`, `yawed`),
/// written in the stage's roll space for Godot to build meshes from.
///
/// Layout (little-endian): `NVM2`, texture count, geometry count; each
/// texture as byte count + PNG; each geometry as vertex count, flags (1
/// normals, 2 uvs), positions, normals, uvs (float), element count, and per
/// element: effect layer (0 none, 1 engine, 2 lights, 3 weapons), a material
/// block (see `putMaterial`), index count, `UInt32` indices.
enum LiveModelExport {
    static let magic: UInt32 = 0x4E564D32
    private static let layers: [GraphicsEnhancement.EffectLayer] = [.engine, .lights, .weapons]

    static func dump(_ model: SCNNode, descriptor: GraphicsEnhancement, simple: Bool) -> (bytes: [UInt8], layers: [String])? {
        let stage = ModelStage(model: ModelLoader.instance(of: model), settings: descriptor.bake ?? .init())
        var textures: [Data] = []
        var textureIndex: [ObjectIdentifier: Int32] = [:]
        var urlIndex: [URL: Int32] = [:]
        var geos = Data()
        var geoCount: UInt32 = 0
        var present: Set<String> = []
        for fx in descriptor.effects ?? [] where fx.at.count == 3 { present.insert(fx.layer.rawValue) }

        func texture(_ p: SCNMaterialProperty) -> Int32 {
            let c = p.contents
            if let url = c as? URL ?? (c as? String).map({ URL(fileURLWithPath: $0) }) {
                if let i = urlIndex[url] { return i }
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil), let png = pngData(img) else { return -1 }
                textures.append(png); let i = Int32(textures.count - 1); urlIndex[url] = i
                return i
            }
            var image: CGImage?
            if let any = c as AnyObject?, CFGetTypeID(any) == CGImage.typeID { image = (any as! CGImage) }
            if image == nil, let ns = c as? NSImage { image = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) }
            guard let img = image, let obj = c as AnyObject? else { return -1 }
            if let i = textureIndex[ObjectIdentifier(obj)] { return i }
            guard let png = pngData(img) else { return -1 }
            textures.append(png); let i = Int32(textures.count - 1); textureIndex[ObjectIdentifier(obj)] = i
            return i
        }

        stage.roll.enumerateHierarchy { node, _ in
            guard let g = node.geometry, let vsrc = g.sources(for: .vertex).first else { return }
            let pos = readVectors(vsrc, components: 3)
            guard !pos.isEmpty else { return }
            let nrm = g.sources(for: .normal).first.map { readVectors($0, components: 3) } ?? []
            let uv = g.sources(for: .texcoord).first.map { readVectors($0, components: 2) } ?? []
            let hasN = nrm.count == pos.count, hasUV = uv.count == pos.count
            let m = node.simdConvertTransform(matrix_identity_float4x4, to: stage.roll)
            let nm = simd_inverse(simd_transpose(m))
            let layer = classify(node, stop: stage.roll, descriptor: descriptor)
            if let layer { present.insert(layer.rawValue) }

            var block = Data()
            put(&block, UInt32(pos.count))
            put(&block, UInt32((hasN ? 1 : 0) | (hasUV ? 2 : 0)))
            for p in pos {
                let w = m * SIMD4<Float>(p[0], p[1], p[2], 1)
                put(&block, w.x); put(&block, w.y); put(&block, w.z)
            }
            if hasN {
                for n in nrm {
                    let t = nm * SIMD4<Float>(n[0], n[1], n[2], 0)
                    let v = SIMD3(t.x, t.y, t.z)
                    let len = simd_length(v)
                    let u = len > 1e-6 ? v / len : SIMD3<Float>(0, 1, 0)
                    put(&block, u.x); put(&block, u.y); put(&block, u.z)
                }
            }
            if hasUV { for t in uv { put(&block, t[0]); put(&block, t[1]) } }
            var elements = Data()
            var elementCount: UInt32 = 0
            for (i, el) in g.elements.enumerated() {
                let idx = triangles(el, vertexCount: UInt32(pos.count))
                guard !idx.isEmpty else { continue }
                let mat = g.materials.isEmpty ? SCNMaterial() : g.materials[i % g.materials.count]
                put(&elements, UInt32(layer.flatMap { layers.firstIndex(of: $0).map { $0 + 1 } } ?? 0))
                putMaterial(&elements, mat, simple: simple, texture: texture)
                put(&elements, UInt32(idx.count))
                for v in idx { put(&elements, v) }
                elementCount += 1
            }
            guard elementCount > 0 else { return }
            put(&block, elementCount)
            block.append(elements)
            geos.append(block)
            geoCount += 1
        }
        guard geoCount > 0 else { return nil }
        var out = Data()
        put(&out, magic)
        put(&out, UInt32(textures.count))
        put(&out, geoCount)
        for t in textures { put(&out, UInt32(t.count)); out.append(t) }
        out.append(geos)
        return ([UInt8](out), present.sorted())
    }

    /// The self-check model (see `NovaWorld.liveModelProbeWrite`), the same arrow `novaswift-hd probe` uses.
    static func writeProbe(to url: URL) -> Bool {
        let root = SCNNode()
        let cone = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.5, height: 2))
        cone.eulerAngles.x = .pi / 2
        cone.name = "hull"
        root.addChildNode(cone)
        for (x, c, name) in [(Float(0.9), NSColor.red, "engine_pod"), (Float(-0.9), NSColor.green, "wing")] {
            let wing = SCNNode(geometry: SCNBox(width: 0.8, height: 0.15, length: 0.5, chamferRadius: 0))
            let m = SCNMaterial()
            m.diffuse.contents = c
            m.metalness.contents = NSNumber(value: 0.25)
            m.roughness.contents = NSNumber(value: 0.6)
            m.lightingModel = .physicallyBased
            wing.geometry?.materials = [m]
            wing.position = SCNVector3(x, 0, -0.6)
            wing.name = name
            root.addChildNode(wing)
        }
        let scene = SCNScene()
        scene.rootNode.addChildNode(root)
        // SceneKit's USD writer throws when a geometry has more elements than materials (a cone
        // has its side and base): pad them, as novaswift-hd's exportUSDZ does.
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let g = node.geometry, g.elementCount > g.materials.count else { return }
            let m = g.firstMaterial ?? SCNMaterial()
            g.materials = (0..<g.elementCount).map { i in i < g.materials.count ? g.materials[i] : m }
        }
        return scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
    }

    /// `ModelStage.prepareEffects`' classify: material and node names up to the roll node.
    private static func classify(_ node: SCNNode, stop: SCNNode, descriptor: GraphicsEnhancement) -> GraphicsEnhancement.EffectLayer? {
        var names: [String] = node.geometry?.materials.compactMap(\.name) ?? []
        var n: SCNNode? = node
        while let cur = n, cur !== stop { if let nm = cur.name { names.append(nm) }; n = cur.parent }
        let lower = names.map { $0.lowercased() }
        for layer in GraphicsEnhancement.EffectLayer.allCases {
            let keys = descriptor.nameMatches(layer)
            if lower.contains(where: { name in keys.contains { name.contains($0) } }) { return layer }
        }
        return nil
    }

    /// Material block: diffuse rgba, diffuse tex, metalness, metal tex,
    /// roughness, rough tex, emission rgb, emission tex, normal tex, lighting
    /// (0 physically based, 1 blinn/phong, 2 lambert, 3 constant), double sided,
    /// opacity (`SCNMaterial.transparency`).
    private static func putMaterial(_ out: inout Data, _ m: SCNMaterial, simple: Bool,
                                    texture: (SCNMaterialProperty) -> Int32) {
        let diffuse = color(m.diffuse) ?? SIMD4<Float>(1, 1, 1, 1)
        put(&out, diffuse.x); put(&out, diffuse.y); put(&out, diffuse.z); put(&out, diffuse.w)
        put(&out, texture(m.diffuse))
        put(&out, scalar(m.metalness) ?? 0); put(&out, texture(m.metalness))
        put(&out, scalar(m.roughness) ?? 0.5); put(&out, texture(m.roughness))
        let e = color(m.emission) ?? SIMD4<Float>(0, 0, 0, 1)
        put(&out, e.x); put(&out, e.y); put(&out, e.z); put(&out, texture(m.emission))
        put(&out, texture(m.normal))
        var model: UInt32 = 0
        switch m.lightingModel {
        case .blinn, .phong: model = 1
        case .lambert: model = 2
        case .constant, .shadowOnly: model = 3
        default: model = 0
        }
        // HDGraphics simpleLighting: every lit material becomes Lambert.
        if simple, model != 3 { model = 2 }
        put(&out, model)
        put(&out, UInt32(m.isDoubleSided ? 1 : 0))
        put(&out, Float(m.transparency))
    }

    private static func color(_ p: SCNMaterialProperty) -> SIMD4<Float>? {
        let k = Float(p.intensity)
        if let c = p.contents as? NSColor, let s = c.usingColorSpace(.sRGB) {
            return SIMD4(Float(s.redComponent) * k, Float(s.greenComponent) * k, Float(s.blueComponent) * k, Float(s.alphaComponent))
        }
        if let any = p.contents as AnyObject?, CFGetTypeID(any) == CGColor.typeID {
            let cg = any as! CGColor
            if let s = cg.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
               let c = s.components, c.count >= 3 {
                return SIMD4(Float(c[0]) * k, Float(c[1]) * k, Float(c[2]) * k, c.count > 3 ? Float(c[3]) : 1)
            }
        }
        if let n = p.contents as? NSNumber { let v = n.floatValue * k; return SIMD4(v, v, v, 1) }
        // An image: SceneKit multiplies it by white; the intensity still scales it.
        if p.contents != nil { return SIMD4(k, k, k, 1) }
        return nil
    }

    private static func scalar(_ p: SCNMaterialProperty) -> Float? {
        if let n = p.contents as? NSNumber { return n.floatValue * Float(p.intensity) }
        if let c = color(p) { return c.x }
        return nil
    }

    private static func pngData(_ img: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Float or double vectors (SceneKit uses both), never assuming alignment.
    private static func readVectors(_ src: SCNGeometrySource, components want: Int) -> [[Float]] {
        let count = src.vectorCount
        let bpc = src.bytesPerComponent
        guard count > 0, src.usesFloatComponents, bpc == 4 || bpc == 8,
              src.componentsPerVector >= min(want, 2) else { return [] }
        let stride = src.dataStride, offset = src.dataOffset, comps = src.componentsPerVector
        let need = (count - 1) * stride + offset + min(comps, want) * bpc
        var out: [[Float]] = []
        out.reserveCapacity(count)
        src.data.withUnsafeBytes { raw in
            guard raw.count >= need else { return }
            for i in 0..<count {
                let at = i * stride + offset
                var v = [Float](repeating: 0, count: want)
                for c in 0..<min(comps, want) {
                    v[c] = bpc == 8 ? Float(raw.loadUnaligned(fromByteOffset: at + c * 8, as: Double.self))
                                    : raw.loadUnaligned(fromByteOffset: at + c * 4, as: Float.self)
                }
                out.append(v)
            }
        }
        return out
    }

    /// Whole triangles only: a bad index drops its triangle, never shifts the rest.
    private static func triangles(_ element: SCNGeometryElement, vertexCount count: UInt32) -> [UInt32] {
        guard element.primitiveType == .triangles else { return [] }
        let bpi = element.bytesPerIndex
        guard bpi == 1 || bpi == 2 || bpi == 4 else { return [] }
        let n = element.primitiveCount * 3
        var out: [UInt32] = []
        out.reserveCapacity(n)
        element.data.withUnsafeBytes { raw in
            guard raw.count >= n * bpi else { return }
            func index(_ i: Int) -> UInt32 {
                let off = i * bpi
                switch bpi {
                case 1: return UInt32(raw.load(fromByteOffset: off, as: UInt8.self))
                case 2: return UInt32(raw.loadUnaligned(fromByteOffset: off, as: UInt16.self))
                default: return raw.loadUnaligned(fromByteOffset: off, as: UInt32.self)
                }
            }
            for t in 0..<(n / 3) {
                let a = index(t * 3), b = index(t * 3 + 1), c = index(t * 3 + 2)
                guard a < count, b < count, c < count else { continue }
                out.append(a); out.append(b); out.append(c)
            }
        }
        return out
    }

    private static func put(_ out: inout Data, _ v: UInt32) {
        var x = v.littleEndian
        withUnsafeBytes(of: &x) { out.append(contentsOf: $0) }
    }
    private static func put(_ out: inout Data, _ v: Int32) { put(&out, UInt32(bitPattern: v)) }
    private static func put(_ out: inout Data, _ v: Float) { put(&out, v.bitPattern) }
}
#endif
