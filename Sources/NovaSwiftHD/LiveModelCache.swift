import Foundation
import NovaSwiftKit
#if canImport(SceneKit) && canImport(Compression)
import SceneKit
import ImageIO

/// Game-ready copies of live 3D models, kept across launches.
///
/// A generated hull is a 20–30 MB USDZ: ~290k triangles with face-varying
/// normals and two 2048² PNG textures. Opening one costs ~300 ms, simplifying
/// it another ~300 ms, and its textures are decoded and uploaded on the first
/// frame that draws it — the stall and the classic sprite showing while a
/// hull "loads". A ship is at most a few hundred pixels on screen, so the
/// copy kept here is the model as it's drawn: already simplified for the
/// detail setting, its textures capped (`maxTexturePixels`, mip-mapped by
/// the GPU anyway, so nothing visible is lost), stored as a SceneKit archive
/// plus raw textures. Loading it is a few milliseconds.
public final class LiveModelCache: @unchecked Sendable {
    /// Bump when what's stored changes shape.
    public static let version = 1
    public let directory: URL

    public convenience init?(subdirectory: String = "NovaSwift/HDLive") {
        guard let caches = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true) else { return nil }
        self.init(directory: caches.appendingPathComponent(subdirectory, isDirectory: true))
    }

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The stored model for `key`, textures attached, or nil.
    public func load(_ key: String) -> SCNNode? {
        let file = directory.appendingPathComponent("\(key).scn")
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              let archive = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        archive.requiresSecureCoding = false
        guard let node = archive.decodeObject(forKey: "node") as? SCNNode,
              let slots = archive.decodeObject(forKey: "textures") as? [Int] else { return nil }
        archive.finishDecoding()
        var images: [Int: CGImage] = [:]
        var ok = true, ordinal = 0
        Self.forEachProperty(node) { p in
            defer { ordinal += 1 }
            guard ordinal < slots.count, slots[ordinal] >= 0 else { return }
            let i = slots[ordinal]
            if images[i] == nil,
               let raw = try? Data(contentsOf: directory.appendingPathComponent("\(key).\(i).nsa"), options: .mappedIfSafe) {
                images[i] = HDAtlas.decodeRaw(raw)
            }
            if let image = images[i] { p.contents = image } else { ok = false }
        }
        return ok && ordinal == slots.count ? node : nil
    }

    /// Store `node` (already simplified, textures already capped) under `key`.
    /// Textures are written beside it in the raw form; the archive holds,
    /// for every material property in walk order, which texture it takes
    /// (contents are emptied while archiving and put back).
    public func store(_ node: SCNNode, key: String) {
        var images: [ObjectIdentifier: (index: Int, image: CGImage)] = [:]
        var swapped: [(SCNMaterialProperty, CGImage)] = []
        var slots: [Int] = []
        Self.forEachProperty(node) { p in
            guard let contents = p.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else {
                slots.append(-1); return
            }
            let image = contents as! CGImage
            let id = ObjectIdentifier(image)
            let index = images[id]?.index ?? images.count
            images[id] = (index, image)
            swapped.append((p, image))
            slots.append(index)
            p.contents = nil
        }
        defer { for (p, image) in swapped { p.contents = image } }
        for (_, entry) in images {
            guard let raw = HDAtlas.encodeRaw(entry.image),
                  (try? raw.write(to: directory.appendingPathComponent("\(key).\(entry.index).nsa"), options: .atomic)) != nil
            else { return }
        }
        let archive = NSKeyedArchiver(requiringSecureCoding: false)
        archive.encode(node, forKey: "node")
        archive.encode(slots, forKey: "textures")
        archive.finishEncoding()
        try? archive.encodedData.write(to: directory.appendingPathComponent("\(key).scn"), options: .atomic)
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Replace every texture under `root` that's still a file reference (how
    /// SceneKit leaves a USDZ's images: decoded only when first drawn) with
    /// the image itself, at most `maxPixels` on its longer side. Textures
    /// shared between properties stay shared.
    public static func capTextures(_ root: SCNNode, maxPixels: Int) {
        var done: [URL: CGImage] = [:]
        forEachProperty(root) { p in
            guard let url = p.contents as? URL else { return }
            if done[url] == nil, let image = image(at: url, maxPixels: maxPixels) { done[url] = image }
            if let image = done[url] { p.contents = image }
        }
    }

    /// Read an image SceneKit refers to by URL: a plain file, or a range of
    /// a USDZ (`…/model.usdz?offset=N&size=M` — USDZ stores files uncompressed).
    static func image(at url: URL, maxPixels: Int) -> CGImage? {
        var data: Data?
        if let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let query = parts.queryItems,
           let offset = query.first(where: { $0.name == "offset" })?.value.flatMap(Int.init),
           let size = query.first(where: { $0.name == "size" })?.value.flatMap(Int.init), size > 0 {
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: parts.path)) else { return nil }
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(offset))
            data = try? handle.read(upToCount: size)
        } else {
            data = try? Data(contentsOf: url)
        }
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    private static func forEachProperty(_ root: SCNNode, _ body: (SCNMaterialProperty) -> Void) {
        root.enumerateHierarchy { node, _ in
            for m in node.geometry?.materials ?? [] {
                for p in [m.diffuse, m.ambient, m.specular, m.emission, m.transparent, m.reflective, m.multiply,
                          m.normal, m.displacement, m.ambientOcclusion, m.selfIllumination, m.metalness,
                          m.roughness, m.clearCoat, m.clearCoatRoughness, m.clearCoatNormal] {
                    body(p)
                }
            }
        }
    }
}
#endif
