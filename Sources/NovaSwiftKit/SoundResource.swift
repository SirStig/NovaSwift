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
    private static let soundCmd: UInt16 = 80

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
        case multiChannel

        public var description: String {
            switch self {
            case .badFormat(let f): return "unknown snd format \(f)"
            case .unsupportedCommand: return "snd has no immediate buffer command"
            case .nonImmediateSample: return "snd uses a non-immediate sample pointer"
            case .unsupportedEncoding(let e): return "snd sample encoding 0x\(String(e, radix: 16)) unsupported"
            case .unsupportedCompression(let f): return "snd compression '\(f)' unsupported (only NONE/ima4)"
            case .multiChannel: return "snd has more than one channel (the original plays nothing)"
            }
        }
    }

    /// Decode a `snd ` resource body into a `NovaSound`, by the original's
    /// rules (`FUN_004d6d30` header offset, `NovaSound_DecodePayload` 0x004d6e60):
    ///
    /// - format 1 skips `numModifiers × 6` bytes, format 2 its reference count;
    ///   any other format is rejected.
    /// - The first command that is `bufferCmd` (0x8051) **or** `soundCmd`
    ///   (0x8050) with the data-offset bit gives the header offset.
    /// - Standard header: 8-bit, data at +0x16. Extended (0xFF): must be mono,
    ///   sample size at +0x30, data at +0x40. Compressed (0xFE): mono, format
    ///   `NONE` or `ima4`, sample size at +0x3E, data at +0x40. A multi-channel
    ///   sound, or any other compression, plays **nothing**.
    /// - The sample bytes are everything from the data start to the end of the
    ///   resource; the header's own length/frame fields are ignored, so a short
    ///   or over-long count never fails the decode.
    /// - Loop points are never used (the mixer has none).
    public static func decode(_ data: Data) throws -> NovaSound {
        let r = BinaryReader(data, bigEndian: true)

        // --- 'snd ' resource header + command list -------------------------
        let format = try r.readU16()
        switch format {
        case 1:
            let numDataFormats = Int(try r.readU16())
            try r.advance(numDataFormats * 6)   // (id u16, init options u32) each
        case 2:
            _ = try r.readU16()       // reference count (ignored)
        default:
            throw Error.badFormat(format)
        }

        let numCommands = try r.readU16()
        var sampleOffset: Int? = nil
        for _ in 0..<numCommands {
            let cmd = try r.readU16()
            _ = try r.readU16()               // param1
            let param2 = try r.readU32()      // offset to the sound header
            if sampleOffset == nil, cmd == 0x8000 | bufferCmd || cmd == 0x8000 | soundCmd {
                sampleOffset = Int(param2)
            }
        }
        guard let headerOffset = sampleOffset else { throw Error.unsupportedCommand }

        // --- Sampled Sound Header -----------------------------------------
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> UInt32? {
            guard at >= 0, at + 4 <= bytes.count else { return nil }
            return UInt32(bytes[at]) << 24 | UInt32(bytes[at+1]) << 16 | UInt32(bytes[at+2]) << 8 | UInt32(bytes[at+3])
        }
        func u16(_ at: Int) -> Int? {
            guard at >= 0, at + 2 <= bytes.count else { return nil }
            return Int(bytes[at]) << 8 | Int(bytes[at+1])
        }
        let h = headerOffset
        guard let rateFixed = u32(h + 8), h + 0x14 < bytes.count else { throw Error.unsupportedCommand }
        let sampleRate = Double(rateFixed) / 65536.0
        let rate = sampleRate > 0 ? sampleRate : 22050
        let encoding = bytes[h + 0x14]

        let dataStart: Int
        let bits: Int
        let compression: String
        switch encoding {
        case stdEncoding:
            dataStart = h + 0x16; bits = 8; compression = "NONE"
        case extEncoding:
            guard let channels = u32(h + 4), channels <= 1 else { throw Error.multiChannel }
            guard let size = u16(h + 0x30) else { throw Error.unsupportedEncoding(encoding) }
            dataStart = h + 0x40; bits = size; compression = "NONE"
        case cmpEncoding:
            guard let channels = u32(h + 4), channels <= 1 else { throw Error.multiChannel }
            guard let fmt = u32(h + 0x28), let size = u16(h + 0x3E) else { throw Error.unsupportedEncoding(encoding) }
            let name = String(bytes: [UInt8(fmt >> 24), UInt8((fmt >> 16) & 0xFF),
                                      UInt8((fmt >> 8) & 0xFF), UInt8(fmt & 0xFF)], encoding: .macOSRoman) ?? "?"
            guard name == "NONE" || name == "ima4" else { throw Error.unsupportedCompression(name) }
            dataStart = h + 0x40; bits = size; compression = name
        default:
            throw Error.unsupportedEncoding(encoding)
        }
        let payload = dataStart < bytes.count ? Array(bytes[dataStart...]) : []

        if compression == "ima4" {
            let out = decodeIMA4(payload, packets: payload.count / 34)
            return NovaSound(sampleRate: rate, samples: out)
        }
        var out = [Float]()
        if bits == 16 {
            out.reserveCapacity(payload.count / 2)
            var i = 0
            while i + 1 < payload.count {
                let s = Int16(bitPattern: UInt16(payload[i]) << 8 | UInt16(payload[i+1]))
                out.append(Float(s) / 32768.0)
                i += 2
            }
        } else {
            out = payload.map { (Float($0) - 127.5) / 127.5 }
        }
        return NovaSound(sampleRate: rate, samples: out)
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

    private static func decodeIMA4(_ bytes: [UInt8], packets: Int) -> [Float] {
        var out = [Float](); out.reserveCapacity(packets * 64)
        var p = 0
        for _ in 0..<packets {
            // 2-byte preamble: predictor (top 9 bits) + step index (low 7 bits).
            let c = Int(Int16(bitPattern: UInt16(bytes[p]) << 8 | UInt16(bytes[p+1])))
            p += 2
            var si = c & 0x7F
            var predictor = Double(c - si)
            if si > 88 { si = 88 }
            var step = imaStepTable[si]
            for _ in 0..<32 {                     // 32 bytes → 64 nibbles
                let b = Int(bytes[p]); p += 1
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
