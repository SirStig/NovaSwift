import Foundation

/// Parser for the classic Macintosh resource-fork layout (big-endian). EV Nova's
/// cross-platform `.ndat` files are exactly these bytes stored in the data fork,
/// so the same parser handles both.
///
/// Layout reference: Inside Macintosh / "More Macintosh Toolbox" (resource manager).
/// See docs/DATA_FORMAT.md §2.1.
public enum ClassicResourceFork {
    public static func parse(_ data: Data) throws -> ResourceCollection {
        let reader = BinaryReader(data, bigEndian: true)

        // Header (16 bytes)
        let dataOffset = Int(try reader.readU32())
        let mapOffset = Int(try reader.readU32())
        let dataLength = Int(try reader.readU32())
        let mapLength = Int(try reader.readU32())

        guard dataOffset != 0, mapOffset != 0, mapLength != 0,
              mapOffset == dataOffset + dataLength,
              mapOffset + mapLength <= data.count
        else {
            throw ResourceFileError.corrupt(
                "bad header: dataOffset=\(dataOffset) mapOffset=\(mapOffset) dataLength=\(dataLength) mapLength=\(mapLength) fileSize=\(data.count)")
        }

        // Resource map: skip the 16-byte header copy + 4 (next-map handle) +
        // 2 (file ref) + 2 (fork attributes) = 24 bytes, then the two list offsets.
        try reader.seek(mapOffset + 24)
        let typeListOffset = Int(try reader.readU16()) + mapOffset
        let nameListOffset = Int(try reader.readU16()) + mapOffset

        // Type list. Counts are stored as (count - 1), so a stored 0xFFFF means 0.
        try reader.seek(typeListOffset)
        let numTypes = Int((try reader.readU16()) &+ 1)

        var collection = ResourceCollection()
        for _ in 0..<numTypes {
            let type = try reader.readFourCharCode()
            let numResources = Int((try reader.readU16()) &+ 1)
            let refListOffset = Int(try reader.readU16()) + typeListOffset

            try reader.pushPosition(refListOffset)
            for _ in 0..<numResources {
                let id = Int(try reader.readI16())
                let nameOffset = try reader.readU16()
                // 1 attribute byte + 3-byte data offset, packed into a u32.
                let attrsAndOffset = try reader.readU32()
                let attributes = Int(attrsAndOffset >> 24)
                let resDataOffset = Int(attrsAndOffset & 0x00FF_FFFF) + dataOffset
                let nextEntry = reader.position + 4 // skip the 4-byte in-memory handle

                var name = ""
                if nameOffset != 0xFFFF {
                    try reader.pushPosition(Int(nameOffset) + nameListOffset)
                    name = try reader.readPString()
                    reader.popPosition()
                }

                try reader.seek(resDataOffset)
                let length = Int(try reader.readU32())
                let blob = try reader.readData(length)

                collection.add(Resource(type: type, id: id, name: name,
                                        attributes: attributes, data: blob))
                try reader.seek(nextEntry)
            }
            reader.popPosition()
        }

        return collection
    }
}
