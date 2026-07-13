import XCTest
import Foundation
@testable import NovaSwiftKit

final class SpriteDiskCacheTests: XCTestCase {

    /// A small but real decoded sheet to round-trip, built from the same minimal
    /// rlëD the RLED tests use (2×2, four solid colours).
    private func sampleSheet() throws -> SpriteSheet {
        var bytes: [UInt8] = []
        func be16(_ v: Int) { bytes += [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func token(_ op: UInt8, _ count: Int) {
            bytes += [op, UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]
        }
        be16(2); be16(2); be16(16); be16(0); be16(1)
        bytes += [UInt8](repeating: 0, count: 6)
        token(0x01, 0); token(0x02, 4); bytes += [0x7C, 0x00, 0x00, 0x1F] // red, blue
        token(0x01, 0); token(0x02, 4); bytes += [0x03, 0xE0, 0x7F, 0xFF] // green, white
        token(0x00, 0)
        return try RLED.decode(Data(bytes))
    }

    /// A cache rooted at a unique subdirectory so tests never prune each other's
    /// entries or touch the app's real cache.
    private func makeCache() throws -> SpriteDiskCache {
        let sub = "NovaSwiftTests/\(UUID().uuidString)"
        return try XCTUnwrap(SpriteDiskCache(fingerprint: "fp", subdirectory: sub),
                             "cache dir should be creatable")
    }

    func testStoreThenLoadReturnsIdenticalSheet() throws {
        let original = try sampleSheet()
        let cache = try makeCache()

        XCTAssertNil(cache.load(42), "cold cache should miss")

        cache.store(42, original)
        let loaded = try XCTUnwrap(cache.load(42), "warm cache should hit")

        XCTAssertEqual(loaded.frameWidth, original.frameWidth)
        XCTAssertEqual(loaded.frameHeight, original.frameHeight)
        XCTAssertEqual(loaded.frameCount, original.frameCount)
        XCTAssertEqual(loaded.columns, original.columns)
        XCTAssertEqual(loaded.rows, original.rows)
        XCTAssertEqual(loaded.surfaceWidth, original.surfaceWidth)
        XCTAssertEqual(loaded.surfaceHeight, original.surfaceHeight)
        XCTAssertEqual(loaded.rgba, original.rgba, "decoded pixels must survive the LZFSE round-trip byte-for-byte")
    }

    func testMissReturnsNil() throws {
        let cache = try makeCache()
        XCTAssertNil(cache.load(999))
    }

    /// A different fingerprint is a different directory, so a store under one is
    /// invisible under the other — this is what makes a stale cache simply not
    /// get read after the data set changes.
    func testDifferentFingerprintDoesNotSeeEntries() throws {
        let sub = "NovaSwiftTests/\(UUID().uuidString)"
        let a = try XCTUnwrap(SpriteDiskCache(fingerprint: "aaa", subdirectory: sub))
        a.store(1, try sampleSheet())
        // Same root, different fingerprint. (Creating it prunes "aaa" — that's the
        // intended eviction of the previous data set's cache.)
        let b = try XCTUnwrap(SpriteDiskCache(fingerprint: "bbb", subdirectory: sub))
        XCTAssertNil(b.load(1), "a different data-set fingerprint must not read stale entries")
    }
}
