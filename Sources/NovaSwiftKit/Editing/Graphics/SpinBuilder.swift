import Foundation

/// Builds `spïn` records (the sprite descriptors every ship, weapon, stellar,
/// explosion and asteroid points at) in the layout `SpinRes` reads: six
/// big-endian Int16s — sprite id, mask id, tile width, tile height, tiles
/// across, tiles down.
public enum SpinBuilder {

    public static let recordSize = 12

    /// The raw 12-byte record.
    public static func data(spriteID: Int, maskID: Int, tileWidth: Int, tileHeight: Int,
                            tilesAcross: Int, tilesDown: Int) -> Data {
        var b = [UInt8](); b.reserveCapacity(recordSize)
        for v in [spriteID, maskID, tileWidth, tileHeight, tilesAcross, tilesDown] { b.appendBE16(v) }
        return Data(b)
    }

    /// A `spïn` resource for a sheet's grid (`columns`×`rows` tiles of the
    /// frame size). For an `rlëD` sprite the mask id is ignored by the game;
    /// by convention it defaults to `spriteID + 1`. For a PICT sprite it must be
    /// a different PICT than the sprite (the original rejects equal ids).
    public static func resource(id: Int, name: String = "", spriteID: Int, maskID: Int? = nil,
                                sheet: SpriteSheet) -> Resource {
        resource(id: id, name: name, spriteID: spriteID, maskID: maskID ?? spriteID + 1,
                 tileWidth: sheet.frameWidth, tileHeight: sheet.frameHeight,
                 tilesAcross: sheet.columns, tilesDown: sheet.rows)
    }

    public static func resource(id: Int, name: String = "", spriteID: Int, maskID: Int,
                                tileWidth: Int, tileHeight: Int, tilesAcross: Int, tilesDown: Int) -> Resource {
        Resource(type: NovaType.spin, id: id, name: name,
                 data: data(spriteID: spriteID, maskID: maskID, tileWidth: tileWidth, tileHeight: tileHeight,
                            tilesAcross: tilesAcross, tilesDown: tilesDown))
    }

    /// `rlëD` + `spïn` for a sheet: `[rlëD #spriteID, spïn #spinID]`.
    public static func rleSprite(spinID: Int, spriteID: Int, name: String = "",
                                 sheet: SpriteSheet, alphaThreshold: UInt8 = 128) throws -> [Resource] {
        let rle = try RLEDEncoder.encode(sheet, alphaThreshold: alphaThreshold)
        return [Resource(type: NovaType.rleD, id: spriteID, name: name, data: rle),
                resource(id: spinID, name: name, spriteID: spriteID, sheet: sheet)]
    }

    /// Classic PICT sprite + mask + `spïn`: `[PICT #spriteID, PICT #maskID, spïn #spinID]`.
    public static func pictSprite(spinID: Int, spriteID: Int, maskID: Int, name: String = "",
                                  sheet: SpriteSheet, alphaThreshold: UInt8 = 128) throws -> [Resource] {
        guard spriteID != maskID else { throw PICTSpriteSheet.Failure.sameSpriteAndMask(spriteID) }
        let pair = try PICTEncoder.encodeSpritePair(sheet, alphaThreshold: alphaThreshold)
        return [Resource(type: NovaType.pict, id: spriteID, name: name, data: pair.image),
                Resource(type: NovaType.pict, id: maskID, name: name, data: pair.mask),
                resource(id: spinID, name: name, spriteID: spriteID, maskID: maskID, sheet: sheet)]
    }
}
