// novaswift-hd — build, bake, compare and benchmark NovaSwift graphics packs
// (HD sprites and 3D models; see docs/HD_PIPELINE.md).
import Foundation
import NovaSwiftKit
import NovaSwiftHD
import SceneKit

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data("error: \(s)\n".utf8)); exit(1)
}

func usage() -> Never {
    print("""
    usage:
      novaswift-hd probe <Nova Files dir> <out dir>
          bake a test arrow model into the Shuttle's layout (orientation/fit check)
      novaswift-hd demo-pack <out plug-ins dir>
          generate the original demo models and planets as a plug-in + .nsx pack
      novaswift-hd preview <Nova Files dir> <plug-ins dir> <out dir> [--scale N]
          resolve every enhancement in the plug-ins, bake/load it, and write
          HD atlases, classic-vs-HD comparison sheets and a timing/memory report
    """)
    exit(2)
}

/// Export a scene as USDZ. Apple's exporter needs one material per geometry
/// element (it crashes on primitives that share one), so expand first.
func exportUSDZ(_ scene: SCNScene, to url: URL) -> Bool {
    scene.rootNode.enumerateHierarchy { node, _ in
        guard let g = node.geometry, g.elementCount > g.materials.count else { return }
        let m = g.firstMaterial ?? SCNMaterial()
        g.materials = (0..<g.elementCount).map { i in i < g.materials.count ? g.materials[i] : m }
    }
    return scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
}

func loadGame(_ dir: String) -> NovaGame {
    let files = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: dir))
    guard !files.isEmpty else { fail("no resource files under \(dir)") }
    do { return NovaGame(try GameLibrary.merge(baseFiles: files)) } catch { fail("\(error)") }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch command {
case "probe":
    guard args.count == 3 else { usage() }
    let game = loadGame(args[1])
    let out = URL(fileURLWithPath: args[2]); try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    guard let classic = game.shipSprite(128) else { fail("no Shuttle sprite") }
    // An arrow: nose +Z, red marker on the left (+X) wing, green on the right.
    let root = SCNNode()
    let cone = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.5, height: 2))
    cone.eulerAngles.x = .pi / 2
    root.addChildNode(cone)
    for (x, c) in [(Float(0.9), NSColor.red), (Float(-0.9), NSColor.green)] {
        let wing = SCNNode(geometry: SCNBox(width: 0.8, height: 0.15, length: 0.5, chamferRadius: 0))
        wing.geometry?.firstMaterial?.diffuse.contents = c
        wing.position = SCNVector3(x, 0, -0.6)
        root.addChildNode(wing)
    }
    let scene = SCNScene(); scene.rootNode.addChildNode(root)
    let usdz = out.appendingPathComponent("probe.usdz")
    guard exportUSDZ(scene, to: usdz) else { fail("USDZ export failed") }
    let model: SCNNode
    do { model = try ModelLoader.load(.file(usdz)) } catch { fail("\(error)") }
    guard let baker = ModelBaker() else { fail("no Metal device") }
    let layout = SpriteLayouts(game: game).layout(for: classic)
    print("layout: \(layout.frameCount) frames, \(layout.framesPerSet)/set, sets \(layout.sets)")
    var stats = ModelBaker.Stats()
    guard let atlas = baker.bake(model: model, settings: .init(), layout: layout, classic: classic, scale: 4, stats: &stats)
    else { fail("bake failed") }
    print("baked \(stats.frames) frames in \(Int(stats.seconds * 1000)) ms → \(atlas.image.width)×\(atlas.image.height)")
    try? atlas.pngData()?.write(to: out.appendingPathComponent("probe_atlas.png"))
    if let cmp = Preview.compare(classic: classic, hd: atlas, frames: [0, 9, 18, 27, 36 + 9, 72 + 9], displayScale: 4) {
        Preview.write(cmp, to: out.appendingPathComponent("probe_compare.png"))
    }

case "ships":
    guard args.count == 3 else { usage() }
    let game = loadGame(args[1])
    let out = URL(fileURLWithPath: args[2]); try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let kit = MaterialKit(textureDir: out.appendingPathComponent("textures"))
    let layouts = SpriteLayouts(game: game)
    guard let baker = ModelBaker() else { fail("no Metal device") }
    for demo in DemoContent.ships {
        guard let classic = game.shipSprite(demo.shipID) else { print("ship \(demo.shipID): no sprite"); continue }
        let scene = SCNScene(); scene.rootNode.addChildNode(demo.build(kit))
        let usdz = out.appendingPathComponent("\(demo.file).usdz")
        guard exportUSDZ(scene, to: usdz) else { fail("export \(demo.file) failed") }
        let model: SCNNode
        do { model = try ModelLoader.load(.file(usdz)) } catch { fail("\(error)") }
        let layout = layouts.layout(for: classic)
        var stats = ModelBaker.Stats()
        guard let atlas = baker.bake(model: model, settings: demo.bake, layout: layout, classic: classic,
                                     scale: 4, stats: &stats) else { fail("bake failed") }
        let size = (try? FileManager.default.attributesOfItem(atPath: usdz.path)[.size] as? Int) ?? 0
        print("\(demo.file): ship \(demo.shipID) sprite \(classic.sourceSpriteID ?? -1), \(layout.frameCount) frames → \(atlas.image.width)×\(atlas.image.height) in \(Int(stats.seconds * 1000)) ms, USDZ \(size / 1024) KB")
        let n = layout.framesPerSet
        var frames = [0, n / 8, n / 4, 3 * n / 8, n / 2, 3 * n / 4]
        if layout.sets.count > 2 { frames += [n + n / 4, 2 * n + n / 4] }
        if let cmp = Preview.compare(classic: classic, hd: atlas, frames: frames, displayScale: 4) {
            Preview.write(cmp, to: out.appendingPathComponent("\(demo.file)_compare.png"))
        }
    }

case "preview":
    // preview <Nova Files> <plug-ins dir> <out dir> [scale] — the app's own path:
    // discover packs, build the catalog, resolve every entry through
    // HDAssetPipeline with a bake cache, twice (cold, then warm).
    guard args.count >= 4 else { usage() }
    let game = loadGame(args[1])
    let pluginsDir = URL(fileURLWithPath: args[2])
    let out = URL(fileURLWithPath: args[3]); try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let scale = args.count > 4 ? Double(args[4]) ?? 2 : 2
    let plugins = GameLibrary.discoverPlugins(in: pluginsDir)
    let packs = GameLibrary.discoverGraphicsPacks(in: [pluginsDir])
    let catalog = GameLibrary.graphicsCatalog(resources: game.resources, plugins: plugins, graphicsPacks: packs)
    print("packs: \(packs.map(\.lastPathComponent)), \(catalog.bySprite.count) enhanced sprite(s)")
    // Where each upgraded graphic shows up in the galaxy (to know where to fly).
    for id in catalog.bySprite.keys.sorted() {
        let ships = game.ships().filter { game.shan($0.id)?.baseSpriteID == id }.map { "\($0.name) (\($0.id))" }
        let spobs = game.spobs().filter { game.spin($0.graphicSpinID)?.spriteID == id }
        let systems = game.systems()
        let where_ = spobs.prefix(6).map { sp in
            let sys = systems.first { $0.spobs.contains(sp.id) }
            return "\(sp.name) in \(sys?.name ?? "?")"
        }
        print("  sprite \(id): " + (ships.isEmpty ? "" : "ships " + ships.prefix(5).joined(separator: ", ") + " ")
              + (where_.isEmpty ? "" : "planets " + where_.joined(separator: "; ")))
    }
    for p in catalog.problems { print("  problem: \(p)") }
    let cache = HDBakeCache(directory: out.appendingPathComponent("bake-cache"))
    let layouts = SpriteLayouts(game: game)
    for pass in ["cold", "warm"] {
        var totalMS = 0, totalBytes = 0
        for e in catalog.bySprite.values.sorted(by: { $0.spriteID < $1.spriteID }) {
            guard let classic = game.spriteSheet(spriteID: e.spriteID, maskID: 0, frameWidth: 0, frameHeight: 0, frameCount: 0)
            else { print("  sprite \(e.spriteID): no classic sheet"); continue }
            let start = Date()
            // The hull's classic overlays, as targets for the model's effect layers.
            let overlays: [HDAssetPipeline.OverlayTarget] = layouts.overlays(forBase: e.spriteID).compactMap { layer, id in
                guard let sh = game.spriteSheet(spriteID: id, maskID: 0, frameWidth: 0, frameHeight: 0, frameCount: 0) else { return nil }
                return .init(spriteID: id, target: .init(layer: layer, frameWidth: sh.frameWidth,
                                                         frameHeight: sh.frameHeight, frameCount: sh.frameCount))
            }.sorted { $0.spriteID < $1.spriteID }
            if pass == "cold", !overlays.isEmpty {
                print("  sprite \(e.spriteID) classic overlays: " + overlays.map { "\($0.target.layer.rawValue)=\($0.spriteID) \($0.target.frameWidth)x\($0.target.frameHeight)" }.joined(separator: ", "))
            }
            do {
                let made = try HDAssetPipeline.atlases(for: e, classic: classic, layout: layouts.layout(for: classic),
                                                       overlays: overlays, maxScale: scale, cache: cache)
                guard let atlas = made[e.spriteID] else { continue }
                let layerAtlases = overlays.compactMap { made[$0.spriteID] }
                let layerNames = overlays.filter { made[$0.spriteID] != nil }.map(\.target.layer.rawValue)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let bytes = made.values.reduce(0) { $0 + $1.byteCount }
                totalMS += ms; totalBytes += bytes
                print(String(format: "  %@ sprite %5d %-6@ %3d frames  %4d×%-4d %.1fx  %6d KB  %5d ms  layers: %@",
                             pass, e.spriteID, e.descriptor.kind.rawValue, atlas.frameCount, atlas.image.width,
                             atlas.image.height, atlas.pixelScale, bytes / 1024, ms,
                             layerNames.isEmpty ? "-" : layerNames.joined(separator: ",")))
                if pass == "warm" {
                    let n = layouts.layout(for: classic).framesPerSet
                    let frames = atlas.frameCount > 1 ? [0, n / 8, n / 4, 3 * n / 8, n / 2, 5 * n / 8, 3 * n / 4, 7 * n / 8] : [0]
                    if let cmp = Preview.compareLayers(classic: classic, hd: atlas, layers: layerAtlases, frames: frames, displayScale: 3) {
                        Preview.write(cmp, to: out.appendingPathComponent("sprite_\(e.spriteID).png"))
                    }
                }
            } catch { print("  sprite \(e.spriteID): \(error)") }
        }
        print("  \(pass) total: \(totalMS) ms, texture memory \(totalBytes / 1024 / 1024) MB")
    }

case "refsheet":
    // refsheet <Nova Files> <ship id> <out.png> — four headings of the classic
    // hull (0°, 40°, 90°, 270°), hard-pixel enlarged on black: the visual
    // reference for a remaster.
    guard args.count == 4, let shipID = Int(args[2]) else { usage() }
    let game = loadGame(args[1])
    guard let sheet = game.shipSprite(shipID), let classicImage = Preview.classicCGImage(sheet) else { fail("no sprite for ship \(shipID)") }
    let n = SpriteLayouts(game: game).layout(for: sheet).framesPerSet
    let cell = 512
    guard let ctx = HDAtlas.makeContext(width: cell * 2, height: cell * 2) else { fail("context") }
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: cell * 2, height: cell * 2))
    ctx.interpolationQuality = .none
    for (i, f) in [0, n / 9, n / 4, 3 * n / 4].enumerated() {
        let crop = classicImage.cropping(to: CGRect(x: (f % 6) * sheet.frameWidth, y: (f / 6) * sheet.frameHeight,
                                                    width: sheet.frameWidth, height: sheet.frameHeight))
        if let crop { ctx.draw(crop, in: CGRect(x: (i % 2) * cell, y: (1 - i / 2) * cell, width: cell, height: cell)) }
    }
    try? HDAtlas.encodePNG(ctx.makeImage()!)?.write(to: URL(fileURLWithPath: args[3]))
    print("ship \(shipID): sprite \(sheet.sourceSpriteID ?? -1) \(sheet.frameWidth)x\(sheet.frameHeight), \(n)/set")

case "orient":
    // orient <Nova Files> <model.usdz> <ship id> — the yaw (0/90/180/270) whose
    // silhouettes best match the classic frames (mask overlap), for models
    // whose nose doesn't face +Z.
    guard args.count == 4, let shipID = Int(args[3]) else { usage() }
    let game = loadGame(args[1])
    guard let classic = game.shipSprite(shipID) else { fail("no sprite for ship \(shipID)") }
    guard let baker = ModelBaker() else { fail("no Metal device") }
    let full = SpriteLayouts(game: game).layout(for: classic)
    let n = full.framesPerSet
    let probe = [0, n / 8, n / 4, 3 * n / 8]
    // Opaque mask of one frame, at the classic resolution.
    // Per-pixel (opaque, r, g, b) of one frame at the classic resolution.
    func pixels(_ img: CGImage?, w: Int, h: Int) -> [(Bool, Double, Double, Double)] {
        guard let img, let ctx = HDAtlas.makeContext(width: w, height: h), let d = ctx.data else { return [] }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = d.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        return (0..<(w * h)).map { i in
            let o = (i / w) * ctx.bytesPerRow + (i % w) * 4
            let a = Double(p[o + 3])
            guard a > 60 else { return (false, 0, 0, 0) }
            // Un-premultiply, then normalise brightness so only hue/placement counts.
            let r = Double(p[o]) / a, g = Double(p[o + 1]) / a, b = Double(p[o + 2]) / a
            let m = max(0.05, (r + g + b) / 3)
            return (true, r / m, g / m, b / m)
        }
    }
    let classicCG = Preview.classicCGImage(classic)
    var best = (yaw: 0.0, score: -1.0)
    for yaw in [0.0, 90, 180, 270] {
        let model: SCNNode
        do { model = try ModelLoader.load(.file(URL(fileURLWithPath: args[2]))) } catch { fail("\(error)") }
        var stats = ModelBaker.Stats()
        guard let atlas = baker.bake(model: model, settings: .init(yaw: yaw), layout: full, classic: classic, scale: 1, stats: &stats)
        else { continue }
        var inter = 0, union = 0, colourDiff = 0.0
        for f in probe {
            let c = pixels(classicCG?.cropping(to: CGRect(x: (f % 6) * classic.frameWidth, y: (f / 6) * classic.frameHeight,
                                                          width: classic.frameWidth, height: classic.frameHeight)),
                           w: classic.frameWidth, h: classic.frameHeight)
            let m = pixels(atlas.frameImage(f), w: classic.frameWidth, h: classic.frameHeight)
            for i in 0..<min(c.count, m.count) {
                if c[i].0 && m[i].0 {
                    inter += 1
                    colourDiff += (abs(c[i].1 - m[i].1) + abs(c[i].2 - m[i].2) + abs(c[i].3 - m[i].3)) / 3
                }
                if c[i].0 || m[i].0 { union += 1 }
            }
        }
        let overlap = union > 0 ? Double(inter) / Double(union) : 0
        let colour = inter > 0 ? max(0, 1 - colourDiff / Double(inter)) : 0
        let score = overlap * (0.5 + 0.5 * colour)
        print(String(format: "  yaw %3.0f: overlap %.3f colour %.3f → %.3f", yaw, overlap, colour, score))
        if score > best.score { best = (yaw, score) }
    }
    print("best yaw \(Int(best.yaw))")

case "planet":
    // planet <surface map.png (equirectangular)> <out.usdz> — a textured sphere.
    guard args.count == 3 else { usage() }
    // A UV sphere as a plain triangle list: the USDZ exporter mangles
    // SCNSphere's strip-based element (most triangles are lost).
    let rings = 96, segs = 192
    var pos: [SCNVector3] = [], uv: [CGPoint] = [], idx: [UInt32] = []
    for r in 0...rings {
        let v = Double(r) / Double(rings), phi = v * .pi
        for s in 0...segs {
            let u = Double(s) / Double(segs), th = u * 2 * .pi
            pos.append(SCNVector3(-sin(phi) * sin(th), cos(phi), -sin(phi) * cos(th)))
            uv.append(CGPoint(x: u, y: v))
        }
    }
    for r in 0..<rings {
        for s in 0..<segs {
            let a = UInt32(r * (segs + 1) + s), b = a + 1, c = a + UInt32(segs + 1), d = c + 1
            idx += [a, c, b, b, c, d]
        }
    }
    let sphere = SCNGeometry(sources: [SCNGeometrySource(vertices: pos), SCNGeometrySource(normals: pos),
                                       SCNGeometrySource(textureCoordinates: uv)],
                             elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
    let m = SCNMaterial()
    m.lightingModel = .physicallyBased
    m.diffuse.contents = URL(fileURLWithPath: args[1])
    m.metalness.contents = NSNumber(value: 0)
    m.roughness.contents = NSNumber(value: 0.85)
    sphere.materials = [m]
    let scene = SCNScene(); scene.rootNode.addChildNode(SCNNode(geometry: sphere))
    guard exportUSDZ(scene, to: URL(fileURLWithPath: args[2])) else { fail("export failed") }
    print("wrote \(args[2])")

case "model":
    // model <Nova Files> <model.usdz> <ship id | s<sprite id>> <out dir> [yaw°] [pitch°] [r,g,b atmosphere]
    guard args.count >= 5 else { usage() }
    let game = loadGame(args[1])
    let target = args[3]
    let classicSheet: SpriteSheet? = target.hasPrefix("s")
        ? Int(target.dropFirst()).flatMap { game.spriteSheet(spriteID: $0, maskID: 0, frameWidth: 0, frameHeight: 0, frameCount: 0) }
        : Int(target).flatMap { game.shipSprite($0) }
    guard let classic = classicSheet else { fail("no sprite for \(target)") }
    let out = URL(fileURLWithPath: args[4]); try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var settings = GraphicsEnhancement.BakeSettings()
    if args.count > 5 { settings.yaw = Double(args[5]) }
    if args.count > 6 { settings.pitch = Double(args[6]) }
    if args.count > 7 { settings.atmosphere = args[7].split(separator: ",").compactMap { Double($0) } }
    let src = URL(fileURLWithPath: args[2])
    let model: SCNNode
    do { model = try ModelLoader.load(.file(src)) } catch { fail("\(error)") }
    guard let baker = ModelBaker() else { fail("no Metal device") }
    let layout = SpriteLayouts(game: game).layout(for: classic)
    var stats = ModelBaker.Stats()
    guard let atlas = baker.bake(model: model, settings: settings, layout: layout, classic: classic, scale: 4, stats: &stats)
    else { fail("bake failed") }
    let name = src.deletingPathExtension().lastPathComponent
    print("\(name): \(layout.frameCount) frames → \(atlas.image.width)×\(atlas.image.height) in \(Int(stats.seconds * 1000)) ms")
    try? atlas.pngData()?.write(to: out.appendingPathComponent("\(name)_atlas.png"))
    let n = layout.framesPerSet
    var frames = [0, n / 8, n / 4, 3 * n / 8, n / 2, 3 * n / 4]
    if layout.sets.count > 2 { frames += [n + n / 4, 2 * n + n / 4] }
    if let cmp = Preview.compare(classic: classic, hd: atlas, frames: frames, displayScale: 4) {
        Preview.write(cmp, to: out.appendingPathComponent("\(name)_compare.png"))
    }

default:
    usage()
}
