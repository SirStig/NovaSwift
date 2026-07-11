import Foundation

/// A decoded EV Nova sound: mono PCM as normalized floats in [-1, 1], plus its
/// native sample rate. Ready to hand to an audio engine (fill an
/// `AVAudioPCMBuffer`) or write out as a WAV.
///
/// EV Nova stores audio in classic Mac `snd ` resources. In practice the game
/// only ever uses two sample encodings — raw 8-bit unsigned PCM and IMA-4 (ADPCM)
/// compression — wrapped in a "sampled sound" header behind a single immediate
/// `bufferCmd`. This decoder handles exactly those, matching NovaJS
/// `SndResource.ts` and the classic Sound Manager layout. See docs/DATA_FORMAT.md.
public struct NovaSound {
    /// Native sample rate in Hz (e.g. 11025, 22050).
    public let sampleRate: Double
    /// Mono samples, normalized to roughly [-1, 1].
    public let samples: [Float]

    public var frameCount: Int { samples.count }
    public var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
}

/// Decoder for the classic Macintosh `snd ` (sampled sound) resource, restricted
/// to the two encodings EV Nova actually ships.
public enum SndDecoder {
    // Sound Manager command ids we care about.
    private static let bufferCmd: UInt16 = 81

    /// Sampled-sound header encodings.
    private static let stdEncoding: UInt8 = 0x00      // standard header (8-bit PCM)
    private static let extEncoding: UInt8 = 0xFF      // extended header
    private static let cmpEncoding: UInt8 = 0xFE      // compressed header (IMA-4 etc.)

    public enum Error: Swift.Error, CustomStringConvertible {
        case badFormat(UInt16)
        case unsupportedCommand
        case nonImmediateSample
        case unsupportedEncoding(UInt8)
        case unsupportedCompression(String)

        public var description: String {
            switch self {
            case .badFormat(let f): return "unknown snd format \(f)"
            case .unsupportedCommand: return "snd has no immediate buffer command"
            case .nonImmediateSample: return "snd uses a non-immediate sample pointer"
            case .unsupportedEncoding(let e): return "snd sample encoding 0x\(String(e, radix: 16)) unsupported"
            case .unsupportedCompression(let f): return "snd compression '\(f)' unsupported (only ima4)"
            }
        }
    }

    /// Decode a `snd ` resource body into a `NovaSound`.
    public static func decode(_ data: Data) throws -> NovaSound {
        let r = BinaryReader(data, bigEndian: true)

        // --- 'snd ' resource header + command list -------------------------
        let format = try r.readU16()
        switch format {
        case 1:
            let numDataFormats = try r.readU16()
            if numDataFormats != 0 {
                _ = try r.readU16()   // firstDataFormatID
                _ = try r.readU32()   // initialization options
            }
        case 2:
            _ = try r.readU16()       // reference count (ignored)
        default:
            throw Error.badFormat(format)
        }

        let numCommands = try r.readU16()
        // We only support the standard "one immediate bufferCmd" layout Nova emits.
        guard numCommands >= 1 else { throw Error.unsupportedCommand }
        var sampleOffset: Int? = nil
        for _ in 0..<numCommands {
            var cmd = try r.readU16()
            _ = try r.readU16()               // param1
            let param2 = try r.readU32()      // param2 (offset to sound header when dataOffsetBit set)
            let hasOffset = (cmd & 0x8000) != 0
            cmd &= 0x7FFF
            if cmd == bufferCmd && hasOffset { sampleOffset = Int(param2) }
        }
        guard let headerOffset = sampleOffset else { throw Error.unsupportedCommand }

        // --- Sampled Sound Header -----------------------------------------
        try r.seek(headerOffset)
        let samplePtr = try r.readU32()
        guard samplePtr == 0 else { throw Error.nonImmediateSample }  // must be immediate

        var length = Int(try r.readU32())            // #samples (std) or #channels (ext/cmp)
        let sampleRate = Double(try r.readU32()) / 65536.0
        _ = try r.readU32()                          // loopStart
        _ = try r.readU32()                          // loopEnd
        let encoding = try r.readU8()
        _ = try r.readU8()                           // baseFrequency

        switch encoding {
        case stdEncoding:
            // `length` samples of unsigned 8-bit PCM follow immediately.
            var out = [Float](); out.reserveCapacity(length)
            for _ in 0..<length {
                let b = try r.readU8()
                out.append((Float(b) - 127.5) / 127.5)
            }
            return NovaSound(sampleRate: sampleRate > 0 ? sampleRate : 22050, samples: out)

        case extEncoding, cmpEncoding:
            // For the extended/compressed headers the earlier field was the channel
            // count; the real frame count is the next u32.
            let channels = max(1, length)
            length = Int(try r.readU32())            // number of frames
            try r.advance(10)                        // AIFF sample rate (80-bit extended)
            _ = try r.readU32()                      // markerChunk

            if encoding == extEncoding {
                _ = try r.readU32()                  // instrumentChunk
                _ = try r.readU32()                  // AESRecording
                let sampleSize = Int(try r.readI16())
                try r.advance(14)                    // future1(2) + future2..4 (12)
                let out = try readUncompressed(r, frames: length, channels: channels, bits: sampleSize)
                return NovaSound(sampleRate: sampleRate > 0 ? sampleRate : 22050, samples: out)
            } else {
                var fmt = ""
                for _ in 0..<4 { fmt.append(Character(UnicodeScalar(try r.readU8()))) }
                _ = try r.readU32()                  // future2
                _ = try r.readU32()                  // stateVars
                _ = try r.readU32()                  // leftOverSamples
                _ = try r.readI16()                  // compressionID
                _ = try r.readI16()                  // packetSize
                _ = try r.readI16()                  // snthID
                _ = try r.readI16()                  // sampleSize
                guard fmt == "ima4" else { throw Error.unsupportedCompression(fmt) }
                let out = try readIMA4(r, packets: length * channels)
                return NovaSound(sampleRate: sampleRate > 0 ? sampleRate : 22050, samples: out)
            }

        default:
            throw Error.unsupportedEncoding(encoding)
        }
    }

    // MARK: Uncompressed extended-header PCM (8- or 16-bit)

    private static func readUncompressed(_ r: BinaryReader, frames: Int, channels: Int, bits: Int) throws -> [Float] {
        let total = frames * max(1, channels)
        var out = [Float](); out.reserveCapacity(frames)
        if bits <= 8 {
            for i in 0..<total where i % channels == 0 {   // take first channel
                let b = try r.readU8()
                out.append((Float(b) - 127.5) / 127.5)
            }
        } else {
            for i in 0..<total {
                let s = Int(try r.readI16())
                if i % channels == 0 { out.append(Float(s) / 32768.0) }
            }
        }
        return out
    }

    // MARK: IMA-4 (ADPCM) decode — 34-byte packets → 64 samples each

    private static let imaIndexTable: [Int] = [
        -1, -1, -1, -1, 2, 4, 6, 8,
        -1, -1, -1, -1, 2, 4, 6, 8,
    ]
    private static let imaStepTable: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
        19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
        130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
        337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
        5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    ]

    @inline(__always) private static func signMag(_ v: Int) -> Double {
        return ((v >> 3) != 0 ? -1.0 : 1.0) * (Double(v & 7) + 0.5)
    }

    private static func readIMA4(_ r: BinaryReader, packets: Int) throws -> [Float] {
        var out = [Float](); out.reserveCapacity(packets * 64)
        for _ in 0..<packets {
            // 2-byte preamble: predictor (top 9 bits) + step index (low 7 bits).
            let c = Int(try r.readI16())
            var si = c & 0x7F
            var predictor = Double(c - si)
            if si > 88 { si = 88 }
            var step = imaStepTable[si]
            for _ in 0..<32 {                     // 32 bytes → 64 nibbles
                let b = Int(try r.readU8())
                for ni in 0..<2 {
                    let v = ni == 1 ? (b >> 4) : (b & 0x0F)
                    si += imaIndexTable[v]
                    if si > 88 { si = 88 } else if si < 0 { si = 0 }
                    predictor += signMag(v) * Double(step) / 4.0
                    out.append(Float(predictor / 32768.0))
                    step = imaStepTable[si]
                }
            }
        }
        return out
    }
}

// MARK: - WAV export (for the CLI / debugging)

public extension NovaSound {
    /// Encode as a 16-bit mono PCM WAV file.
    func wavData() -> Data {
        let rate = UInt32(sampleRate.rounded())
        let pcm: [Int16] = samples.map { Int16(max(-1, min(1, $0)) * 32767) }
        let dataBytes = pcm.count * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        pcm.forEach { u16(UInt16(bitPattern: $0)) }
        return d
    }
}
