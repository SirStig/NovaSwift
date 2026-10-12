import Foundation

/// Authoring helpers for NovaSwift's HD sprite / 3D model layer, in its
/// in-plug-in form (docs/HD_PIPELINE.md "Inside the plug-in file"):
///
/// - `NSgx` #<sprite id>: UTF-8 JSON `GraphicsEnhancement` with `"blob": <id>`
///   (no `sprite`/`file` keys — the resource id is the sprite id);
/// - `NSbl` #<any id>: the asset bytes (PNG for `sprite`, USDZ for `model`).
///
/// The original game never asks for either type, so the file still loads
/// unchanged there. This matches `GraphicsPackEmbedding.embed` exactly:
/// blob ids are allocated from 128 upward, identical assets share one blob,
/// and re-attaching a sprite replaces its descriptor (dropping the old blob
/// when nothing else uses it).
public enum HDPackAuthoring {

    public enum AuthoringError: Swift.Error, CustomStringConvertible, Equatable {
        case unsupportedAsset(String)
        case noSpriteID(type: String, id: Int)
        case badSpriteID(Int)

        public var description: String {
            switch self {
            case let .unsupportedAsset(m): return m
            case let .noSpriteID(t, id): return "\(t) #\(id) does not resolve to a sprite id"
            case let .badSpriteID(id): return "sprite id \(id) is outside 0...32767"
            }
        }
    }

    /// One attachment found in a collection.
    public struct Attachment: Sendable, Hashable {
        public let spriteID: Int
        public let descriptor: GraphicsEnhancement
        public let blobID: Int?
        public let assetByteCount: Int
        public var kind: GraphicsEnhancement.Kind { descriptor.kind }
    }

    // MARK: Resolving a resource to its sprite id

    /// The sprite id an enhancement for `(type, id)` should be keyed to:
    /// `rlëD`/`PICT` -> itself; `spïn` -> its sprite; `shän` -> its base image;
    /// `spöb` -> its graphic's `spïn` sprite. nil for anything else.
    public static func spriteID(forType type: FourCharCode, id: Int, in c: ResourceCollection) -> Int? {
        func spinSprite(_ spinID: Int) -> Int? { c.resource(NovaType.spin, spinID).map { SpinRes($0).spriteID } }
        switch type {
        case NovaType.rleD, NovaType.pict: return id
        case NovaType.spin: return spinSprite(id)
        case NovaType.shan: return c.resource(NovaType.shan, id).map { ShanRes($0).baseSpriteID }
        case NovaType.spob:
            guard let r = c.resource(NovaType.spob, id) else { return nil }
            let spinID = SpobRes(r).graphicSpinID
            return spinSprite(spinID) ?? spinID
        default: return nil
        }
    }

    // MARK: Attach

    /// Attach an HD sprite atlas (PNG bytes, the classic sheet's layout at
    /// `scale`× size) to `spriteID`.
    @discardableResult
    public static func attachSprite(png: Data, spriteID: Int, scale: Double = 2, columns: Int? = nil,
                                    frameCount: Int? = nil, overlays: GraphicsEnhancement.Overlays? = nil,
                                    name: String = "", to c: inout ResourceCollection) throws -> Attachment {
        guard png.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            throw AuthoringError.unsupportedAsset("HD sprite atlases must be PNG")
        }
        let d = GraphicsEnhancement(kind: .sprite, scale: scale, columns: columns, frameCount: frameCount,
                                    overlays: overlays)
        return try attach(d, asset: png, spriteID: spriteID, name: name, to: &c)
    }

    /// Attach a 3D model (USDZ bytes) to `spriteID`.
    @discardableResult
    public static func attachModel(usdz: Data, spriteID: Int, bake: GraphicsEnhancement.BakeSettings? = nil,
                                   overlays: GraphicsEnhancement.Overlays? = nil,
                                   layers: [String: [String]]? = nil,
                                   effects: [GraphicsEnhancement.Effect]? = nil, live: Bool? = nil,
                                   shield: [Double]? = nil, name: String = "",
                                   to c: inout ResourceCollection) throws -> Attachment {
        guard usdz.starts(with: [0x50, 0x4B, 0x03, 0x04]) else {
            throw AuthoringError.unsupportedAsset("in-file 3D models must be USDZ (convert glTF/FBX/.blend first)")
        }
        var d = GraphicsEnhancement(kind: .model, overlays: overlays, bake: bake, live: live,
                                    layers: layers, effects: effects)
        d.shield = shield
        return try attach(d, asset: usdz, spriteID: spriteID, name: name, to: &c)
    }

    /// Same as `attachSprite`/`attachModel`, addressed by the resource being
    /// upgraded (e.g. a `shän` or `spöb`): resolves the sprite id first.
    @discardableResult
    public static func attachSprite(png: Data, toResource type: FourCharCode, id: Int, scale: Double = 2,
                                    columns: Int? = nil, frameCount: Int? = nil,
                                    overlays: GraphicsEnhancement.Overlays? = nil, name: String = "",
                                    in c: inout ResourceCollection) throws -> Attachment {
        guard let sprite = spriteID(forType: type, id: id, in: c) else {
            throw AuthoringError.noSpriteID(type: type.description, id: id)
        }
        return try attachSprite(png: png, spriteID: sprite, scale: scale, columns: columns,
                                frameCount: frameCount, overlays: overlays, name: name, to: &c)
    }

    @discardableResult
    public static func attachModel(usdz: Data, toResource type: FourCharCode, id: Int,
                                   bake: GraphicsEnhancement.BakeSettings? = nil, name: String = "",
                                   in c: inout ResourceCollection) throws -> Attachment {
        guard let sprite = spriteID(forType: type, id: id, in: c) else {
            throw AuthoringError.noSpriteID(type: type.description, id: id)
        }
        return try attachModel(usdz: usdz, spriteID: sprite, bake: bake, name: name, to: &c)
    }

    private static func attach(_ descriptor: GraphicsEnhancement, asset: Data, spriteID: Int, name: String,
                               to c: inout ResourceCollection) throws -> Attachment {
        guard (0...32767).contains(spriteID) else { throw AuthoringError.badSpriteID(spriteID) }
        remove(spriteID: spriteID, from: &c)

        // Reuse an identical blob, else the first free id from 128.
        let blobs = c.resources(of: GraphicsEnhancementType.blob)
        let blobID: Int
        if let same = blobs.first(where: { $0.data == asset }) {
            blobID = same.id
        } else {
            let used = Set(blobs.map(\.id))
            var next = GraphicsPackEmbedding.firstBlobID
            while used.contains(next) { next += 1 }
            blobID = next
            c.add(Resource(type: GraphicsEnhancementType.blob, id: blobID,
                           name: String(name.prefix(255)), data: asset))
        }
        var d = descriptor
        d.sprite = nil; d.file = nil; d.blob = blobID
        let json = try JSONEncoder().encode(d)
        c.add(Resource(type: GraphicsEnhancementType.descriptor, id: spriteID, name: String(name.prefix(255)),
                       data: json))
        return Attachment(spriteID: spriteID, descriptor: d, blobID: blobID, assetByteCount: asset.count)
    }

    // MARK: List / remove

    /// Every readable `NSgx` descriptor in the collection, by sprite id.
    public static func attachments(in c: ResourceCollection) -> [Attachment] {
        c.resources(of: GraphicsEnhancementType.descriptor).compactMap { r in
            guard var d = try? JSONDecoder().decode(GraphicsEnhancement.self, from: r.data) else { return nil }
            d.sprite = r.id
            let size = d.blob.flatMap { c.resource(GraphicsEnhancementType.blob, $0)?.data.count } ?? 0
            return Attachment(spriteID: r.id, descriptor: d, blobID: d.blob, assetByteCount: size)
        }
    }

    /// Remove the attachment for `spriteID` and its blob if no other
    /// descriptor uses it. Returns whether a descriptor existed.
    @discardableResult
    public static func remove(spriteID: Int, from c: inout ResourceCollection) -> Bool {
        guard let old = c.resource(GraphicsEnhancementType.descriptor, spriteID) else { return false }
        c.remove(GraphicsEnhancementType.descriptor, spriteID)
        if let blob = (try? JSONDecoder().decode(GraphicsEnhancement.self, from: old.data))?.blob {
            let stillUsed = c.resources(of: GraphicsEnhancementType.descriptor).contains {
                (try? JSONDecoder().decode(GraphicsEnhancement.self, from: $0.data))?.blob == blob
            }
            if !stillUsed { c.remove(GraphicsEnhancementType.blob, blob) }
        }
        return true
    }

    /// Remove every attachment (descriptors and blobs).
    public static func removeAll(from c: inout ResourceCollection) {
        for r in c.resources(of: GraphicsEnhancementType.descriptor) { c.remove(GraphicsEnhancementType.descriptor, r.id) }
        for r in c.resources(of: GraphicsEnhancementType.blob) { c.remove(GraphicsEnhancementType.blob, r.id) }
    }

    /// Export all in-file attachments as an `.nsx` sidecar folder.
    @discardableResult
    public static func exportPack(from c: ResourceCollection, to url: URL, name: String? = nil) throws -> Int {
        try GraphicsPackEmbedding.extract(from: c, to: url, name: name)
    }
}
