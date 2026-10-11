import Foundation

/// Moves an HD pack between its two shipping forms: a `.nsx` sidecar folder
/// and resources inside the plug-in file itself (`NSgx` descriptors +
/// `NSbl` blobs, which the original game ignores). This is how a mod author
/// adds HD art to an existing plug-in — Arpia 2, say — and repacks it as one
/// file that still loads unchanged in the original.
public enum GraphicsPackEmbedding {
    public enum EmbedError: Error, CustomStringConvertible {
        case noManifest(String)
        case badManifest(String)
        case missingFile(sprite: Int, file: String)
        case unsupportedInFile(sprite: Int, file: String)
        case noSprite(index: Int)

        public var description: String {
            switch self {
            case .noManifest(let p): return "\(p) has no \(GraphicsPackManifest.fileName)"
            case .badManifest(let e): return "\(GraphicsPackManifest.fileName) is not valid (\(e))"
            case .missingFile(let s, let f): return "sprite \(s): file \"\(f)\" not found in the pack"
            case .unsupportedInFile(let s, let f):
                return "sprite \(s): \"\(f)\" can't go inside a plug-in file — in-file assets must be PNG or USDZ"
            case .noSprite(let i): return "graphics entry #\(i + 1) has no sprite id"
            }
        }
    }

    /// Lowest id used for new `NSbl` blobs (the usual first free id in a
    /// classic resource file).
    static let firstBlobID = 128

    /// `collection` with every enhancement of the `.nsx` folder at `pack`
    /// added as in-file resources. An existing descriptor for the same sprite
    /// is replaced (and its blob removed if nothing else uses it).
    public static func embed(pack: URL, into collection: ResourceCollection) throws -> ResourceCollection {
        let manifestURL = pack.appendingPathComponent(GraphicsPackManifest.fileName)
        guard let mdata = try? Data(contentsOf: manifestURL) else { throw EmbedError.noManifest(pack.lastPathComponent) }
        let manifest: GraphicsPackManifest
        do { manifest = try JSONDecoder().decode(GraphicsPackManifest.self, from: mdata) } catch {
            throw EmbedError.badManifest(String(describing: error))
        }

        var out = collection
        var usedBlobIDs = Set(out.resources(of: GraphicsEnhancementType.blob).map(\.id))
        var nextBlob = firstBlobID
        func allocateBlobID() -> Int {
            while usedBlobIDs.contains(nextBlob) { nextBlob += 1 }
            usedBlobIDs.insert(nextBlob)
            return nextBlob
        }
        // The same file shared by several sprites is stored once.
        var blobForFile: [String: Int] = [:]

        for (i, entry) in manifest.graphics.enumerated() {
            guard let sprite = entry.sprite else { throw EmbedError.noSprite(index: i) }
            guard let file = entry.file else { continue }   // already in-file style; nothing to carry
            let url = pack.appendingPathComponent(file).standardizedFileURL
            guard url.path.hasPrefix(pack.standardizedFileURL.path + "/"),
                  let bytes = try? Data(contentsOf: url) else { throw EmbedError.missingFile(sprite: sprite, file: file) }
            guard GraphicsAssetSource.blob(bytes).fileExtension != nil else {
                throw EmbedError.unsupportedInFile(sprite: sprite, file: file)
            }

            // Replace an earlier descriptor for this sprite.
            if let old = out.resource(GraphicsEnhancementType.descriptor, sprite) {
                out.remove(GraphicsEnhancementType.descriptor, sprite)
                if let oldBlob = (try? JSONDecoder().decode(GraphicsEnhancement.self, from: old.data))?.blob {
                    let stillUsed = out.resources(of: GraphicsEnhancementType.descriptor).contains {
                        (try? JSONDecoder().decode(GraphicsEnhancement.self, from: $0.data))?.blob == oldBlob
                    }
                    if !stillUsed { out.remove(GraphicsEnhancementType.blob, oldBlob); usedBlobIDs.remove(oldBlob) }
                }
            }

            let blobID: Int
            if let shared = blobForFile[file] { blobID = shared } else {
                blobID = allocateBlobID()
                blobForFile[file] = blobID
                out.add(Resource(type: GraphicsEnhancementType.blob, id: blobID,
                                 name: String((file as NSString).lastPathComponent.prefix(255)), data: bytes))
            }
            var d = entry
            d.sprite = nil      // in-file: the descriptor's resource id is the sprite id
            d.file = nil
            d.blob = blobID
            let json = try JSONEncoder().encode(d)
            out.add(Resource(type: GraphicsEnhancementType.descriptor, id: sprite,
                             name: manifest.name.map { String($0.prefix(255)) } ?? "", data: json))
        }
        return out
    }

    /// Write the in-file enhancements of `collection` out as a `.nsx` folder
    /// at `pack` (created; existing files with the same names are replaced).
    /// Returns the number of enhancements written.
    @discardableResult
    public static func extract(from collection: ResourceCollection, to pack: URL, name: String? = nil) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: pack, withIntermediateDirectories: true)
        var entries: [GraphicsEnhancement] = []
        var fileForBlob: [Int: String] = [:]
        for r in collection.resources(of: GraphicsEnhancementType.descriptor).sorted(by: { $0.id < $1.id }) {
            guard var d = try? JSONDecoder().decode(GraphicsEnhancement.self, from: r.data),
                  let blobID = d.blob, let blob = collection.resource(GraphicsEnhancementType.blob, blobID) else { continue }
            let file: String
            if let done = fileForBlob[blobID] { file = done } else {
                let ext = GraphicsAssetSource.blob(blob.data).fileExtension ?? "bin"
                file = "asset_\(blobID).\(ext)"
                try blob.data.write(to: pack.appendingPathComponent(file), options: .atomic)
                fileForBlob[blobID] = file
            }
            d.sprite = r.id
            d.blob = nil
            d.file = file
            entries.append(d)
        }
        let manifest = GraphicsPackManifest(name: name, graphics: entries)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: pack.appendingPathComponent(GraphicsPackManifest.fileName), options: .atomic)
        return entries.count
    }
}
