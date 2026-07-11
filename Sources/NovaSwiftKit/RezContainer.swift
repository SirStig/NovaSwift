import Foundation

/// Parser for the Graphite/ResForge "BRGR" Rez container — the format used by
/// modern community `.rez` plug-ins and total conversions.
///
/// The container is little-endian, but its resource map is big-endian. Layout
/// reference: ResForge `RezFormat.swift` / burgerlib `brrezfile.cpp`.
/// See docs/DATA_FORMAT.md §2.3.
public enum RezContainer {
    private static let signature: UInt32 = 0x4252_4752 // 'BRGR'
    private static let groupType: UInt32 = 1
    private static let nameFieldLength = 256

    public static func parse(_ data: Data) throws -> ResourceCollection {
        let reader = BinaryReader(data, bigEndian: false) // container is little-endian

        // Root header. Signature is stored big-endian; the rest little-endian.
        let sig = try reader.readU32(bigEndian: true)
        let numGroups = try reader.readU32()
        let headerLength = try reader.readU32()
        let type = try reader.readU32()
        let baseIndex = Int(try reader.readU32())
        let numEntries = Int(try reader.readU32())

        guard sig == signature, numGroups == 1, type == groupType,
              numEntries >= 1, Int(headerLength) <= data.count
        else {
            throw ResourceFileError.corrupt(
                "bad BRGR header: sig=\(String(format: "%08X", sig)) numGroups=\(numGroups) type=\(type) numEntries=\(numEntries)")
        }

        // Entry table: (dataOffset, dataSize, nameOffset) per entry. The last
        // entry describes the resource map itself.
        var offsets = [Int](); offsets.reserveCapacity(numEntries)
        var sizes = [Int](); sizes.reserveCapacity(numEntries)
        for _ in 0..<numEntries {
            offsets.append(Int(try reader.readU32()))
            sizes.append(Int(try reader.readU32()))
            try reader.advance(4) // skip name offset
        }

        // Resource map (big-endian).
        let mapOffset = offsets[numEntries - 1]
        try reader.seek(mapOffset)
        let typeListOffset = Int(try reader.readU32(bigEndian: true)) + mapOffset
        let numTypes = Int(try reader.readU32(bigEndian: true))

        try reader.seek(typeListOffset)
        var collection = ResourceCollection()
        for _ in 0..<numTypes {
            let resType = try reader.readFourCharCode()
            let resListOffset = Int(try reader.readU32(bigEndian: true)) + mapOffset
            let numResources = Int(try reader.readU32(bigEndian: true))

            try reader.pushPosition(resListOffset)
            for _ in 0..<numResources {
                let index = Int(try reader.readU32(bigEndian: true)) - baseIndex
                guard index >= 0, index < numEntries else {
                    throw ResourceFileError.corrupt("resource index \(index) out of range 0..<\(numEntries)")
                }
                try reader.advance(4) // duplicate type code — already known
                let id = Int(try reader.readI16(bigEndian: true))
                let afterName = reader.position + nameFieldLength

                let name = try reader.readCString(limit: nameFieldLength)

                let blob = Data(reader.bytes[offsets[index]..<offsets[index] + sizes[index]])
                collection.add(Resource(type: resType, id: id, name: name, data: blob))

                try reader.seek(afterName)
            }
            reader.popPosition()
        }

        return collection
    }
}
