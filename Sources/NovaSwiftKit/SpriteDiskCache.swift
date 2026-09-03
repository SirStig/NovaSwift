import Foundation

/// A persistent, cross-launch cache of **decoded** sprite sheets.
///
/// The expensive part of showing a ship or planet isn't reading the resource
/// fork — it's turning EV Nova's run-length-encoded `rlëD` bytes into a flat
/// RGBA surface (`RLED.decode`). That result is pure: the same `rlëD` id in the
/// same data set always decodes to the same surface. The 2002 game never paid
/// this because QuickDraw blitted the RLE straight to screen; we materialise a
/// 32-bit bitmap for Metal, so we do the decode once and keep it.
///
/// This cache persists that decoded surface to disk — LZFSE-compressed where the
/// platform has LZFSE, raw where it doesn't (see `Codec`) — keyed by
/// `rlëD` id under a directory named for the data set's fingerprint (see
/// `GameLibrary.fingerprint`). On a warm cache, first-visit art loads as a fast
/// mmap + decompress instead of a full RLE decode, and second-and-later launches
/// skip the decode entirely — the "it just loads" feel of the original.
///
/// Changing the data set (importing new base data, enabling/disabling a plug-in,
/// or a file's size/mtime changing) yields a new fingerprint, so a stale cache is
/// simply never read; old fingerprint directories are pruned lazily on init.
public final class SpriteDiskCache: @unchecked Sendable {
    private let dir: URL

    /// Bytes: "NSS" + a codec/version byte. Bump the byte to invalidate every
    /// entry when the on-disk layout or the decoder's output changes.
    ///
    /// The last byte doubles as the body codec, because LZFSE is an Apple-only
    /// Foundation/Compression facility: `NSData.compressed(using:)` does not
    /// exist in swift-corelibs-foundation, so Linux and Windows store the
    /// surface uncompressed instead (`.raw`). Both codecs are readable on
    /// Apple; off-Apple an `.lzfse` record is simply treated as a cache miss
    /// and re-decoded. That only ever happens if a cache directory is carried
    /// between platforms — the fingerprint directory lives in the local user's
    /// caches, so in practice each machine only ever meets its own records.
    private static let magicPrefix: [UInt8] = [0x4E, 0x53, 0x53]  // "NSS"
    private static let magicSize = magicPrefix.count + 1

    private enum Codec: UInt8 {
        case lzfse = 0x01
        case raw = 0x02
    }

    /// The codec this platform writes with. LZFSE roughly halves a decoded
    /// surface on disk, so it stays the default wherever it exists.
    /// `canImport(Compression)` is the availability test for it: the algorithm
    /// enum hangs off `NSData` in Foundation, but only on platforms that ship
    /// Apple's Compression framework.
    ///
    /// Off Apple the trade is disk for time: a raw record is roughly twice the
    /// size, but it still skips the RLE decode, which is the expensive half and
    /// the whole reason this cache exists. `maxSurfaceBytes` still bounds any
    /// single entry, and a changed data set still evicts the whole directory.
    private static var writeCodec: Codec {
        #if canImport(Compression)
        return .lzfse
        #else
        return .raw
        #endif
    }

    /// A hard ceiling on a single decoded surface (defends against a corrupt
    /// header asking us to allocate gigabytes). 4096×4096×4 ≈ 64 MB is already
    /// far larger than any real Nova sprite sheet.
    private static let maxSurfaceBytes = 4096 * 4096 * 4

    /// Opens (creating if needed) the cache directory for `fingerprint` under the
    /// system caches directory. Returns nil only if no writable caches location
    /// exists — callers then simply run without a disk cache.
    public init?(fingerprint: String, subdirectory: String = "NovaSwift/DecodedSprites") {
        let fm = FileManager.default
        guard let caches = try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true) else { return nil }
        let root = caches.appendingPathComponent(subdirectory, isDirectory: true)
        let dir = root.appendingPathComponent(fingerprint, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Log.data.error("SpriteDiskCache: could not create \(dir.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
        self.dir = dir
        Self.pruneStaleFingerprints(under: root, keeping: fingerprint)
    }

    private func fileURL(_ rleID: Int) -> URL {
        dir.appendingPathComponent("\(rleID).nss", isDirectory: false)
    }

    /// Load a previously stored decoded sheet for `rleID`, or nil on a miss (or
    /// if the on-disk record is unreadable/corrupt — the caller then re-decodes).
    public func load(_ rleID: Int) -> SpriteSheet? {
        let url = fileURL(rleID)
        // Memory-map: we only touch the small header + hand the compressed body
        // to the decompressor, so there's no reason to fault the whole file in.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return Self.decodeRecord(data)
    }

    /// Persist `sheet` under `rleID`. Best-effort: a write failure just means the
    /// next launch re-decodes. Safe to call concurrently — each id is its own
    /// file and the write is atomic.
    public func store(_ rleID: Int, _ sheet: SpriteSheet) {
        guard let record = Self.encodeRecord(sheet) else { return }
        do {
            try record.write(to: fileURL(rleID), options: .atomic)
        } catch {
            Log.data.debug("SpriteDiskCache: store \(rleID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Record format
    //
    // [ "NSS", codec(1) ]
    // [ frameWidth, frameHeight, frameCount, columns, rows,
    //   surfaceWidth, surfaceHeight ]  — 7 × Int32 little-endian
    // [ RGBA body — LZFSE-compressed (codec 0x01) or raw (codec 0x02) ]

    private static func encodeRecord(_ s: SpriteSheet) -> Data? {
        guard s.rgba.count == s.surfaceWidth * s.surfaceHeight * 4 else { return nil }
        let codec = writeCodec
        guard let body = compressBody(Data(s.rgba), using: codec) else { return nil }
        var out = Data()
        out.append(contentsOf: magicPrefix)
        out.append(codec.rawValue)
        for field in [s.frameWidth, s.frameHeight, s.frameCount, s.columns, s.rows,
                      s.surfaceWidth, s.surfaceHeight] {
            var le = Int32(field).littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        out.append(body)
        return out
    }

    private static func compressBody(_ raw: Data, using codec: Codec) -> Data? {
        switch codec {
        case .raw:
            return raw
        case .lzfse:
            #if canImport(Compression)
            return try? (raw as NSData).compressed(using: .lzfse) as Data
            #else
            return nil
            #endif
        }
    }

    /// Inflate a record body. Returns nil when this platform has no decoder for
    /// `codec` — the caller then treats the record as a miss and re-decodes.
    private static func decompressBody(_ body: Data, codec: Codec) -> Data? {
        switch codec {
        case .raw:
            return body
        case .lzfse:
            #if canImport(Compression)
            return try? (body as NSData).decompressed(using: .lzfse) as Data
            #else
            return nil
            #endif
        }
    }

    private static func decodeRecord(_ data: Data) -> SpriteSheet? {
        let headerSize = magicSize + 7 * MemoryLayout<Int32>.size
        guard data.count > headerSize else { return nil }
        guard Array(data.prefix(magicPrefix.count)) == magicPrefix,
              let codec = Codec(rawValue: data[data.startIndex + magicPrefix.count]) else { return nil }

        var fields = [Int](repeating: 0, count: 7)
        var offset = magicSize
        for i in 0..<7 {
            let slice = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + 4))
            let v = slice.withUnsafeBytes { $0.load(as: Int32.self) }
            fields[i] = Int(Int32(littleEndian: v))
            offset += 4
        }
        let (frameWidth, frameHeight, frameCount, columns, rows, surfaceWidth, surfaceHeight) =
            (fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6])

        let expected = surfaceWidth * surfaceHeight * 4
        guard surfaceWidth > 0, surfaceHeight > 0, expected > 0, expected <= maxSurfaceBytes else {
            return nil
        }
        let body = data.subdata(in: (data.startIndex + headerSize)..<data.endIndex)
        guard let raw = decompressBody(body, codec: codec), raw.count == expected else { return nil }

        return SpriteSheet(frameWidth: frameWidth, frameHeight: frameHeight, frameCount: frameCount,
                           columns: columns, rows: rows,
                           surfaceWidth: surfaceWidth, surfaceHeight: surfaceHeight,
                           rgba: [UInt8](raw))
    }

    // MARK: - Housekeeping

    /// Delete sibling fingerprint directories (previous data sets / plug-in
    /// configurations) so the cache doesn't grow without bound as the player
    /// toggles plug-ins. Best-effort and silent.
    private static func pruneStaleFingerprints(under root: URL, keeping current: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles]) else { return }
        for entry in entries where entry.lastPathComponent != current {
            try? fm.removeItem(at: entry)
        }
    }
}
