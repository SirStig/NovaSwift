import XCTest
import Foundation
@testable import NovaSwiftKit

final class EditingGraphicsTests: XCTestCase {

    // MARK: helpers

    /// data/EV Nova/Nova Files relative to the repo root; nil (skip) when absent.
    static func realRez(_ names: [String]) -> ResourceCollection? {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let dir = url.appendingPathComponent("data/EV Nova/Nova Files")
        var all = ResourceCollection()
        var any = false
        for n in names {
            if let c = try? ResourceFile.read(contentsOf: dir.appendingPathComponent(n)) { all.overlay(c); any = true }
        }
        return any ? all : nil
    }

    /// Deterministic xorshift.
    struct RNG { var s: UInt64 = 0x9E3779B97F4A7C15
        mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s } }

    /// Frames with runs, odd-length literals, transparent edges, an empty row, a fully
    /// opaque row and noise; already normalised to what rlëD can hold.
    func makeSheet(fw: Int, fh: Int, frames: Int) throws -> SpriteSheet {
        var rng = RNG()
        var imgs: [RGBAImage] = []
        for f in 0..<frames {
            var px = [UInt8](repeating: 0, count: fw * fh * 4)
            for y in 0..<fh {
                for x in 0..<fw {
                    let i = (y * fw + x) * 4
                    let r = rng.next()
                    var c: (UInt8, UInt8, UInt8, UInt8)
                    switch y % 6 {
                    case 0: c = (0, 0, 0, 0)                                    // empty row
                    case 1: c = (200, UInt8(f * 7), 30, 255)                    // fully opaque flat row
                    case 2: c = x % 5 == 0 ? (0, 0, 0, 0) : (UInt8(r & 255), UInt8(r >> 8 & 255), UInt8(r >> 16 & 255), 255)
                    case 3: c = (x < 3 || x >= fw - 2) ? (0, 0, 0, 0) : (10, 20, 30, 255)   // edge transparency + run
                    case 4: c = ((x / 3) % 2 == 0) ? (255, 255, 255, 255) : (0, 0, 0, 255)  // short runs, opaque black
                    default: c = (UInt8(r & 255), 0, UInt8(r >> 8 & 255), (r >> 20) & 1 == 0 ? 255 : 0)
                    }
                    px[i] = c.0; px[i + 1] = c.1; px[i + 2] = c.2; px[i + 3] = c.3
                }
            }
            imgs.append(try RGBAImage(width: fw, height: fh, rgba: px))
        }
        return try SpriteImport.fromFrames(imgs)
    }

    func assertSame(_ a: SpriteSheet, _ b: SpriteSheet, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.frameWidth, b.frameWidth, msg, file: file, line: line)
        XCTAssertEqual(a.frameHeight, b.frameHeight, msg, file: file, line: line)
        XCTAssertEqual(a.frameCount, b.frameCount, msg, file: file, line: line)
        XCTAssertEqual(a.surfaceWidth, b.surfaceWidth, msg, file: file, line: line)
        XCTAssertTrue(a.rgba == b.rgba, "pixels differ \(msg)", file: file, line: line)
    }

    // MARK: rlëD

    func testColorQuantisationInvertsExpansion() {
        for v in UInt16(0)...31 { XCTAssertEqual(GfxColor.to5(GfxColor.from5(v)), v) }
    }

    func testRLEDSyntheticRoundTrip() throws {
        for (w, h, n) in [(1, 1, 1), (2, 7, 1), (13, 12, 3), (31, 25, 7), (64, 64, 13), (200, 30, 6)] {
            let sheet = try makeSheet(fw: w, fh: h, frames: n)
            let data = try RLEDEncoder.encode(sheet)
            let back = try RLED.decode(data)
            assertSame(sheet, back, "\(w)x\(h)x\(n)")
        }
    }

    func testRLEDBlankAndOpaqueFrames() throws {
        let blank = try SpriteImport.fromFrames([RGBAImage(width: 5, height: 4, rgba: [UInt8](repeating: 0, count: 80))])
        assertSame(blank, try RLED.decode(RLEDEncoder.encode(blank)))
        let solid = try SpriteImport.fromFrames([RGBAImage(width: 9, height: 3, rgba: [UInt8](repeating: 255, count: 108))])
        let d = try RLEDEncoder.encode(solid)
        assertSame(solid, try RLED.decode(d))
        XCTAssertLessThan(d.count, 16 + 3 * (4 + 4 + 20) + 4, "flat rows use repeat runs")
    }

    func testRLEDRejectsBadInput() {
        XCTAssertThrowsError(try RLEDEncoder.encode(rgba: [0, 0, 0], surfaceWidth: 1, surfaceHeight: 1,
                                                    frameWidth: 1, frameHeight: 1, frameCount: 1))
        XCTAssertThrowsError(try RLEDEncoder.encode(rgba: [], surfaceWidth: 0, surfaceHeight: 0,
                                                    frameWidth: 0, frameHeight: 0, frameCount: 1))
    }

    func testRLEDRealDataRoundTrip() throws {
        guard let c = Self.realRez(["Nova Ships 1.rez", "Nova Ships 2.rez", "Nova Graphics 1.rez", "Nova Graphics 2.rez"]) else {
            throw XCTSkip("data/EV Nova not present")
        }
        let all = c.resources(of: NovaType.rleD)
        try XCTSkipIf(all.isEmpty)
        let start = Date()
        var checked = 0, origBytes = 0, newBytes = 0
        for r in all {
            if Date().timeIntervalSince(start) > 12 { break }
            guard let sheet = try? RLED.decode(r.data) else { continue }
            let enc = try RLEDEncoder.encode(sheet)
            let back = try RLED.decode(enc)
            XCTAssertTrue(back.rgba == sheet.rgba && back.frameCount == sheet.frameCount, "rlëD #\(r.id)")
            checked += 1; origBytes += r.data.count; newBytes += enc.count
        }
        XCTAssertGreaterThan(checked, 20)
        print("RLED real round-trip: \(checked)/\(all.count) sprites, original \(origBytes) B -> encoded \(newBytes) B")
    }

    // MARK: PICT

    func noiseImage(_ w: Int, _ h: Int, flatRows: Bool = true) -> [UInt8] {
        var rng = RNG(s: UInt64(w * 1000 + h))
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            if flatRows && y % 3 == 0 { px[i] = 12; px[i + 1] = 200; px[i + 2] = 99 } else {
                let r = rng.next(); px[i] = UInt8(r & 255); px[i + 1] = UInt8(r >> 8 & 255); px[i + 2] = UInt8(r >> 16 & 255)
            }
        } }
        return px
    }

    func testPICT32RoundTripLossless() throws {
        for (w, h) in [(2, 1), (3, 5), (8, 8), (61, 7), (62, 3), (63, 3), (130, 20), (300, 9)] {
            let px = noiseImage(w, h)
            let data = try PICTEncoder.encode(rgba: px, width: w, height: h, depth: .bits32)
            let back = try PICT.decode(data)
            XCTAssertEqual(back.surfaceWidth, w); XCTAssertEqual(back.surfaceHeight, h)
            XCTAssertTrue(back.rgba == px, "\(w)x\(h)")
            XCTAssertEqual(data.count & 1, 0)
            XCTAssertEqual(Int(data[0]) << 8 | Int(data[1]), data.count & 0xFFFF)
        }
    }

    func testPICT16RoundTripQuantised() throws {
        for (w, h) in [(1, 4), (2, 2), (3, 3), (4, 4), (50, 6), (126, 4), (300, 9)] {
            var px = noiseImage(w, h)
            let data = try PICTEncoder.encode(rgba: px, width: w, height: h, depth: .bits16)
            for i in stride(from: 0, to: px.count, by: 4) {
                for k in 0..<3 { px[i + k] = GfxColor.from5(GfxColor.to5(px[i + k])) }
            }
            let back = try PICT.decode(data)
            XCTAssertTrue(back.rgba == px, "\(w)x\(h)")
        }
    }

    func testPICTWidthOne32FallsBackToSixteenBit() throws {
        let px: [UInt8] = [247, 0, 8, 255, 0, 247, 0, 255]
        let back = try PICT.decode(PICTEncoder.encode(rgba: px, width: 1, height: 2))
        XCTAssertEqual(back.rgba, px)
    }

    func testPICTSpritePairSlicesBack() throws {
        let sheet = try makeSheet(fw: 20, fh: 18, frames: 8)
        let pair = try PICTEncoder.encodeSpritePair(sheet)
        XCTAssertEqual(pair.tilesAcross, 6); XCTAssertEqual(pair.tilesDown, 2)
        let img = try PICT.decode(pair.image), mask = try PICT.decode(pair.mask)
        let cut = try PICTSpriteSheet.slice(image: img, mask: mask, frameWidth: 20, frameHeight: 18,
                                            frameCount: pair.tilesAcross * pair.tilesDown)
        // slice repacks 12 cells; the 8 real frames must match, extras are empty.
        for f in 0..<8 {
            XCTAssertTrue(cut.singleFrame(f)!.rgba == sheet.singleFrame(f)!.rgba, "frame \(f)")
        }
        for f in 8..<12 { XCTAssertTrue(cut.singleFrame(f)!.rgba.allSatisfy { $0 == 0 }) }
    }

    func testPICTRealDataRoundTrip() throws {
        guard let c = Self.realRez(["Nova Graphics 1.rez", "Nova Graphics 2.rez", "Nova Graphics 3.rez", "Nova Titles 1.rez"]) else {
            throw XCTSkip("data/EV Nova not present")
        }
        let all = c.resources(of: NovaType.pict)
        try XCTSkipIf(all.isEmpty)
        let start = Date()
        var checked = 0
        for r in all where r.data.count < 600_000 {
            if Date().timeIntervalSince(start) > 10 { break }
            guard let sheet = try? PICT.decode(r.data) else { continue }
            let back = try PICT.decode(PICTEncoder.encode(sheet))
            XCTAssertTrue(back.rgba == sheet.rgba, "PICT #\(r.id)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 10)
        print("PICT real round-trip: \(checked)/\(all.count)")
    }

    // MARK: cicn

    func testCICNRoundTrip() throws {
        var px = [UInt8](repeating: 0, count: 12 * 12 * 4)
        for y in 0..<12 { for x in 0..<12 where (x + y) % 5 != 0 {
            let i = (y * 12 + x) * 4
            px[i] = UInt8(x * 20); px[i + 1] = UInt8(y * 20); px[i + 2] = 77; px[i + 3] = 255
        } }
        let back = try CICN.decode(CICNEncoder.encode(rgba: px, width: 12, height: 12))
        XCTAssertEqual(back.frameWidth, 12)
        XCTAssertTrue(back.rgba == px)
    }

    func testCICNNonSquareRoundTrip() throws {
        let w = 20, h = 7
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w where (x * 3 + y) % 4 != 0 {
            let i = (y * w + x) * 4
            px[i] = UInt8(x * 12); px[i + 1] = UInt8(y * 30); px[i + 2] = 40; px[i + 3] = 255
        } }
        let back = try CICN.decode(CICNEncoder.encode(rgba: px, width: w, height: h))
        XCTAssertEqual(back.frameWidth, w)
        XCTAssertEqual(back.frameHeight, h)
        XCTAssertTrue(back.rgba == px)
    }

    func testCICNReducesToTwoFiftySixColours() throws {
        var rng = RNG()
        var px = [UInt8](repeating: 255, count: 16 * 16 * 4)
        for i in 0..<(16 * 16) { let r = rng.next(); px[i * 4] = UInt8(r & 255); px[i * 4 + 1] = UInt8(r >> 8 & 255); px[i * 4 + 2] = UInt8(r >> 16 & 255) }
        let back = try CICN.decode(CICNEncoder.encode(rgba: px, width: 16, height: 16))
        XCTAssertTrue(back.rgba.enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 255 })
        for i in 0..<(16 * 16 * 4) where i % 4 != 3 { XCTAssertLessThan(abs(Int(back.rgba[i]) - Int(px[i])), 16) }
    }

    func testCICNRealDataRoundTrip() throws {
        guard let c = Self.realRez(["Nova Graphics 1.rez", "Nova Graphics 2.rez", "Nova Graphics 3.rez", "Nova Data 1.rez"]) else {
            throw XCTSkip("data/EV Nova not present")
        }
        var checked = 0
        for r in c.resources(of: NovaType.cicn) {
            guard let s = try? CICN.decode(r.data) else { continue }
            let back = try CICN.decode(CICNEncoder.encode(s))
            XCTAssertTrue(back.rgba == s.rgba, "cicn #\(r.id)")
            checked += 1
        }
        print("cicn real round-trip: \(checked)")
    }

    // MARK: sprite import

    func testGridAndFrameImportAgree() throws {
        // 2x2 grid of 4x4 frames, distinct colours.
        var px = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let cols: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)]
        for y in 0..<8 { for x in 0..<8 {
            let c = cols[(y / 4) * 2 + x / 4]; let i = (y * 8 + x) * 4
            px[i] = c.0; px[i + 1] = c.1; px[i + 2] = c.2; px[i + 3] = 255
        } }
        let grid = try SpriteImport.fromGrid(RGBAImage(width: 8, height: 8, rgba: px), frameWidth: 4, frameHeight: 4)
        XCTAssertEqual(grid.frameCount, 4)
        let frames = try (0..<4).map { f -> RGBAImage in
            var p = [UInt8](repeating: 0, count: 64)
            for i in 0..<16 { p[i * 4] = cols[f].0; p[i * 4 + 1] = cols[f].1; p[i * 4 + 2] = cols[f].2; p[i * 4 + 3] = 255 }
            return try RGBAImage(width: 4, height: 4, rgba: p)
        }
        assertSame(grid, try SpriteImport.fromFrames(frames))
        XCTAssertThrowsError(try SpriteImport.fromGrid(RGBAImage(width: 8, height: 8, rgba: px), frameWidth: 9, frameHeight: 4))
    }

    func testAlphaThresholdAndClearing() throws {
        let img = try RGBAImage(width: 2, height: 1, rgba: [200, 100, 50, 127, 200, 100, 50, 128])
        let s = try SpriteImport.singleFrame(img)
        XCTAssertEqual(Array(s.rgba[0..<4]), [0, 0, 0, 0])
        XCTAssertEqual(s.rgba[7], 255)
    }

    func testRotationConvention() throws {
        // A 9x9 image with an opaque 3x3 blob at the top centre (the "nose").
        var px = [UInt8](repeating: 0, count: 9 * 9 * 4)
        for y in 0..<3 { for x in 3..<6 { let i = (y * 9 + x) * 4; px[i] = 255; px[i + 3] = 255 } }
        let s = try SpriteImport.rotated(RGBAImage(width: 9, height: 9, rgba: px), frames: 36, frameSize: 21)
        XCTAssertEqual(s.frameCount, 36); XCTAssertEqual(s.columns, 6); XCTAssertEqual(s.rows, 6)
        func centroid(_ f: Int) -> (Double, Double) {
            let fr = s.singleFrame(f)!; var sx = 0.0, sy = 0.0, n = 0.0
            for y in 0..<21 { for x in 0..<21 where fr.rgba[(y * 21 + x) * 4 + 3] != 0 { sx += Double(x) - 10; sy += Double(y) - 10; n += 1 } }
            return (sx / n, sy / n)
        }
        let f0 = centroid(0), f9 = centroid(9), f18 = centroid(18), f27 = centroid(27)
        XCTAssertLessThan(f0.1, -2); XCTAssertEqual(f0.0, 0, accuracy: 0.6)      // up
        XCTAssertGreaterThan(f9.0, 2); XCTAssertEqual(f9.1, 0, accuracy: 0.6)    // 90 deg clockwise: right
        XCTAssertGreaterThan(f18.1, 2)                                            // down
        XCTAssertLessThan(f27.0, -2)                                              // left
        // And it encodes.
        assertSame(s, try RLED.decode(RLEDEncoder.encode(s)))
    }

    #if canImport(CoreGraphics)
    func testCGImageBridge() throws {
        let px: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 0, 0, 0, 255, 255, 9, 9, 9, 255]
        let img = try RGBAImage(width: 2, height: 2, rgba: px)
        let cg = try XCTUnwrap(img.makeCGImage())
        let back = try RGBAImage(cgImage: cg)
        XCTAssertEqual(back.rgba[0..<4].map { $0 }, [255, 0, 0, 255])
        XCTAssertEqual(back.rgba[11], 255)
        let sheet = try SpriteImport.fromGrid(cg, frameWidth: 1, frameHeight: 1)
        XCTAssertEqual(sheet.frameCount, 4)
        let png = try XCTUnwrap(sheet.pngData())
        XCTAssertEqual(try RGBAImage(imageData: png).width, sheet.surfaceWidth)
    }
    #endif

    // MARK: spïn

    func testSpinRecordMatchesDecoder() throws {
        let sheet = try makeSheet(fw: 30, fh: 28, frames: 36)
        let res = SpinBuilder.resource(id: 777, spriteID: 5000, sheet: sheet)
        XCTAssertEqual(res.data.count, 12)
        let spin = SpinRes(res)
        XCTAssertEqual([spin.spriteID, spin.maskID, spin.tileWidth, spin.tileHeight, spin.tilesAcross, spin.tilesDown],
                       [5000, 5001, 30, 28, 6, 6])
        let rs = try SpinBuilder.rleSprite(spinID: 777, spriteID: 5000, sheet: sheet)
        XCTAssertEqual(rs.map(\.type), [NovaType.rleD, NovaType.spin])
        let pr = try SpinBuilder.pictSprite(spinID: 778, spriteID: 5100, maskID: 5101, sheet: sheet)
        XCTAssertEqual(pr.map(\.type), [NovaType.pict, NovaType.pict, NovaType.spin])
        XCTAssertThrowsError(try SpinBuilder.pictSprite(spinID: 1, spriteID: 9, maskID: 9, sheet: sheet))
    }

    // MARK: snd

    func testSndRoundTrip16And8() throws {
        let n = 2205
        let samples = (0..<n).map { Float(sin(Double($0) * 0.05)) * 0.8 }
        let audio = PCMAudio(sampleRate: 22050, samples: samples)
        for (bits, tol) in [(SoundImport.BitDepth.sixteen, Float(0.0005)), (.eight, Float(0.01))] {
            let d = try SoundImport.makeSnd(audio, bits: bits)
            let back = try SndDecoder.decode(d)
            XCTAssertEqual(back.sampleRate, 22050, accuracy: 0.01)
            XCTAssertEqual(back.samples.count, n)
            for i in 0..<n { XCTAssertEqual(back.samples[i], samples[i], accuracy: tol) }
        }
    }

    func testWAVImportResamplesAndDownmixes() throws {
        // stereo 16-bit 44100 Hz WAV, 4410 frames of L=+0.5, R=-0.5 plus a DC L=R=0.25 section
        var wav = [UInt8]()
        func u32(_ v: Int) { wav += [UInt8(v & 255), UInt8(v >> 8 & 255), UInt8(v >> 16 & 255), UInt8(v >> 24 & 255)] }
        func u16(_ v: Int) { wav += [UInt8(v & 255), UInt8(v >> 8 & 255)] }
        let frames = 4410
        wav += Array("RIFF".utf8); u32(36 + frames * 4); wav += Array("WAVEfmt ".utf8); u32(16)
        u16(1); u16(2); u32(44100); u32(44100 * 4); u16(4); u16(16)
        wav += Array("data".utf8); u32(frames * 4)
        for f in 0..<frames {
            let l: Int16 = f < 2205 ? 16384 : 8192, r: Int16 = f < 2205 ? -16384 : 8192
            u16(Int(UInt16(bitPattern: l))); u16(Int(UInt16(bitPattern: r)))
        }
        let parsed = try SoundImport.parseWAV(Data(wav))
        XCTAssertEqual(parsed.sampleRate, 44100); XCTAssertEqual(parsed.samples.count, frames)
        XCTAssertEqual(parsed.samples[0], 0, accuracy: 0.001)
        XCTAssertEqual(parsed.samples[3000], 0.25, accuracy: 0.001)
        let snd = try SoundImport.makeSnd(wav: Data(wav), bits: .sixteen, sampleRate: 22050)
        let back = try SndDecoder.decode(snd)
        XCTAssertEqual(back.sampleRate, 22050, accuracy: 0.01)
        XCTAssertEqual(back.samples.count, 2205, accuracy: 1)
        XCTAssertEqual(back.samples[1500], 0.25, accuracy: 0.002)
    }

    func testExtended80RoundTrip() {
        for r in [8000.0, 11025, 22050, 22254.5454, 44100, 48000] {
            XCTAssertEqual(SoundImport.decodeExtended80(SoundImport.extended80(r)), r, accuracy: 1e-6)
        }
        XCTAssertEqual(SoundImport.extended80(44100), [0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0])
    }

    func testAIFFImport() throws {
        var b = [UInt8]()
        func be32(_ v: Int) { b.appendBE32(v) }
        let samples: [Int16] = [0, 16384, -16384, 32767]
        b += Array("FORM".utf8); be32(4 + 8 + 18 + 8 + 8 + samples.count * 2); b += Array("AIFF".utf8)
        b += Array("COMM".utf8); be32(18); b.appendBE16(1); be32(samples.count); b.appendBE16(16)
        b += SoundImport.extended80(22050)
        b += Array("SSND".utf8); be32(8 + samples.count * 2); be32(0); be32(0)
        for s in samples { b.appendBE16(Int(UInt16(bitPattern: s))) }
        let a = try SoundImport.parse(Data(b))
        XCTAssertEqual(a.sampleRate, 22050, accuracy: 1e-6)
        XCTAssertEqual(a.samples[1], 0.5, accuracy: 0.001); XCTAssertEqual(a.samples[2], -0.5, accuracy: 0.001)
    }

    func testRealSndReencodes() throws {
        guard let c = Self.realRez(["Nova Sounds.rez"]) else { throw XCTSkip("data/EV Nova not present") }
        var n = 0
        for r in c.resources(of: NovaType.snd).prefix(60) {
            guard let s = try? SndDecoder.decode(r.data), s.samples.count > 10 else { continue }
            let a = PCMAudio(sampleRate: s.sampleRate, samples: s.samples)
            let back = try SndDecoder.decode(SoundImport.makeSnd(a, bits: .sixteen))
            XCTAssertEqual(back.samples.count, s.samples.count)
            XCTAssertEqual(back.samples[s.samples.count / 2], s.samples[s.samples.count / 2], accuracy: 0.0005)
            n += 1
        }
        XCTAssertGreaterThan(n, 5)
    }

    // MARK: HD authoring

    func testHDAttachListRemove() throws {
        var c = ResourceCollection()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]), usdz = Data([0x50, 0x4B, 0x03, 0x04, 9, 9])
        let a = try HDPackAuthoring.attachSprite(png: png, spriteID: 2300, scale: 4, frameCount: 36, to: &c)
        XCTAssertEqual(a.blobID, 128)
        _ = try HDPackAuthoring.attachModel(usdz: usdz, spriteID: 1010, bake: .init(yaw: 180), to: &c)
        let sameBlob = try HDPackAuthoring.attachSprite(png: png, spriteID: 2301, to: &c)
        XCTAssertEqual(sameBlob.blobID, 128, "identical assets share a blob")
        XCTAssertEqual(c.resources(of: GraphicsEnhancementType.blob).count, 2)

        let list = HDPackAuthoring.attachments(in: c)
        XCTAssertEqual(list.map(\.spriteID), [1010, 2300, 2301])
        XCTAssertEqual(list[0].kind, .model); XCTAssertEqual(list[0].descriptor.bake?.yaw, 180)
        XCTAssertEqual(list[1].descriptor.scale, 4); XCTAssertEqual(list[1].descriptor.frameCount, 36)

        // The game's own resolver sees them.
        var cat = GraphicsEnhancementCatalog(); cat.addInFile(from: c)
        XCTAssertEqual(cat[2300]?.descriptor.kind, .sprite)
        XCTAssertEqual(cat[1010]?.source.loadData(), usdz)
        XCTAssertTrue(cat.problems.isEmpty)

        // Replacing drops the orphaned blob; shared blob survives removal of one user.
        _ = try HDPackAuthoring.attachSprite(png: Data([0x89, 0x50, 0x4E, 0x47, 7]), spriteID: 2301, to: &c)
        XCTAssertEqual(c.resources(of: GraphicsEnhancementType.blob).count, 3)
        XCTAssertTrue(HDPackAuthoring.remove(spriteID: 2301, from: &c))
        XCTAssertEqual(c.resources(of: GraphicsEnhancementType.blob).count, 2)
        XCTAssertTrue(HDPackAuthoring.remove(spriteID: 2300, from: &c))
        XCTAssertNil(c.resource(GraphicsEnhancementType.blob, 128))
        XCTAssertFalse(HDPackAuthoring.remove(spriteID: 2300, from: &c))
    }

    func testHDRejectsBadAssetsAndResolvesResources() throws {
        var c = ResourceCollection()
        XCTAssertThrowsError(try HDPackAuthoring.attachSprite(png: Data([1, 2, 3]), spriteID: 1, to: &c))
        XCTAssertThrowsError(try HDPackAuthoring.attachModel(usdz: Data([1, 2, 3]), spriteID: 1, to: &c))
        XCTAssertThrowsError(try HDPackAuthoring.attachSprite(png: Data([0x89, 0x50, 0x4E, 0x47]), spriteID: 40000, to: &c))
        c.add(SpinBuilder.resource(id: 3100, spriteID: 4242, maskID: 4243, tileWidth: 8, tileHeight: 8, tilesAcross: 6, tilesDown: 6))
        XCTAssertEqual(HDPackAuthoring.spriteID(forType: NovaType.spin, id: 3100, in: c), 4242)
        XCTAssertEqual(HDPackAuthoring.spriteID(forType: NovaType.rleD, id: 9, in: c), 9)
        XCTAssertNil(HDPackAuthoring.spriteID(forType: NovaType.spin, id: 1, in: c))
        _ = try HDPackAuthoring.attachSprite(png: Data([0x89, 0x50, 0x4E, 0x47]), toResource: NovaType.spin, id: 3100, in: &c)
        XCTAssertNotNil(c.resource(GraphicsEnhancementType.descriptor, 4242))
    }

    func testHDExportsAsPack() throws {
        var c = ResourceCollection()
        _ = try HDPackAuthoring.attachSprite(png: Data([0x89, 0x50, 0x4E, 0x47, 5]), spriteID: 77, to: &c)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hd-\(UUID().uuidString).nsx")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(try HDPackAuthoring.exportPack(from: c, to: dir), 1)
        var round = ResourceCollection()
        XCTAssertEqual(try GraphicsPackEmbedding.embed(pack: dir, into: round).resources(of: GraphicsEnhancementType.descriptor).count, 1)
        round = try GraphicsPackEmbedding.embed(pack: dir, into: round)
        XCTAssertEqual(HDPackAuthoring.attachments(in: round).first?.spriteID, 77)
    }
}
