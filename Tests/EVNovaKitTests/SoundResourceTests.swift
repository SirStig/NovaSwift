import XCTest
@testable import EVNovaKit

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
