import XCTest
@testable import NovaSwiftKit

final class SoundResourceTests: XCTestCase {

    /// Build a minimal `snd ` (format 1, one immediate bufferCmd, standard 8-bit
    /// PCM header) wrapping the given unsigned-8-bit samples at `rate` Hz.
    private func makeSnd(rate: Int, pcm: [UInt8]) -> Data {
        var d = Data()
        func u16(_ v: Int) { d.append(UInt8((v >> 8) & 0xFF)); d.append(UInt8(v & 0xFF)) }
        func u32(_ v: UInt32) {
            d.append(UInt8((v >> 24) & 0xFF)); d.append(UInt8((v >> 16) & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF));  d.append(UInt8(v & 0xFF))
        }
        // Resource header + command list.
        u16(1)                       // format 1
        u16(0)                       // numberOfDataFormats = 0
        u16(1)                       // numCommands = 1
        u16(0x8000 | 81)             // bufferCmd with dataOffset bit
        u16(0)                       // param1
        // Sound header begins at byte 14 (after the 8-byte command's param2 too).
        u32(14)                      // param2 = offset to sound header

        // Sampled Sound Header (standard).
        u32(0)                       // samplePtr = 0 (immediate)
        u32(UInt32(pcm.count))       // length (num samples)
        u32(UInt32(rate) << 16)      // sampleRate, 16.16 fixed
        u32(0)                       // loopStart
        u32(0)                       // loopEnd
        d.append(0)                  // encoding = standard
        d.append(60)                 // baseFrequency
        d.append(contentsOf: pcm)    // sample bytes
        return d
    }

    func testDecodes8BitPCM() throws {
        let snd = makeSnd(rate: 22050, pcm: [0, 128, 255])
        let sound = try SndDecoder.decode(snd)
        XCTAssertEqual(sound.sampleRate, 22050, accuracy: 0.5)
        XCTAssertEqual(sound.samples.count, 3)
        XCTAssertEqual(sound.samples[0], -1.0, accuracy: 0.01)  // 0    → ~-1
        XCTAssertEqual(sound.samples[1],  0.0, accuracy: 0.02)  // 128  → ~0
        XCTAssertEqual(sound.samples[2],  1.0, accuracy: 0.01)  // 255  → ~+1
    }

    // MARK: D-7 the original's acceptance rules (0x004d6d30 / 0x004d6e60)

    /// A format-1 snd with `mods` modifiers, one command `cmd`, and `header`
    /// (a sampled-sound header + data) right after the command list.
    private func makeSnd(mods: Int, cmd: Int, header: [UInt8]) -> Data {
        var d = Data()
        func u16(_ v: Int) { d.append(UInt8((v >> 8) & 0xFF)); d.append(UInt8(v & 0xFF)) }
        func u32(_ v: Int) { u16(v >> 16); u16(v & 0xFFFF) }
        u16(1); u16(mods)
        for _ in 0..<mods { u16(5); u32(0) }
        u16(1); u16(cmd); u16(0)
        u32(d.count + 4)
        d.append(contentsOf: header)
        return d
    }

    private func header(encoding: UInt8, channels: Int = 1, rate: Int = 11025,
                        format: String = "NONE", sampleSize: Int = 8, data: [UInt8]) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: encoding == 0 ? 0x16 : 0x40)
        func put32(_ at: Int, _ v: Int) { for i in 0..<4 { h[at + i] = UInt8((v >> (24 - 8 * i)) & 0xFF) } }
        put32(4, encoding == 0 ? 999_999 : channels)     // std: a bogus length, ignored
        put32(8, rate << 16)
        h[0x14] = encoding
        if encoding == 0xFF { h[0x30] = UInt8(sampleSize >> 8); h[0x31] = UInt8(sampleSize & 0xFF) }
        if encoding == 0xFE {
            for (i, c) in format.utf8.enumerated() { h[0x28 + i] = c }
            h[0x3E] = UInt8(sampleSize >> 8); h[0x3F] = UInt8(sampleSize & 0xFF)
        }
        return h + data
    }

    func testSoundCmdAndSeveralModifiersAreAccepted() throws {
        let snd = makeSnd(mods: 2, cmd: 0x8050, header: header(encoding: 0, data: [0, 128, 255, 128]))
        let s = try SndDecoder.decode(snd)
        XCTAssertEqual(s.samples.count, 4, "length field ignored: bytes to the end of the resource")
        XCTAssertEqual(s.sampleRate, 11025, accuracy: 0.5)
    }

    func testMultiChannelSoundsPlayNothing() {
        let ext = makeSnd(mods: 0, cmd: 0x8051, header: header(encoding: 0xFF, channels: 2, data: [1, 2, 3, 4]))
        XCTAssertThrowsError(try SndDecoder.decode(ext))
        let cmp = makeSnd(mods: 0, cmd: 0x8051, header: header(encoding: 0xFE, channels: 2, format: "ima4", data: []))
        XCTAssertThrowsError(try SndDecoder.decode(cmp))
    }

    func testCompressedHeaderMarkedNoneIsPlainPCM() throws {
        let snd = makeSnd(mods: 0, cmd: 0x8051,
                          header: header(encoding: 0xFE, format: "NONE", sampleSize: 16, data: [0x40, 0x00, 0xC0, 0x00]))
        let s = try SndDecoder.decode(snd)
        XCTAssertEqual(s.samples, [0.5, -0.5])
        let mace = makeSnd(mods: 0, cmd: 0x8051, header: header(encoding: 0xFE, format: "MAC3", data: [0, 0]))
        XCTAssertThrowsError(try SndDecoder.decode(mace), "other codecs are rejected")
    }

    func testExtendedSixteenBitAndOddTrailingByte() throws {
        let snd = makeSnd(mods: 0, cmd: 0x8051,
                          header: header(encoding: 0xFF, sampleSize: 16, data: [0x40, 0x00, 0x7F]))
        XCTAssertEqual(try SndDecoder.decode(snd).samples, [0.5], "a short tail never fails the decode")
    }

    func testRejectsUnknownFormat() {
        var d = Data([0x00, 0x09])   // format 9
        d.append(contentsOf: [0, 0, 0, 0])
        XCTAssertThrowsError(try SndDecoder.decode(d))
    }

    func testWavRoundTripSampleCount() throws {
        let snd = makeSnd(rate: 11025, pcm: Array(repeating: 200, count: 100))
        let sound = try SndDecoder.decode(snd)
        let wav = sound.wavData()
        // 44-byte header + 2 bytes/sample.
        XCTAssertEqual(wav.count, 44 + 100 * 2)
        XCTAssertEqual(Array(wav.prefix(4)), Array("RIFF".utf8))
    }
}
