import Foundation
import Crypto

// MARK: - NovaSwift graphics extensions (HD sprites and 3D models)
//
// An optional layer that upgrades how a plug-in's (or the base game's) art
// looks, without changing a single gameplay byte. Spec: docs/HD_PIPELINE.md.
//
// Every enhancement is keyed to a **sprite id**: the id the original sprite
// loader resolves (`Sprite_CreateFromSpriteSheetResources` 0x00474ab0) — the
// `rlëD` with that id, or the PICT sprite sheet of that id. Wherever the game
// draws that sprite (a hull, a planet, an asteroid, a shot, an explosion),
// the enhancement draws instead. Collision keeps using the classic masks.
//
// Two ways to ship one:
//
// 1. In the plug-in file itself, as two resource types the original game
//    never asks for (it only ever looks up the types it knows, so the file
//    still loads unchanged in EV Nova):
//    - `NSgx` #<sprite id>: a UTF-8 JSON `GraphicsEnhancement`.
//    - `NSbl` #<any id>:    raw bytes (PNG atlas, USDZ model) a descriptor
//                           points at with `"blob": <id>`.
//    Being ordinary resources, they follow the plug-in override chain.
// 2. A sidecar folder `<name>.nsx/` with a `manifest.json` (a
//    `GraphicsPackManifest`) and its asset files — for content too big for a
//    resource file. The original game never descends into folders. A sidecar
//    sitting next to a plug-in (inside the plug-in's folder, or beside a loose
//    `<name>.rez`) belongs to that plug-in and follows its enable switch; one
//    on its own is a standalone HD pack.

public enum GraphicsEnhancementType {
    /// A graphics enhancement descriptor; id = the sprite id it upgrades.
    public static let descriptor = FourCharCode("NSgx")!
    /// A binary asset (PNG, USDZ) referenced by a descriptor's `blob`.
    public static let blob = FourCharCode("NSbl")!
}

/// One upgraded sprite: what replaces it and how.
public struct GraphicsEnhancement: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A high-resolution PNG atlas in the classic sheet's frame layout.
        case sprite
        /// A 3D model (USDZ), rendered into the classic frame layout (and,
        /// where the presentation allows, drawn live in 3D).
        case model
    }

    /// Whether the classic overlay layers of a hull (engine glow, running
    /// lights, weapon glow, alternating sprites) still draw on top. Classic
    /// overlays are pixel-matched to the classic art, so a model hides them
    /// by default; a hand-painted HD sheet authored to match keeps them.
    public enum Overlays: String, Codable, Sendable { case keep, hide }

    public var kind: Kind
    /// The sprite id (manifest entries only; in a plug-in file the `NSgx`
    /// resource id is the sprite id).
    public var sprite: Int?
    /// Sidecar asset path, relative to the `.nsx` folder.
    public var file: String?
    /// `NSbl` id holding the asset bytes (in-file form).
    public var blob: Int?
    /// Sprite atlases: pixels per classic pixel (2 = twice the size). Default 2.
    public var scale: Double?
    /// Sprite atlases: frames per row. Default 6, like every classic sheet.
    public var columns: Int?
    /// Optional check: the number of frames the atlas holds. Must match the
    /// classic sheet — the game picks frames by the classic layout.
    public var frameCount: Int?
    public var overlays: Overlays?
    /// Model rendering setup (model kind only).
    public var bake: BakeSettings?
    /// Model kind: allow drawing it live in 3D (smooth rotation, real
    /// lighting) instead of as baked frames. Default true.
    public var live: Bool?
    /// Model kind: which parts of the model glow in which effect layer, as
    /// substrings of node or material names (case-insensitive). Default:
    /// `engine` → engine glow, `light` → running lights, `weapon`/`muzzle` →
    /// weapon glow.
    public var layers: [String: [String]]?
    /// Model kind: glowing emitters placed on the model — for models that
    /// have no separate glowing parts (e.g. a single scanned/generated mesh).
    public var effects: [Effect]?
    /// Hulls: a shield bubble in this colour `[r, g, b]` (0…1), fitted to the
    /// ship's outline in every heading and flashed on hits. Only used when the
    /// hull has no classic shield layer of its own. Omit for no shield.
    public var shield: [Double]?

    public init(kind: Kind, sprite: Int? = nil, file: String? = nil, blob: Int? = nil,
                scale: Double? = nil, columns: Int? = nil, frameCount: Int? = nil,
                overlays: Overlays? = nil, bake: BakeSettings? = nil, live: Bool? = nil,
                layers: [String: [String]]? = nil, effects: [Effect]? = nil) {
        self.kind = kind; self.sprite = sprite; self.file = file; self.blob = blob
        self.scale = scale; self.columns = columns; self.frameCount = frameCount
        self.overlays = overlays; self.bake = bake; self.live = live
        self.layers = layers; self.effects = effects
    }

    /// The hull effect layers a model can supply. Each is rendered into the
    /// hull's own classic overlay sprite (shän engine / light / weapon-glow
    /// layer), so the game drives it exactly as before: engine glow while
    /// thrusting, the shän blink pattern, the weapon flare and its decay.
    public enum EffectLayer: String, Codable, Sendable, CaseIterable {
        case engine, lights, weapons

        /// Default name substrings that put a model part in this layer.
        public var defaultNameMatches: [String] {
            switch self {
            case .engine: return ["engine", "thruster", "exhaust"]
            case .lights: return ["light", "beacon", "nav_"]
            case .weapons: return ["weapon", "muzzle"]
            }
        }
    }

    /// A soft glowing emitter at a point on the model. Coordinates are in
    /// the model's fitted space: centred, nose toward +Z, Y up, the model's
    /// widest horizontal extent spanning −1…1 (after `bake.yaw`).
    public struct Effect: Codable, Hashable, Sendable {
        public var layer: EffectLayer
        public var at: [Double]
        /// Glow radius, same units as `at` (default 0.06).
        public var radius: Double?
        /// [r, g, b], 0…1 (default a blue-white engine plasma).
        public var color: [Double]?

        public init(layer: EffectLayer, at: [Double], radius: Double? = nil, color: [Double]? = nil) {
            self.layer = layer; self.at = at; self.radius = radius; self.color = color
        }
    }

    /// Name substrings for a layer (descriptor override, else the defaults).
    public func nameMatches(_ layer: EffectLayer) -> [String] {
        (layers?[layer.rawValue] ?? layer.defaultNameMatches).map { $0.lowercased() }
    }

    public var effectiveScale: Double { max(1, scale ?? 2) }
    public var effectiveColumns: Int { max(1, columns ?? SpriteSheet.framesPerRow) }
    public var hidesClassicOverlays: Bool { (overlays ?? (kind == .model ? .hide : .keep)) == .hide }
    public var allowsLive: Bool { kind == .model && (live ?? true) }

    /// How a model is posed, lit and framed. Every field is optional; the
    /// defaults reproduce the classic EV Nova sprite look (a fixed camera
    /// looking down at the ship, key light from the upper left).
    ///
    /// Model convention: Y up, nose toward +Z (the glTF / USD convention),
    /// units arbitrary — the model is fitted to the classic sprite's size.
    public struct BakeSettings: Codable, Hashable, Sendable {
        /// Camera elevation above the horizon, degrees (90 = straight down).
        public var pitch: Double?
        /// Extra rotation (degrees, about +Y) applied to the model before
        /// posing — for models whose nose isn't +Z.
        public var yaw: Double?
        /// Rotation about the model's X axis, degrees, applied before `yaw` —
        /// for models whose up axis isn't +Y (e.g. Z-up exports): ±90.
        public var tilt: Double?
        /// Full up-axis fix: rotation [x, y, z] in degrees (applied in that
        /// order, before `yaw`). Overrides `tilt`. For models exported lying
        /// on their side or upside down.
        public var rotate: [Double]?
        /// Exact orientation fix: a 3×3 rotation, row-major, mapping the
        /// model's axes onto (wingspan, height, nose). Overrides `rotate`/`tilt`.
        /// Written by `novaswift-hd orient` for models generated at an angle.
        public var orientation: [Double]?
        /// Roll applied to the banking sets, degrees.
        public var bankRoll: Double?
        /// Fraction of the classic sprite's opaque extent the model fills (1 =
        /// the same size as the classic art).
        public var fit: Double?
        /// Key-light direction in screen terms (x right, y up, z toward the
        /// viewer). Default upper-left-front.
        public var light: [Double]?
        /// Overall light multiplier.
        public var exposure: Double?
        /// Pixels per classic pixel to render at (capped by the player's
        /// HD-detail setting).
        public var scale: Double?
        /// Spin, degrees per second, for live-drawn planets/stations (0 = still).
        public var spin: Double?
        /// Planets: an atmosphere shell drawn around the model — rim glow
        /// colour [r, g, b] (0…1). Omit for airless bodies and ships.
        public var atmosphere: [Double]?

        public init(pitch: Double? = nil, yaw: Double? = nil, bankRoll: Double? = nil, fit: Double? = nil,
                    light: [Double]? = nil, exposure: Double? = nil, scale: Double? = nil, spin: Double? = nil,
                    atmosphere: [Double]? = nil) {
            self.pitch = pitch; self.yaw = yaw; self.bankRoll = bankRoll; self.fit = fit
            self.light = light; self.exposure = exposure; self.scale = scale; self.spin = spin
            self.atmosphere = atmosphere
        }
    }
}

/// `manifest.json` of a `.nsx` sidecar pack.
public struct GraphicsPackManifest: Codable, Hashable, Sendable {
    /// Format version. Readers accept `format <= GraphicsPackManifest.currentFormat`.
    public var format: Int
    public var name: String?
    public var author: String?
    public var license: String?
    public var graphics: [GraphicsEnhancement]

    public static let currentFormat = 1
    public static let fileName = "manifest.json"
    public static let folderExtension = "nsx"

    public init(format: Int = GraphicsPackManifest.currentFormat, name: String? = nil, author: String? = nil,
                license: String? = nil, graphics: [GraphicsEnhancement]) {
        self.format = format; self.name = name; self.author = author; self.license = license
        self.graphics = graphics
    }
}

/// Where an enhancement's asset bytes live.
public enum GraphicsAssetSource: Hashable, Sendable {
    case blob(Data)
    case file(URL)

    public func loadData() -> Data? {
        switch self {
        case .blob(let d): return d
        case .file(let url): return try? Data(contentsOf: url, options: .mappedIfSafe)
        }
    }

    /// A stable content key (SHA-256 of the bytes) for caching anything
    /// derived from this asset — bakes are reused across launches and data
    /// sets as long as the asset itself is unchanged.
    public func contentKey() -> String? {
        guard let data = loadData() else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// File extension hint ("png", "usdz") for loaders that need one.
    public var fileExtension: String? {
        switch self {
        case .file(let url): return url.pathExtension.lowercased()
        case .blob(let d):
            if d.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
            if d.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "usdz" }   // USDZ is a zip
            return nil
        }
    }
}

/// An enhancement ready to use: its descriptor, asset and origin.
public struct ResolvedGraphicsEnhancement: Hashable, Sendable {
    public let spriteID: Int
    public let descriptor: GraphicsEnhancement
    public let source: GraphicsAssetSource
    /// "" for the base data, else the plug-in bundle id / sidecar pack name.
    public let origin: String
}

/// The enhancements in effect for a loaded data set, by sprite id.
public struct GraphicsEnhancementCatalog: Sendable {
    public private(set) var bySprite: [Int: ResolvedGraphicsEnhancement] = [:]
    /// Descriptors that could not be used, with the reason (shown to plug-in
    /// authors in the log; the classic art draws instead).
    public private(set) var problems: [String] = []

    public init() {}

    public var isEmpty: Bool { bySprite.isEmpty }
    public subscript(spriteID: Int) -> ResolvedGraphicsEnhancement? { bySprite[spriteID] }

    mutating func set(_ e: ResolvedGraphicsEnhancement) { bySprite[e.spriteID] = e }
    mutating func problem(_ s: String) { problems.append(s) }

    /// Read every `NSgx` descriptor in a merged collection. Each winner of the
    /// override chain is used; its `NSbl` is looked up in the same collection,
    /// so a plug-in can also override another's asset bytes.
    public mutating func addInFile(from resources: ResourceCollection) {
        for r in resources.resources(of: GraphicsEnhancementType.descriptor) {
            let label = "NSgx #\(r.id)" + (r.pluginID.isEmpty ? "" : " (\(r.pluginID))")
            guard var d = try? JSONDecoder().decode(GraphicsEnhancement.self, from: r.data) else {
                problem("\(label): not a valid graphics descriptor (JSON)"); continue
            }
            d.sprite = r.id
            guard let blobID = d.blob else { problem("\(label): no \"blob\" given"); continue }
            guard let blob = resources.resource(GraphicsEnhancementType.blob, blobID) else {
                problem("\(label): NSbl #\(blobID) not found"); continue
            }
            set(ResolvedGraphicsEnhancement(spriteID: r.id, descriptor: d, source: .blob(blob.data),
                                            origin: r.pluginID))
        }
    }

    /// Apply one sidecar pack on top.
    public mutating func addSidecar(_ pack: URL, origin: String) {
        let name = pack.lastPathComponent
        let manifestURL = pack.appendingPathComponent(GraphicsPackManifest.fileName)
        guard let data = try? Data(contentsOf: manifestURL) else {
            problem("\(name): no \(GraphicsPackManifest.fileName)"); return
        }
        let manifest: GraphicsPackManifest
        do { manifest = try JSONDecoder().decode(GraphicsPackManifest.self, from: data) } catch {
            problem("\(name): \(GraphicsPackManifest.fileName) is not valid (\(error))"); return
        }
        guard manifest.format <= GraphicsPackManifest.currentFormat else {
            problem("\(name): format \(manifest.format) is newer than this version understands"); return
        }
        let root = pack.standardizedFileURL.resolvingSymlinksInPath()
        for d in manifest.graphics {
            guard let sprite = d.sprite else { problem("\(name): an entry has no \"sprite\" id"); continue }
            guard let path = d.file, !path.isEmpty else { problem("\(name): sprite \(sprite) has no \"file\""); continue }
            let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            // Assets must stay inside the pack.
            guard url.path.hasPrefix(root.path + "/") else {
                problem("\(name): sprite \(sprite) file \"\(path)\" is outside the pack"); continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                problem("\(name): sprite \(sprite) file \"\(path)\" not found"); continue
            }
            set(ResolvedGraphicsEnhancement(spriteID: sprite, descriptor: d, source: .file(url), origin: origin))
        }
    }
}

// MARK: - Discovery and layering

extension GameLibrary {
    /// Every `.nsx` sidecar pack under the plug-in folders: directly in a
    /// folder, or one level down inside a plug-in's folder.
    public static func discoverGraphicsPacks(in directories: [URL]) -> [URL] {
        let fm = FileManager.default
        func subfolders(_ dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                          options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false }
                .sorted(by: nameOrder)
        }
        func isPack(_ url: URL) -> Bool { url.pathExtension.lowercased() == GraphicsPackManifest.folderExtension }
        // A pack sits in a plug-ins folder, inside a plug-in's folder, or — as
        // unpacked by the plug-in manager — inside the download's own wrapper
        // folder under that. Search a few levels, never inside a pack.
        var out: [URL] = []
        func search(_ dir: URL, depth: Int) {
            for child in subfolders(dir) {
                if isPack(child) { out.append(child) } else if depth > 1 { search(child, depth: depth - 1) }
            }
        }
        for dir in directories { search(dir, depth: 4) }
        return out
    }

    /// The bundle a sidecar pack belongs to: a plug-in folder owns the packs
    /// inside it; a loose plug-in file owns the pack beside it with the same
    /// base name. nil = a standalone HD pack.
    static func owner(ofGraphicsPack pack: URL, in plugins: [PluginBundle]) -> PluginBundle? {
        let packPath = pack.standardizedFileURL.path
        let parent = pack.deletingLastPathComponent().standardizedFileURL.path
        let base = pack.deletingPathExtension().lastPathComponent.uppercased()
        // A folder plug-in owns every pack anywhere inside its folder (e.g. a
        // `Graphics/` subfolder, or the download's wrapper folder); the
        // innermost folder wins, so an opt-in sub-item owns its own packs.
        var best: (bundle: PluginBundle, depth: Int)?
        for p in plugins {
            // A total conversion's files sit in its `Nova Files/`; its packs may
            // sit beside that folder, at the conversion's root.
            let tcRoots = p.novaFilesURLs.map { $0.deletingLastPathComponent().deletingLastPathComponent() }
            for f in p.allFileURLs + tcRoots.map({ $0.appendingPathComponent(".tc-root") }) {
                let folder = f.deletingLastPathComponent().standardizedFileURL.path
                if p.id == f.lastPathComponent {
                    // A loose plug-in file owns only the same-named pack beside it.
                    if folder == parent, f.deletingPathExtension().lastPathComponent.uppercased() == base {
                        return p
                    }
                } else if packPath.hasPrefix(folder + "/") {
                    let depth = folder.count
                    if depth > (best?.depth ?? -1) { best = (p, depth) }
                }
            }
        }
        return best?.bundle
    }

    /// Build the graphics catalog for a merged data set. In-file descriptors
    /// follow the normal override chain (already resolved in `resources`).
    /// Sidecar packs apply on top, in plug-in load order — a plug-in's own
    /// pack only while that plug-in is loaded — then standalone packs by name.
    public static func graphicsCatalog(resources: ResourceCollection, plugins: [PluginBundle],
                                       graphicsPacks: [URL], flatPluginOrder: Bool = true)
        -> GraphicsEnhancementCatalog {
        var catalog = GraphicsEnhancementCatalog()
        catalog.addInFile(from: resources)

        let layers = resolveLayers(baseFiles: [], plugins: plugins, flat: flatPluginOrder)
        var rank: [String: Int] = [:]
        for (i, layer) in layers.plugins.enumerated() { rank[layer.id] = i }

        var owned: [(rank: Int, pack: URL, origin: String)] = []
        var standalone: [URL] = []
        for pack in graphicsPacks {
            if let p = owner(ofGraphicsPack: pack, in: plugins) {
                guard let r = rank[p.id] else { continue }   // its plug-in isn't loaded
                owned.append((r, pack, p.id))
            } else {
                standalone.append(pack)
            }
        }
        for o in owned.sorted(by: { $0.rank != $1.rank ? $0.rank < $1.rank : nameOrder($0.pack, $1.pack) }) {
            catalog.addSidecar(o.pack, origin: o.origin)
        }
        for pack in standalone.sorted(by: nameOrder) {
            catalog.addSidecar(pack, origin: pack.lastPathComponent)
        }
        return catalog
    }
}
