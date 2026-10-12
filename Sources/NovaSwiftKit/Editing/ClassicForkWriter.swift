import Foundation

/// Writer for the classic Macintosh resource-fork layout — the exact inverse of
/// `ClassicResourceFork.parse`, so the bytes load in EV Nova on macOS as a
/// plug-in fork or `.ndat` data-fork file. Layout (Inside Macintosh, More
/// Macintosh Toolbox):
///
/// - 16-byte header: data offset (256), map offset, data length, map length;
/// - padding to 256 bytes, then the data area: for each resource a 4-byte
///   length followed by its bytes;
/// - the map: a 16-byte copy of the header, 4-byte next-map handle, 2-byte file
///   ref, 2-byte attributes, then the type-list and name-list offsets (relative
///   to the map start), the type list (count − 1, then per type: code, count − 1,
///   reference-list offset), the reference lists (id, name offset or 0xFFFF,
///   attribute byte + 3-byte data offset, 4-byte handle), and the Pascal names.
public enum ClassicForkWriter {
    /// Classic forks start their data area at byte 256 by convention.
    static let dataStart = 256
    /// Resource data offsets are 3 bytes, so the data area can't exceed 16 MiB.
    public static let maxDataArea = 0x00FF_FFFF

    public enum WriteError: Swift.Error, CustomStringConvertible {
        case tooLarge
        case noResources
        public var description: String {
            switch self {
            case .tooLarge: return "The resources total more than 16 MiB, the limit of a classic resource fork"
            case .noResources: return "A classic resource fork needs at least one resource"
            }
        }
    }

    public static func write(_ collection: ResourceCollection) throws -> Data {
        let types = collection.types
        guard !types.isEmpty else { throw WriteError.noResources }

        // Data area, remembering each resource's offset within it.
        var dataArea = Data()
        var offsets: [FourCharCode: [Int: Int]] = [:]
        for type in types {
            for r in collection.resources(of: type) {
                offsets[type, default: [:]][r.id] = dataArea.count
                dataArea.append(be32(r.data.count))
                dataArea.append(r.data)
            }
        }
        guard dataArea.count <= maxDataArea else { throw WriteError.tooLarge }

        // Name list (Pascal strings), deduplicating nothing: every named
        // resource gets its own entry like the Resource Manager writes.
        var nameList = Data()
        var nameOffsets: [FourCharCode: [Int: Int]] = [:]
        for type in types {
            for r in collection.resources(of: type) where !r.name.isEmpty {
                let bytes = Array(FieldCodec.macRoman(r.name).prefix(255))
                nameOffsets[type, default: [:]][r.id] = nameList.count
                nameList.append(UInt8(bytes.count)); nameList.append(contentsOf: bytes)
            }
        }

        // Map: header copy (patched below), handle, ref, attrs, two offsets.
        let typeListOffset = 28 // right after the 28-byte map header
        let typeListSize = 2 + 8 * types.count
        var refLists = Data()
        var typeList = Data()
        typeList.append(be16(types.count - 1))
        for type in types {
            let list = collection.resources(of: type)
            typeList.append(contentsOf: type.bytes)
            typeList.append(be16(list.count - 1))
            typeList.append(be16(typeListSize + refLists.count))
            for r in list {
                refLists.append(be16(r.id & 0xFFFF))
                refLists.append(be16(nameOffsets[type]?[r.id] ?? 0xFFFF))
                let attrOffset = (UInt32(r.attributes & 0xFF) << 24) | UInt32(offsets[type]![r.id]!)
                refLists.append(be32(Int(attrOffset)))
                refLists.append(Data(count: 4)) // in-memory handle
            }
        }
        let nameListOffset = typeListOffset + typeList.count + refLists.count
        var map = Data(count: 24)
        map.append(be16(typeListOffset))
        map.append(be16(nameListOffset))
        map.append(typeList); map.append(refLists); map.append(nameList)

        let mapOffset = dataStart + dataArea.count
        var header = Data()
        header.append(be32(dataStart)); header.append(be32(mapOffset))
        header.append(be32(dataArea.count)); header.append(be32(map.count))
        map.replaceSubrange(0..<16, with: header)

        var out = header
        out.append(Data(count: dataStart - header.count))
        out.append(dataArea)
        out.append(map)
        return out
    }

    private static func be16(_ v: Int) -> Data { Data([UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
    private static func be32(_ v: Int) -> Data {
        Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
}
