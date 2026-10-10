import Foundation

/// Writer for the Graphite/ResForge "BRGR" Rez container — the inverse of
/// `RezContainer.parse`, laid out byte-for-byte like the community `.rez`
/// plug-ins EV Nova CE loads (checked against a shipping plug-in):
///
/// - root header (24 bytes): `BRGR` (big-endian), then little-endian
///   numGroups = 1, headerLength (= first data offset − 12), groupType = 1,
///   baseIndex = 1, numEntries (resources + 1 for the map);
/// - one 12-byte entry per resource (offset, size, nameOffset = 0), then the
///   map's entry, whose nameOffset (relative to byte 12) points at the
///   `resource.map` name that follows the entry table;
/// - resource data, in index order;
/// - the big-endian resource map: typeListOffset (8), numTypes, then per type
///   (code, resListOffset, count), then per resource a 266-byte record
///   (index, type, id, 256-byte name).
///
/// Used to package NovaSwift graphics extensions (`NSgx`/`NSbl`) into an
/// ordinary plug-in file; the full editor write path is still planned.
public enum RezWriter {
    private static let nameFieldLength = 256
    private static let mapName = Array("resource.map".utf8) + [0]

    public static func write(_ collection: ResourceCollection) -> Data {
        // Stable order: by type code, then id. Data is laid out in this order,
        // which is also the order the map's records number them.
        let types = collection.types
        var resources: [Resource] = []
        for type in types { resources += collection.resources(of: type) }

        let numEntries = resources.count + 1
        let entryTableEnd = 24 + 12 * numEntries
        let firstData = entryTableEnd + mapName.count

        var out = Data()
        func le32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        func be32(_ v: Int, into d: inout Data) { var x = UInt32(v).bigEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

        out.append(contentsOf: Array("BRGR".utf8))
        le32(1)
        le32(firstData - 12)
        le32(1)
        le32(1)            // baseIndex
        le32(numEntries)

        var offset = firstData
        for r in resources {
            le32(offset); le32(r.data.count); le32(0)
            offset += r.data.count
        }
        let mapOffset = offset

        // Map body (big-endian), built first so its size is known.
        var map = Data()
        be32(8, into: &map)
        be32(types.count, into: &map)
        var resListOffset = 8 + 12 * types.count
        var index = 1
        var records = Data()
        for type in types {
            let list = collection.resources(of: type)
            map.append(contentsOf: type.bytes)
            be32(resListOffset, into: &map)
            be32(list.count, into: &map)
            for r in list {
                be32(index, into: &records)
                records.append(contentsOf: type.bytes)
                var id = Int16(truncatingIfNeeded: r.id).bigEndian
                withUnsafeBytes(of: &id) { records.append(contentsOf: $0) }
                var name = [UInt8]((r.name.data(using: .macOSRoman) ?? Data()).prefix(nameFieldLength - 1))
                name += [UInt8](repeating: 0, count: nameFieldLength - name.count)
                records.append(contentsOf: name)
                index += 1
            }
            resListOffset += 266 * list.count
        }
        map.append(records)

        le32(mapOffset); le32(map.count); le32(entryTableEnd - 12)
        out.append(contentsOf: mapName)
        for r in resources { out.append(r.data) }
        out.append(map)
        return out
    }
}
